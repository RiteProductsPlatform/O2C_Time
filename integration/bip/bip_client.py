"""
Oracle Fusion BI Publisher — report puller for the O2C Time master-data sync.

Pulls a BIP report over the v2 SOAP surface and returns the decoded bytes, so a
scheduled job can land bulk Fusion master data into the O2C_TIME cache tables
(OC_TIME_WORKER / PROJECT / TASK / ALLOCATION / ABSENCE / CALENDAR).

Why BIP and not REST for these:
  * one report returns thousands of rows where REST needs paginated calls;
  * the data model can JOIN across objects, so project + WBS task + resource
    assignment arrive pre-stitched instead of being reassembled client-side;
  * a full extract lets you detect DELETIONS, which incremental REST cannot.

REST is still required for the daily deltas and for every write-back
(INT-007 OTL push, INT-009 statusChangeRequests) — BIP is read-only.

Services (per the Fusion pod):
    /xmlpserver/services/v2/SecurityService   session login (optional — runReport
                                              takes credentials inline)
    /xmlpserver/services/v2/CatalogService    deploy/inspect report definitions
    /xmlpserver/services/v2/ReportService     runReport  <- used here
    /xmlpserver/services/v2/ScheduleService   async scheduling for large extracts

Credentials are read from the environment. Never hard-code them and never let
them reach a client (NFR-005): this script is meant to run inside OIC or a
scheduled server-side job, not a browser.

    FUSION_BASE_URL   https://<pod>.fa.<dc>.oraclecloud.com
    FUSION_USER       integration service account
    FUSION_PASSWORD   its password

Usage:
    python bip_client.py \
        --report /Custom/O2C/Time/O2C_WORKERS.xdo \
        --format csv \
        --param P_EFFECTIVE_DATE=2026-08-01 \
        --out ./extracts/workers.csv
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
import time
from typing import Dict, Optional
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape

import requests

PUB_NS = "http://xmlns.oracle.com/oxp/service/PublicReportService"
SOAP_NS = "http://schemas.xmlsoap.org/soap/envelope/"

REPORT_SERVICE = "/xmlpserver/services/v2/ReportService"

# A synchronous runReport holds the whole payload in memory on both ends. Past
# roughly this size, ask BIP to chunk it instead.
DEFAULT_CHUNK_BYTES = 5_000_000


class BipError(RuntimeError):
    """A SOAP fault, an HTTP error, or a malformed BIP response."""


# ──────────────────────────────────────────────────────────────────────────
# Envelope construction
# ──────────────────────────────────────────────────────────────────────────

def _params_xml(params: Dict[str, str]) -> str:
    """Render report parameters. BIP wants every value wrapped in its own item."""
    if not params:
        return ""
    items = []
    for name, value in params.items():
        items.append(
            "<pub:item>"
            f"<pub:name>{escape(str(name))}</pub:name>"
            f"<pub:values><pub:item>{escape(str(value))}</pub:item></pub:values>"
            "</pub:item>"
        )
    return (
        "<pub:parameterNameValues><pub:listOfParamNameValues>"
        + "".join(items)
        + "</pub:listOfParamNameValues></pub:parameterNameValues>"
    )


def _run_report_envelope(report_path: str, user: str, password: str,
                         fmt: str = "csv", template: str = "Default",
                         locale: str = "en-US",
                         params: Optional[Dict[str, str]] = None,
                         chunk_size: int = -1) -> str:
    """
    Build a runReport request.

    byPassCache is true because master data must never be served from a cached
    render — a stale worker list silently produces a stale timesheet grid.

    sizeOfDataChunkDownload = -1 returns everything in one response; a positive
    value makes BIP stage the output and hand back a reportFileID to page through.
    """
    return (
        f'<soapenv:Envelope xmlns:soapenv="{SOAP_NS}" xmlns:pub="{PUB_NS}">'
        "<soapenv:Header/><soapenv:Body>"
        "<pub:runReport>"
        "<pub:reportRequest>"
        f"<pub:attributeFormat>{escape(fmt)}</pub:attributeFormat>"
        f"<pub:attributeLocale>{escape(locale)}</pub:attributeLocale>"
        f"<pub:attributeTemplate>{escape(template)}</pub:attributeTemplate>"
        "<pub:byPassCache>true</pub:byPassCache>"
        "<pub:flattenXML>false</pub:flattenXML>"
        f"{_params_xml(params or {})}"
        f"<pub:reportAbsolutePath>{escape(report_path)}</pub:reportAbsolutePath>"
        f"<pub:sizeOfDataChunkDownload>{int(chunk_size)}</pub:sizeOfDataChunkDownload>"
        "</pub:reportRequest>"
        f"<pub:userID>{escape(user)}</pub:userID>"
        f"<pub:password>{escape(password)}</pub:password>"
        "</pub:runReport>"
        "</soapenv:Body></soapenv:Envelope>"
    )


def _download_chunk_envelope(file_id: str, user: str, password: str,
                             begin: int, size: int) -> str:
    return (
        f'<soapenv:Envelope xmlns:soapenv="{SOAP_NS}" xmlns:pub="{PUB_NS}">'
        "<soapenv:Header/><soapenv:Body>"
        "<pub:downloadReportDataChunk>"
        f"<pub:fileID>{escape(file_id)}</pub:fileID>"
        f"<pub:beginIdx>{int(begin)}</pub:beginIdx>"
        f"<pub:size>{int(size)}</pub:size>"
        f"<pub:userID>{escape(user)}</pub:userID>"
        f"<pub:password>{escape(password)}</pub:password>"
        "</pub:downloadReportDataChunk>"
        "</soapenv:Body></soapenv:Envelope>"
    )


# ──────────────────────────────────────────────────────────────────────────
# Transport
# ──────────────────────────────────────────────────────────────────────────

def _first_text(root: ET.Element, tag: str) -> Optional[str]:
    """Find a tag regardless of the prefix BIP happens to use."""
    for el in root.iter():
        if el.tag.rsplit("}", 1)[-1] == tag:
            return el.text
    return None


def _post(session: requests.Session, url: str, envelope: str,
          timeout: int, retries: int = 3) -> ET.Element:
    headers = {"Content-Type": "text/xml; charset=utf-8", "SOAPAction": ""}
    last = None
    for attempt in range(1, retries + 1):
        try:
            resp = session.post(url, data=envelope.encode("utf-8"),
                                headers=headers, timeout=timeout)
        except requests.RequestException as exc:
            last = exc
            if attempt == retries:
                raise BipError(f"{url} unreachable after {retries} attempts: {exc}") from exc
            time.sleep(2 ** attempt)
            continue

        # A SOAP fault still arrives as 500, and its text is the only useful
        # diagnostic BIP gives - surface it rather than the status code alone.
        if resp.status_code >= 400 or "<faultstring" in resp.text:
            try:
                fault = _first_text(ET.fromstring(resp.content), "faultstring")
            except ET.ParseError:
                fault = None
            raise BipError(
                f"BIP returned {resp.status_code}: {fault or resp.text[:400]}")

        try:
            return ET.fromstring(resp.content)
        except ET.ParseError as exc:
            raise BipError(f"Malformed SOAP response: {exc}") from exc

    raise BipError(str(last))


def run_report(report_path: str,
               fmt: str = "csv",
               template: str = "Default",
               locale: str = "en-US",
               params: Optional[Dict[str, str]] = None,
               base_url: Optional[str] = None,
               user: Optional[str] = None,
               password: Optional[str] = None,
               timeout: int = 900,
               chunked: bool = False,
               chunk_bytes: int = DEFAULT_CHUNK_BYTES) -> bytes:
    """
    Run a BIP report and return its decoded output.

    Set chunked=True for bulk extracts. BIP then stages the file and returns a
    reportFileID which is paged through, so neither side has to hold the whole
    extract in memory at once.
    """
    base_url = (base_url or os.environ.get("FUSION_BASE_URL", "")).rstrip("/")
    user = user or os.environ.get("FUSION_USER", "")
    password = password or os.environ.get("FUSION_PASSWORD", "")

    missing = [n for n, v in
               (("FUSION_BASE_URL", base_url), ("FUSION_USER", user),
                ("FUSION_PASSWORD", password)) if not v]
    if missing:
        raise BipError("Missing environment variable(s): " + ", ".join(missing))

    url = base_url + REPORT_SERVICE
    session = requests.Session()

    root = _post(session, url,
                 _run_report_envelope(report_path, user, password, fmt, template,
                                      locale, params,
                                      chunk_bytes if chunked else -1),
                 timeout)

    payload = _first_text(root, "reportBytes")
    if payload is None:
        raise BipError("Response contained no reportBytes — check the report "
                       "path and that the account can run it.")

    data = base64.b64decode(payload)

    if not chunked:
        return data

    # Chunked: keep pulling until a short read says we have reached the end.
    file_id = _first_text(root, "reportFileID")
    if not file_id:
        return data

    out = bytearray(data)
    begin = len(out)
    while True:
        chunk_root = _post(session, url,
                           _download_chunk_envelope(file_id, user, password,
                                                    begin, chunk_bytes),
                           timeout)
        b64 = _first_text(chunk_root, "reportBytes")
        if not b64:
            break
        chunk = base64.b64decode(b64)
        if not chunk:
            break
        out.extend(chunk)
        begin += len(chunk)
        if len(chunk) < chunk_bytes:
            break

    return bytes(out)


# ──────────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────────

def _parse_params(pairs) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for p in pairs or []:
        if "=" not in p:
            raise SystemExit(f"--param must be NAME=VALUE, got: {p}")
        name, _, value = p.partition("=")
        out[name.strip()] = value
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Pull a Fusion BI Publisher report.")
    ap.add_argument("--report", required=True,
                    help="Absolute catalog path, e.g. /Custom/O2C/Time/O2C_WORKERS.xdo")
    ap.add_argument("--format", default="csv", help="csv | xml | xlsx (default csv)")
    ap.add_argument("--template", default="Default", help="Layout template name")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--param", action="append", metavar="NAME=VALUE",
                    help="Report parameter; repeatable")
    ap.add_argument("--out", help="Write to this file instead of stdout")
    ap.add_argument("--chunked", action="store_true",
                    help="Stage and page the output — use for bulk extracts")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args(argv)

    try:
        data = run_report(args.report, fmt=args.format, template=args.template,
                          locale=args.locale, params=_parse_params(args.param),
                          timeout=args.timeout, chunked=args.chunked)
    except BipError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "wb") as fh:
            fh.write(data)
        rows = data.count(b"\n")
        print(f"{len(data):,} bytes ({rows:,} lines) -> {args.out}")
    else:
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
