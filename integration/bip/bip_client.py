"""
Oracle Fusion BI Publisher client — O2C Time master-data extraction.

Pulls bulk Fusion master data into the O2C_TIME cache tables
(OC_TIME_WORKER / PROJECT / TASK / ALLOCATION / ABSENCE / CALENDAR).

Why BIP rather than REST for these:
  * one report returns thousands of rows where REST needs paginated calls;
  * the data model JOINs across objects, so project + WBS task + resource
    assignment arrive pre-stitched instead of being reassembled client-side;
  * a full extract lets you detect DELETIONS, which incremental REST cannot.

REST remains required for daily deltas and every write-back (INT-007 OTL push,
INT-009 statusChangeRequests) — BIP is read-only.

Everything below was verified against a live Fusion pod. Four things that are
not obvious from the WSDL and cost real time to discover:

  1. uploadObject requires objectType 'xdmz' (a ZIP), not 'xdm'. The service
     rejects 'xdm' outright: "Only support types - xdoz / xdmz / xssz / xmaz /
     xsbzxdrz".
  2. The ZIP must contain the model as '_datamodel.xdm'.
  3. Responses can be gzip-encoded — including SOAP faults, so a failure looks
     like binary noise unless it is decompressed before the faultstring is read.
  4. runDataModel output is wrapped <DATA_DS><ROWSET><ROW>, NOT in the <G_1>
     group name declared in the model.

Credentials come from the environment. This runs inside OIC or a scheduled
server-side job, never a browser (NFR-005).

    FUSION_BASE_URL   https://<pod>.<domain>
    FUSION_USER       integration service account
    FUSION_PASSWORD   its password
"""

from __future__ import annotations

import base64
import gzip
import io
import os
import re
import ssl
import time
import urllib.error
import urllib.request
import zipfile
from typing import Dict, List, Optional
from xml.sax.saxutils import escape

NS = "http://xmlns.oracle.com/oxp/service/v2"
SOAP_NS = "http://schemas.xmlsoap.org/soap/envelope/"

REPORT_SERVICE = "/xmlpserver/services/v2/ReportService"
CATALOG_SERVICE = "/xmlpserver/services/v2/CatalogService"
SECURITY_SERVICE = "/xmlpserver/services/v2/SecurityService"

DEFAULT_CHUNK_BYTES = 5_000_000

# Fusion's SQL data source. HCM and PPM objects are both reachable from it —
# they are synonyms into the same FUSION schema.
DEFAULT_DATA_SOURCE = "ApplicationDB_FSCM"


class BipError(RuntimeError):
    """A SOAP fault, HTTP error, or malformed BIP response."""


class BipClient:

    def __init__(self, base_url: Optional[str] = None, user: Optional[str] = None,
                 password: Optional[str] = None, verify_tls: bool = True,
                 timeout: int = 900):
        self.base_url = (base_url or os.environ.get("FUSION_BASE_URL", "")).rstrip("/")
        self.user = user or os.environ.get("FUSION_USER", "")
        self.password = password or os.environ.get("FUSION_PASSWORD", "")
        self.timeout = timeout

        missing = [n for n, v in (("FUSION_BASE_URL", self.base_url),
                                  ("FUSION_USER", self.user),
                                  ("FUSION_PASSWORD", self.password)) if not v]
        if missing:
            raise BipError("Missing environment variable(s): " + ", ".join(missing))

        self._ctx = ssl.create_default_context()
        if not verify_tls:
            self._ctx.check_hostname = False
            self._ctx.verify_mode = ssl.CERT_NONE

    # ── transport ────────────────────────────────────────────────────────

    @property
    def _creds(self) -> str:
        return ("<p:userID>%s</p:userID><p:password>%s</p:password>"
                % (escape(self.user), escape(self.password)))

    @staticmethod
    def _decode(raw: bytes, resp) -> str:
        """BIP gzips responses — including faults — depending on the front end."""
        enc = (resp.headers.get("Content-Encoding") or "").lower()
        if enc == "gzip" or raw[:2] == b"\x1f\x8b":
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        return raw.decode("utf-8", "replace")

    def _post(self, service: str, op: str, inner: str,
              timeout: Optional[int] = None, retries: int = 3) -> str:
        envelope = (
            '<s:Envelope xmlns:s="%s" xmlns:p="%s"><s:Body>'
            "<p:%s>%s</p:%s>"
            "</s:Body></s:Envelope>" % (SOAP_NS, NS, op, inner, op)
        )
        url = self.base_url + service
        headers = {
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPAction": "",
            # Ask for plain text so a fault is readable even if decompression fails.
            "Accept-Encoding": "identity",
        }
        last: Optional[Exception] = None

        for attempt in range(1, retries + 1):
            req = urllib.request.Request(url, data=envelope.encode("utf-8"),
                                         headers=headers)
            try:
                with urllib.request.urlopen(
                        req, timeout=timeout or self.timeout, context=self._ctx) as r:
                    return self._decode(r.read(), r)
            except urllib.error.HTTPError as exc:
                body = self._decode(exc.read(), exc)
                fault = re.search(r"<faultstring>(.*?)</faultstring>", body, re.S)
                raise BipError("%s -> HTTP %s: %s"
                               % (op, exc.code,
                                  fault.group(1).strip() if fault else body[:400]))
            except Exception as exc:                       # network-level only
                last = exc
                if attempt == retries:
                    raise BipError("%s unreachable after %d attempts: %s"
                                   % (url, retries, exc)) from exc
                time.sleep(2 ** attempt)

        raise BipError(str(last))

    @staticmethod
    def _val(body: str, tag: str) -> Optional[str]:
        m = re.search(r"<(?:\w+:)?%s[^>]*>(.*?)</(?:\w+:)?%s>" % (tag, tag), body, re.S)
        return m.group(1) if m else None

    # ── security ─────────────────────────────────────────────────────────

    def validate_login(self) -> bool:
        body = self._post(SECURITY_SERVICE, "validateLogin", self._creds, timeout=60)
        return (self._val(body, "validateLoginReturn") or "").strip() == "true"

    def entitlements(self) -> Dict[str, bool]:
        out = {}
        for op in ("isAdmin", "isDataModelDeveloper", "isReportDeveloper", "isScheduler"):
            try:
                body = self._post(SECURITY_SERVICE, op, self._creds, timeout=60)
                out[op] = (self._val(body, op + "Return") or "").strip() == "true"
            except BipError:
                out[op] = False
        return out

    # ── catalog ──────────────────────────────────────────────────────────

    def object_exists(self, path: str) -> bool:
        body = self._post(CATALOG_SERVICE, "objectExist",
                          "<p:reportObjectAbsolutePath>%s</p:reportObjectAbsolutePath>%s"
                          % (escape(path), self._creds), timeout=60)
        return (self._val(body, "objectExistReturn") or "").strip() == "true"

    def delete_object(self, path: str) -> bool:
        body = self._post(CATALOG_SERVICE, "deleteObject",
                          "<p:objectAbsolutePath>%s</p:objectAbsolutePath>%s"
                          % (escape(path), self._creds), timeout=120)
        return (self._val(body, "deleteObjectReturn") or "").strip() == "true"

    def folder_contents(self, folder: str) -> List[str]:
        body = self._post(CATALOG_SERVICE, "getFolderContents",
                          "<p:folderAbsolutePath>%s</p:folderAbsolutePath>%s"
                          % (escape(folder), self._creds), timeout=120)
        return re.findall(r"<absolutePath>([^<]*)</absolutePath>", body)

    # ── data models ──────────────────────────────────────────────────────

    @staticmethod
    def build_data_model(sql: str, columns: List[str],
                         data_source: str = DEFAULT_DATA_SOURCE,
                         description: str = "O2C Time extract",
                         defaults: Optional[Dict[str, str]] = None) -> str:
        """
        Wrap a SELECT in the minimal .xdm BIP will accept.

        `columns` must match the SELECT list aliases exactly and in order — BIP
        maps output elements positionally against the declared structure.

        Any :BIND in the SQL is auto-declared in <parameters>. This is not
        optional: an undeclared bind is NOT an error — BIP silently resolves it
        to NULL, so every date comparison quietly fails and the extract returns
        zero rows while reporting success. That failure mode is invisible unless
        you compare against a run with the value inlined.
        """
        elements = "".join(
            '<element name="%s" value="%s"/>' % (c.upper(), c.upper()) for c in columns)

        binds = []
        for b in re.findall(r":([A-Za-z_][A-Za-z0-9_]*)", sql):
            if b not in binds:
                binds.append(b)

        if binds:
            defaults = defaults or {}
            params = "<parameters>" + "".join(
                '<parameter name="%s" dataType="xsd:string" defaultValue="%s" '
                'rowPlacement="1"><input label="%s"/></parameter>'
                % (b, escape(str(defaults.get(b, ""))), b.replace("_", " ").title())
                for b in binds) + "</parameters>"
        else:
            params = "<parameters/>"

        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<dataModel xmlns="http://xmlns.oracle.com/oxp/xmlp" version="2.0" '
            'defaultDataSourceRef="%s">'
            "<description>%s</description>"
            '<dataProperties>'
            '<property name="include_parameters" value="true"/>'
            '<property name="include_null_Element" value="true"/>'
            '<property name="include_rowsettag" value="false"/>'
            "</dataProperties>"
            '<dataSets><dataSet name="Q1" type="simple">'
            '<sql dataSourceRef="%s"><![CDATA[%s]]></sql>'
            "</dataSet></dataSets>"
            '<output rootName="DATA_DS" uniqueRowName="false">'
            '<nodeList name="data-structure"><dataStructure tagName="DATA_DS">'
            '<group name="G_1" label="Q1" source="Q1">%s</group>'
            "</dataStructure></nodeList></output>"
            "<eventTriggers/><valueSets/>%s<bursting/><validation/>"
            "</dataModel>"
            % (data_source, escape(description), data_source, sql, elements, params)
        )

    def upload_data_model(self, path: str, xdm: str, replace: bool = True) -> str:
        """
        Deploy a data model.

        objectType MUST be 'xdmz' and the payload a ZIP containing
        '_datamodel.xdm' — the service rejects a bare 'xdm'. An existing object
        is deleted first: uploading over one fails rather than replacing it.
        """
        if replace and self.object_exists(path):
            self.delete_object(path)

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("_datamodel.xdm", xdm)
        payload = base64.b64encode(buf.getvalue()).decode()

        body = self._post(
            CATALOG_SERVICE, "uploadObject",
            "<p:reportObjectAbsolutePathURL>%s</p:reportObjectAbsolutePathURL>"
            "<p:objectType>xdmz</p:objectType>"
            "<p:objectZippedData>%s</p:objectZippedData>%s"
            % (escape(path), payload, self._creds), timeout=300)

        result = self._val(body, "uploadObjectReturn")
        if not result:
            raise BipError("uploadObject returned no path — deploy failed.")
        return result.strip()

    # ── execution ────────────────────────────────────────────────────────

    def _report_request(self, path: str, fmt: str, template: str, locale: str,
                        params: Optional[Dict[str, str]], chunk: int) -> str:
        items = ""
        for name, value in (params or {}).items():
            items += ("<p:item><p:name>%s</p:name><p:values><p:item>%s</p:item>"
                      "</p:values></p:item>" % (escape(str(name)), escape(str(value))))
        pblock = ("<p:parameterNameValues><p:listOfParamNameValues>%s"
                  "</p:listOfParamNameValues></p:parameterNameValues>" % items) if items else ""
        return (
            "<p:reportRequest>"
            "<p:attributeFormat>%s</p:attributeFormat>"
            "<p:attributeLocale>%s</p:attributeLocale>"
            "<p:attributeTemplate>%s</p:attributeTemplate>"
            # Master data must never come from a cached render: a stale worker
            # list silently produces a stale timesheet grid.
            "<p:byPassCache>true</p:byPassCache>"
            "<p:flattenXML>false</p:flattenXML>%s"
            "<p:reportAbsolutePath>%s</p:reportAbsolutePath>"
            "<p:sizeOfDataChunkDownload>%d</p:sizeOfDataChunkDownload>"
            "</p:reportRequest>"
            % (escape(fmt), escape(locale), escape(template), pblock,
               escape(path), int(chunk))
        )

    def _collect(self, body: str, chunked: bool, chunk_bytes: int) -> bytes:
        payload = self._val(body, "reportBytes")
        if payload is None:
            raise BipError("Response contained no reportBytes — check the path "
                           "and that the account may run it.")
        data = bytearray(base64.b64decode(payload))
        if not chunked:
            return bytes(data)

        file_id = self._val(body, "reportFileID")
        if not file_id:
            return bytes(data)

        begin = len(data)
        while True:
            more = self._post(
                REPORT_SERVICE, "downloadReportDataChunk",
                "<p:fileID>%s</p:fileID><p:beginIdx>%d</p:beginIdx>"
                "<p:size>%d</p:size>%s"
                % (escape(file_id), begin, chunk_bytes, self._creds))
            b64 = self._val(more, "reportBytes")
            if not b64:
                break
            chunk = base64.b64decode(b64)
            if not chunk:
                break
            data.extend(chunk)
            begin += len(chunk)
            if len(chunk) < chunk_bytes:
                break
        return bytes(data)

    def run_data_model(self, path: str, params: Optional[Dict[str, str]] = None,
                       chunked: bool = False,
                       chunk_bytes: int = DEFAULT_CHUNK_BYTES) -> bytes:
        """Run a data model directly — returns its raw XML output."""
        body = self._post(REPORT_SERVICE, "runDataModel",
                          self._report_request(path, "xml", "", "en-US", params,
                                               chunk_bytes if chunked else -1)
                          + self._creds)
        return self._collect(body, chunked, chunk_bytes)

    def run_report(self, path: str, fmt: str = "csv", template: str = "Default",
                   locale: str = "en-US", params: Optional[Dict[str, str]] = None,
                   chunked: bool = False,
                   chunk_bytes: int = DEFAULT_CHUNK_BYTES) -> bytes:
        """Run a report that has a layout template."""
        body = self._post(REPORT_SERVICE, "runReport",
                          self._report_request(path, fmt, template, locale, params,
                                               chunk_bytes if chunked else -1)
                          + self._creds)
        return self._collect(body, chunked, chunk_bytes)

    # ── convenience ──────────────────────────────────────────────────────

    @staticmethod
    def rows(xml_bytes: bytes) -> List[Dict[str, str]]:
        """
        Parse runDataModel output into dicts.

        The rows are <DATA_DS><ROWSET><ROW>, despite the model declaring a group
        called G_1 — reading G_1 silently yields zero rows.
        """
        text = xml_bytes.decode("utf-8", "replace")
        out: List[Dict[str, str]] = []
        for chunk in re.findall(r"<ROW>(.*?)</ROW>", text, re.S):
            out.append({m.group(1): (m.group(2) or "").strip()
                        for m in re.finditer(r"<([A-Za-z0-9_]+)>(.*?)</\1>", chunk, re.S)})
        return out

    def query(self, sql: str, columns: List[str],
              path: str = "/Custom/O2C_TIME/_adhoc.xdm",
              keep: bool = False) -> List[Dict[str, str]]:
        """
        Run an arbitrary SELECT: deploy a throwaway model, run it, delete it.

        Intended for discovery and verification, not for production extracts —
        production ones should be deployed once and scheduled.
        """
        self.upload_data_model(path, self.build_data_model(sql, columns))
        try:
            return self.rows(self.run_data_model(path))
        finally:
            if not keep:
                try:
                    self.delete_object(path)
                except BipError:
                    pass
