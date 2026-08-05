# Extracting Data from BI Publisher (Oracle Analytics Publisher) Reports in Oracle Fusion

_Source: Oracle BI Publisher Developer's Guide (docs.oracle.com/middleware/12213/bip/BIPDV) + Fusion SaaS Analytics Publisher._
_Purpose: Reference / build-input for programmatically extracting report data from Oracle Fusion Cloud._

---

## 1. Overview

Oracle Fusion exposes BI Publisher (rebranded **Oracle Analytics Publisher**) report output through **two supported integration paths**:

| Path | Endpoint style | Best for |
|------|----------------|----------|
| **SOAP** `ExternalReportWSSService` / `ReportService` | `/xmlpserver/services/...` | Standard, most widely used in Fusion SaaS; on-demand and scheduled extraction |
| **REST** Analytics Publisher API | `/xmlpserver/services/rest/v1/...` | Modern JSON integrations |

For pure **data extraction**, the standard pattern is SOAP `runReport()` with output format `xml` or `csv`, backed by a BI Publisher **data model** and a data/CSV template.

---

## 2. Public BI Publisher Web Services

| Service | Purpose |
|---------|---------|
| **ReportService** | Run reports, get report info, define/modify reports, upload templates. Core service for on-demand extraction. |
| **ScheduleService** | Schedule report jobs, retrieve report outputs, manage report job history. Best for large / asynchronous extracts. |
| **SecurityService** | Security operations (login, session tokens, impersonation). |
| **CatalogService** | Browse and manage the BI Publisher catalog. |

### Fusion SaaS endpoint
In Oracle Fusion Cloud SaaS the secured public service is **`ExternalReportWSSService`** (WS-Security wrapped version of ReportService):

```
WSDL:  https://<your-fusion-host>/xmlpserver/services/ExternalReportWSSService?wsdl
```

Other WSDLs follow the same pattern, e.g.:
```
https://<your-fusion-host>/xmlpserver/services/v2/ReportService?wsdl
https://<your-fusion-host>/xmlpserver/services/v2/ScheduleService?wsdl
```

---

## 3. SOAP — `runReport()` (recommended for extraction)

### Method signatures
```
ReportResponse runReport(ReportRequest reportRequest, String userID, String password);
ReportResponse runReportInSession(ReportRequest reportRequest, String bipSessionToken);
```

| Parameter | Description |
|-----------|-------------|
| `reportRequest` | The ReportRequest object (see below). |
| `userID` | BI Publisher / Fusion user name. |
| `password` | Password for that user. |
| `bipSessionToken` | (In-session variant) session token from SecurityService.login(). |

### 3.1 `ReportRequest` — input fields
| Field | Description |
|-------|-------------|
| `String reportAbsolutePath` | Catalog path to the report, e.g. `/Custom/Time/MyExtract.xdo`. |
| `String attributeFormat` | Output format. **Use `xml` or `csv` for data extraction**; also `pdf`, `excel`, `html`, `rtf`, etc. |
| `String attributeTemplate` | Layout/template to apply, e.g. `Employeelisting.rtf`. For raw data use a data-only / CSV template. |
| `String attributeLocale` | Report locale, e.g. `fr-FR`. |
| `String attributeUILocale` | UI locale (required when parameter input is non-English). |
| `String attributeCalendar` | Formatting calendar: `Gregorian`, `Arabic Hijrah`, `English Hijrah`, `Japanese Imperial`, `Thai Buddha`, `ROC Official`. |
| `String attributeTimeZone` | Time zone for the request. |
| `ParamNameValues parameterNameValues` | Array of report parameter name/value pairs used to filter the data. |
| `int sizeOfDataChunkDownload` | `-1` = return whole output in one response; a positive byte value streams output in chunks (use for large extracts). |
| `boolean flattenXML` | Whether to flatten the generated XML. |
| `byte[] reportData` | Optional inline data (when not using the report's own data model). |
| `String reportRawData` | Optional raw data string. |

### 3.2 `ReportResponse` — output fields
| Field | Description |
|-------|-------------|
| `byte[] reportBytes` | **The report binary/data output** (base64 over the wire). This is your extracted data. |
| `String reportContentType` | Content type, e.g. `text/xml`, `application/vnd.ms-excel`, `application/pdf`, `application/msword`. |
| `String reportFileID` | Numeric ID of the report file (used with getDocumentData() for chunked download). |
| `String reportLocale` | Locale selected for the report (e.g. `fr_FR`). |
| `MetaDataList metaDataList` | Metadata about the generated output. |

### 3.3 Sample SOAP request (ExternalReportWSSService.runReport)
```xml
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:pub="http://xmlns.oracle.com/oxp/service/PublicReportService">
  <soapenv:Header/>
  <soapenv:Body>
    <pub:runReport>
      <pub:reportRequest>
        <pub:reportAbsolutePath>/Custom/Time/TimeCardExtract.xdo</pub:reportAbsolutePath>
        <pub:attributeFormat>csv</pub:attributeFormat>
        <pub:attributeTemplate>DataOnly</pub:attributeTemplate>
        <pub:sizeOfDataChunkDownload>-1</pub:sizeOfDataChunkDownload>
        <pub:parameterNameValues>
          <pub:item>
            <pub:name>P_START_DATE</pub:name>
            <pub:values><pub:item>2026-01-01</pub:item></pub:values>
          </pub:item>
          <pub:item>
            <pub:name>P_END_DATE</pub:name>
            <pub:values><pub:item>2026-01-31</pub:item></pub:values>
          </pub:item>
        </pub:parameterNameValues>
      </pub:reportRequest>
    </pub:runReport>
  </soapenv:Body>
</soapenv:Envelope>
```

### 3.4 Sample SOAP response (abridged)
```xml
<pub:runReportReturn>
  <pub:reportBytes>UEsDBBQABgAI...base64-encoded output...</pub:reportBytes>
  <pub:reportContentType>text/csv</pub:reportContentType>
  <pub:reportFileID>...</pub:reportFileID>
  <pub:reportLocale>en_US</pub:reportLocale>
</pub:runReportReturn>
```

**Extraction flow:** call `runReport` → read `reportBytes` → base64-decode → parse (CSV/XML).

---

## 4. SOAP — ScheduleService (for large / async extracts)

Use ScheduleService when the extract is large or long-running so you don't hold a synchronous connection:

1. `scheduleReport(ScheduleRequest, userID, password)` → returns a **jobId**.
2. Poll `getScheduledReportStatus(jobId, ...)` until complete.
3. `getDocumentData(...)` / `getAllScheduledReportHistory(...)` → download the output.

### `ScheduleRequest` — key fields
| Field | Description |
|-------|-------------|
| `String reportRequest` (ReportRequest) | Same report definition/format/params as above. |
| `String dataModelUrl` | Location of the `.xdm` Data Model definition. |
| `boolean bookBindingOutputOption` | Whether book-binding output is enabled. |
| `DeliveryChannels deliveryChannels` | Delivery options (email, FTP, WebDAV, etc.). |
| schedule timing fields | Start date, frequency, recurrence, etc. |

---

## 5. REST — Analytics Publisher API

Base path on your Fusion pod:
```
https://<your-fusion-host>/xmlpserver/services/rest/v1/
```

### Run a report (data extraction)
```
POST /xmlpserver/services/rest/v1/reports/{reportPath}/run
Authorization: Basic <base64 user:pass>   (or OAuth 2.0 bearer)
Content-Type: multipart/form-data
```
Body: a JSON `ReportRequest` part specifying:
```json
{
  "byPassCache": true,
  "flattenXML": false,
  "sizeOfDataChunkDownload": -1,
  "reportRawData": "",
  "attributeFormat": "csv",
  "attributeTemplate": "DataOnly",
  "attributeLocale": "en-US",
  "parameterNameValues": {
    "listOfParamNameValues": [
      { "item": [
        { "name": "P_START_DATE", "values": { "item": ["2026-01-01"] } },
        { "name": "P_END_DATE",   "values": { "item": ["2026-01-31"] } }
      ]}
    ]
  }
}
```
**Response:** report output stream (CSV/XML/PDF per `attributeFormat`).

### Other useful REST endpoints
| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/reports/{reportPath}` | Get report definition / metadata. |
| GET | `/reports/{reportPath}/parameters` | List report parameters. |
| POST | `/reports/{reportPath}/run` | Run report and return output. |
| POST | `/reports/{reportPath}/scheduleReport` | Schedule the report job. |
| GET | `/scheduledReport/{jobId}` | Get scheduled job status / output. |

---

## 6. Authentication

- **SOAP `ExternalReportWSSService`**: WS-Security header (username token) OR the `userID`/`password` arguments on `runReport`.
- **REST**: HTTP Basic auth or OAuth 2.0 bearer token.
- Use a dedicated Fusion integration user with the BI catalog privileges to run the target report.
- _Do not embed credentials in the .xdo path or URL; pass them via the auth header / method arguments._

---

## 7. Best-practice extraction pattern

1. Build a **BI Publisher Data Model** (`.xdm`) with your SQL / view against the Fusion tables (e.g. the HWM_TM_REC*, PJC_*, PAY_* time tables).
2. Add a **CSV or "data only" template** so output is clean tabular data.
3. Call **`runReport`** (SOAP) or **POST `/run`** (REST) with `attributeFormat = csv` (small/medium) — or **ScheduleService** for large volumes.
4. Decode `reportBytes` (base64) and parse.
5. For very large data sets, prefer **chunked download** (`sizeOfDataChunkDownload` > 0 + `getDocumentData`) or scheduled delivery to FTP/UCM.

---

## 8. When to use BIP vs transactional REST

- **Transactional REST** (timeRecordEventRequests, projectExpenditureItems, etc.): create/read individual records, event-driven integration.
- **BI Publisher extraction**: bulk / historical / reconciliation data pulls where per-record REST calls would be too chatty. A data-model-backed report + `runReport(format=csv)` is the standard bulk-extract mechanism.
