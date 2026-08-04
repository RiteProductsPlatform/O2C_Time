# Build Spec: Custom Time Module to Replace Oracle OTL (Oracle Time and Labor)

**Purpose of this document:** A complete, self-contained specification to hand to an AI coding assistant (Claude) to build a custom time-entry / time-management module that replaces Oracle Fusion Cloud Time and Labor (OTL). It defines the architecture, the inputs OTL consumes, the outputs it produces, every relevant REST API (with request/response bodies and field schemas), and the physical database tables. Source: Oracle Fusion Cloud documentation, release 26C (REST books `farws`/`fapap`, Tables & Views books `oedmh`/`oedpp`, and the *Implementing Time and Labor* guide `faitl`).

---

## 1. What the Module Must Do (Executive Summary)

OTL is a **collection-and-validation hub**. It (a) captures reported time, (b) enriches each entry with *time attributes* supplied by integrating applications, (c) validates and routes entries through approval, then (d) distributes approved time to downstream **time consumers**. The three delivered time consumers are **Global Payroll**, **Project Costing**, and **Absence Management**. The same three applications that feed reference data *in* are the ones that receive processed time *out*.

Your module must reproduce this hub: capture time, resolve the POET/payroll/absence attributes, validate + approve, and transfer to Payroll and Project Costing (and record absences).

---

## 2. Architecture Diagram (Data Flow)

```
                        ┌──────────────────────────── REFERENCE DATA (INPUTS) ────────────────────────────┐
                        │                                                                                  │
   GLOBAL PAYROLL ──────┤  Payroll Time Type, Assignment Number, payroll-calculated rates                  │
   (PAY_*)              │   REST: elementEntries, payrollTimeDefinitionsLOV, payrollRelationships          │
                        │                                                                                  │
   PROJECT COSTING ─────┤  POET = Project + Organization + Expenditure Type + Task ; billable flag; rates  │
   (PJF_*/PJC_*)        │   REST: projects, projects/{id}/child/Tasks, expenditureTypes, projectLaborResources,
                        │         projectResourceAssignments, personAssignmentLaborSchedules, rateSchedules │
                        │                                                                                  │
   ABSENCE MGMT ────────┤  Absence Management Type (e.g. Vacation, Paid Maternity), plan balances          │
   (ANC_*)              │   REST: absences, planBalances, absenceTypesLOV                                  │
                        │                                                                                  │
   HR / SCHEDULING ─────┤  Worker eligibility (Time Card Required), work schedule, patterns, shifts,       │
   (PER_*/HTS_*)        │   calendar/holidays.  REST: workforceScheduleDefinitions, workforceScheduleShifts │
                        └───────────────────────────────────────┬──────────────────────────────────────────┘
                                                                 │  (defaulting & validation)
                                                                 ▼
        ┌───────────────────────────────────────────────────────────────────────────────────────────┐
        │                              TIME MODULE  (the OTL replacement)                             │
        │                                                                                             │
        │   CAPTURE            →   VALIDATE            →   APPROVE            →   ROUTE (consumer set)  │
        │   time cards /           rules, categories,      manager approval      decide which consumer │
        │   web clock /            eligibility, POET       workflow              each entry goes to    │
        │   calendar /             & rate checks                                                       │
        │   REST time events                                                                           │
        │                                                                                             │
        │   Capture REST:  POST /hcmRestApi/.../timeRecordEventRequests   (processMode = TIME_SUBMIT)  │
        │   Read REST:     GET  /hcmRestApi/.../timeRecords                                            │
        │   Tables:        HWM_TM_REC, HWM_TM_REC_EVENTS, HWM_TM_REC_EVENT_ATRBS,                      │
        │                  HWM_TIMECARDS, HWM_TIME_ENTRIES, HWM_ALLOCATIONS_HDR_F/_LINES_F             │
        └───────────────────────────────────────┬─────────────────────────────────────────────────────┘
                                                 │  after approval: transfer via ESS processes
              ┌──────────────────────────────────┼───────────────────────────────────────┐
              ▼                                   ▼                                        ▼
   ┌────────────────────┐            ┌──────────────────────────┐            ┌──────────────────────┐
   │  GLOBAL PAYROLL     │            │   PROJECT COSTING         │            │  ABSENCE MANAGEMENT  │
   │  (OUTPUT)           │            │   (OUTPUT)                │            │  (OUTPUT)            │
   │                     │            │                           │            │                      │
   │ Process: "Load Time │            │ Process: "Transfer Time   │            │ Absence entries      │
   │ Card Batches" /     │            │ to Projects" → "Import &  │            │ recorded back to     │
   │ Transfer to Payroll │            │ Process Cost Transactions"│            │ Absence Mgmt         │
   │                     │            │                           │            │                      │
   │ Lands as ELEMENT    │            │ Staging: PJC_TXN_XFACE_ALL│            │ Table:               │
   │ ENTRIES             │            │ Costed:  PJC_EXP_ITEMS_ALL│            │ ANC_PER_ABS_ENTRIES  │
   │ Table: PAY_ELEMENT_ │            │          PJC_COST_DIST_   │            │ ANC_PER_ABS_ENTRY_   │
   │ ENTRIES_F           │            │          LINES_ALL        │            │ DTLS                 │
   │ REST: elementEntries│            │ REST(read): projectCosts, │            │ REST: absences       │
   │                     │            │ projectExpenditureItems   │            │                      │
   └────────────────────┘            └──────────────────────────┘            └──────────────────────┘
```

**Routing rule:** each time entry carries a *Time Type* attribute that classifies it as a Payroll entry, a Project entry, and/or an Absence entry. A **time consumer set** decides which consumer(s) receive it. Oracle's delivered consumer sets are **Payroll Only**, **Project (Execution/Absence) Only**, and **Projects and Payroll**.

---

## 3. Inputs and Outputs (Detailed)

### 3.1 Time Attributes — the bridge between OTL and integrating apps

A *time attribute* reflects how time is paid, costed, billed, or recorded, and qualifies each time entry. These are delivered by the integrating applications and are what your module must resolve on every entry:

| Integrating Application | Time Attribute | What it identifies | Example values |
|---|---|---|---|
| Global Payroll | **Payroll Time Type** | Time for payroll processing | Regular, Overtime, Vacation, Public Holiday |
| Project Costing | **Expenditure Type** | Time for costing & billing | Billable, Nonbillable |
| Absence Management | **Absence Management Type** | Time for absence processing | Paid Maternity, Vacation |

These attributes are passed on each time event as `timeRecordEventAttribute` name/value pairs (see the `timeRecordEventRequests` payload in Section 5).

### 3.2 INPUTS (what the module consumes)

1. **Reported time** — from time cards, calendar, Web Clock, collection devices, or the `timeRecordEventRequests` REST resource.
2. **Payroll reference** — Payroll Time Type, Assignment Number, payroll-calculated rates; payroll time definitions & periods.
3. **Project reference (POET)** — Project, Owning/Expenditure Organization, Expenditure Type, Task; billable flag; project resources & assignments; rate schedules.
4. **Absence reference** — Absence types/plans and plan balances (to enter and validate absences on the card).
5. **Worker & schedule** — eligibility (`Time Card Required` on employment), work schedule, work patterns, shifts, calendar/holidays (to default and validate entries).

### 3.3 OUTPUTS (what the module produces, after validate + approve)

1. **To Global Payroll** — approved hours transferred for payment; land as **Element Entries** (`PAY_ELEMENT_ENTRIES_F`). Process: *Load Time Card Batches / Transfer Time Cards from Time and Labor to Payroll*.
2. **To Project Costing** — project time transferred as cost transactions; staged in `PJC_TXN_XFACE_ALL`, costed into `PJC_EXP_ITEMS_ALL` + `PJC_COST_DIST_LINES_ALL`. Process: *Transfer Time to Projects → Import and Process Cost Transactions*.
3. **To Absence Management** — absence entries recorded back as absence records (`ANC_PER_ABS_ENTRIES`).

> **Integration note:** capture is REST (`timeRecordEventRequests`). The hand-off to Payroll and Projects is executed by scheduled (ESS) transfer processes, not a single REST push. Your module should either invoke those processes or write directly to `elementEntries` / stage into the costing interface.

---

## 4. Time Consumer Sets (Routing Logic to Implement)

| Delivered Consumer Set | Applies to entries in time category | Routes to |
|---|---|---|
| Payroll Only | All Payroll Entries | Global Payroll |
| Project (Execution) / Absence Only | All Project / All Absence Entries | Project Costing / Absence |
| Projects and Payroll | All Project Entries | Project Costing **and** Payroll |

Implement this as: classify each entry by its Time Type → look up the consumer set → dispatch to the matching output transfer(s).

---

## 5. REST APIs (Endpoints, Payloads, Field Schemas)

**Base paths:** HCM = `/hcmRestApi/resources/11.13.18.05/` · Projects/PPM = `/fscmRestApi/resources/11.13.18.05/`. Auth: Basic or OAuth 2.0 over HTTPS; `Content-Type: application/json`.

### 5.1 CAPTURE — Submit time (core write API)

#### Submit time — Time Record Event Requests

- **Method / Path:** `POST /hcmRestApi/resources/11.13.18.05/timeRecordEventRequests`

**Example Request Body**

```json
{
"processInline": "N",
"processMode": "TIME_SUBMIT",
"timeRecordEvent":
[{
"startTime":"2017-11-07T13:00:00.000-08:00",
"stopTime":"2017-11-07T16:00:00.000-08:00",
"reporterIdType":"PERSON",
"reporterId":"955160008182127",
"assignmentNumber":"10",
"comment":"Missing entry due to clock down",
"operationType":"ADD",
"timeRecordEventAttribute":
[{
"attributeName":"PayrollTimeType",
"attributeValue":"ZOTL_Regular"
}]
}]
}
```

**Example Response Body**

```json
{
    "timeRecordEventRequestId": 300100145540850,
    "processMode": "TIME_SUBMIT",
    "processInline": "Y",
    "timeRecordEvent": [
        {
            "comment": "Missing entry due to clock down",
            "crudStatusValue": 0,
            "personId": "300100074978533",
            "referenceDate": null,
            "reporterId": "955160008184353",
            "reporterIdType": "PERSON",
            "startTime": "2017-11-07T13:00:00.000-08:00",
            "stopTime": "2017-11-07T16:00:00.000-08:00",
            "subresourceId": null,
            "timeRecordEventId": 300100145540851,
            "timeRecordEventRequestId": 300100145540850,
            "timeRecordId": null,
            "timeRecordVersion": null,
            "operationType": "ADD",
            "assignmentNumber": "10",
            "eventStatusValue": 5,
            "eventStatus": "COMPLETE",
            "measure": null,
            "changeReason": null,
            "timeRecordEventAttribute": [
                {
                    "timeAttributeFieldId": 300100028326158,
                    "timeRecordEventAttributeId": 300100145540852,
                    "timeRecordEventId": 300100145540851,
                    "attributeValue": "ZOTL_Regular",
                    "attributeName": "PayrollTimeType",
                    "changeReason": null,
                    "links": [...]
}
            
         
                 Back to Top
```

> `processMode: "TIME_SUBMIT"` posts to the repository. Each event carries `timeRecordEventAttribute` name/value pairs — this is where you attach **PayrollTimeType**, project **POET**, and **Absence type** so downstream routing works.


**Field Schema — `timeRecordEventRequests`**

| Field | Type | Description |
|---|---|---|
| `processInline` | string (max 30) | Indicates whether to process the time record events inline or asynchronously. |
| `processMode` | string (max 20) | Mode--Save, Submit, or Enter--for processing time records stored in the WFM time repository. |
| `timeRecordEvent` | array | Time Record Events  Record Events The timeRecordEvents resource is a child of the timeRecordEventRequests resource. It's a unique identifier for a time record event sent using the time records REST AP |
| `timeRecordEventRequestId` | integer (int64) | Unique identifier for the time record event request. |
| `assignmentNumber` | string | Assignment number for the person associated with the time record event. Valid values are defined in the AssignmentPVO1 lookup type. |
| `changeReason` | string (max 64) | Reason for the audited change associated with the time record event, such as missing time entry or incorrect time entry. Valid values are defined in the HcmLookupPVO1 lookup type. The lookup codes are |
| `comment` | string (max 1000) | Comment associated with the time record event. |
| `crudStatusValue` | integer | Numeric value for the type of operation, such as 1 for Create, 2 for Update, or 3 for Delete, to apply when importing the time record event. |
| `eventStatus` | string | Processing status for the time record event, such as New, In process, or Complete. |
| `eventStatusValue` | integer | Numeric value for the processing status, such as 0 for New, 4 for In process, or 5 for Complete, of the time record event. |
| `measure` | number | Quantity, in hours or units, for the time record event. |
| `operationType` | string | of operation, such as Create, Update, or Delete, to apply when importing the time record event. |
| `personId` | string | Unique identifier for the person associated with the time record event. |
| `referenceDate` | string (date) | to use to process a time record event that spans multiple days. |
| `reporterId` | string (max 80) | Unique identifier for the worker associated with the time record event. |
| `reporterIdType` | string (max 20) | of identifier for the time reporter, such as Person or Badge. |
| `startTime` | string (max 150) | Start time for the time record event to import. |
| `stopTime` | string (max 150) | End time for the time record event to import. |
| `subresourceId` | integer | Identifier for the work assignment of the person associated with the time record event. |
| `timeRecordEventAttribute` | array | Time Record Event Attributes  Record Event Attributes The timeRecordEventAttribute resource is the child of the timeRecordEvents resource and the grandchild of the timeRecordEventRequests resource. It |
| `timeRecordEventId` | integer | Unique identifier for the time record event. |
| `timeRecordEventMessage` | array | Time Record Event Messages  Record Event Messages The timeRecordEventMessage resource is a child of the timeRecordEvents attribute and the grandchild of the timeRecordEventRequests resource. It's a un |
| `timeRecordId` | integer | Unique identifier for the time record to update or delete. |
| `timeRecordVersion` | integer | Version number for the time record stored in the Workforce Management time repository. |
| `attributeName` | string (max 240) | of the attribute to import with the time record event, such as Payroll Time Type or Absence Management Type. Valid values are defined in the TimeAttibuteFieldPVO1 lookup type. |
| `attributeValue` | string (max 150) | for the attribute to import with the time record event, such as Regular or Overtime. |
| `timeAttributeFieldId` | integer (int64) | Unique identifier for the field that the time attribute is associated with. |
| `timeRecordEventAttributeId` | integer (int64) | Unique identifier for the time record event attribute. |
| `allowException` | string (max 1) | Indicates whether to allow the exception associated with the time record. Valid values are true and false. The default value is false. |
| `attributeType` | string (max 20) | for the attribute that the message is related to, such as Timestamp for startTime. |
| `messageField` | string (max 256) | Unique identifier for the field that the message is associated with. |
| `messageId` | integer (int64) | Unique identifier for the message associated with the time record. |
| `messageName` | string (max 256) | of the message associated with the time record. |
| `timeBldgBlkVersion` | integer (int32) | Version number for the time record event with the specified message. |
| `timeRecordEventMessageId` | integer (int64) | Unique identifier for the message associated with the time record event. |

#### Read posted time — Time Records

- **Method / Path:** `GET /hcmRestApi/resources/11.13.18.05/timeRecords/{timeRecordId}`

**Example Response Body**

```json
{
    "timeRecordId": 300100115490167,
    "timeRecordGroupId": 300100115490166,
    "startTime": "2014-01-03T00:00:00+00:00",
    "stopTime": null,
    "groupType": "Processed TimecardEntry",
    "recordType": "MEASURE",
    "measure": 8,
    "unitOfMeasure": "Hours",
    "personNumber": "955160008176061",
    "personId": 300100026188534,
    "comment": null,
    "assignmentNumber": "E955160008176061",
    "timeRecordGroupVersion": 1,
    "timeRecordVersion": 1,
    "referenceDate": null,
    "links": [...]
}
```


**Field Schema — `timeRecords`**

| Field | Type | Description |
|---|---|---|
| `assignmentNumber` | string (max 50, read-only) | Assignment number for the person associated with the time record. |
| `comment` | string (max 1000, read-only) | Comment associated with the time record. |
| `earnedDate` | string (date) (read-only) | Time entry date determined by the earned day rule configuration. |
| `groupType` | string (max 255, read-only) | Layer where time record groups are retrieved from, such as processed time or posted schedule shift. |
| `measure` | number (read-only) | Quantity, in hours or units, for the time record. |
| `overtimeDate` | string (date) (read-only) | Time entry date determined by the overtime day rule and start time configuration. |
| `personId` | integer (int64) (read-only) | Unique identifier for the person associated with the time record. |
| `personNumber` | string (max 30, read-only) | for the person associated with the time record. |
| `recordType` | string (max 30, read-only) | for the time record, either measure or range. |
| `startTime` | string (date-time) (read-only) | Start time for the range containing the time records to retrieve. |
| `stopTime` | string (date-time) (read-only) | End time for the range containing the time records to retrieve. |
| `timeAttributes` | array | Time Attributes  Attributes The timeAttributes resource is a child of the timeRecordGroups resource. It's a qualifier associated with the time record group that reflects how time is recorded as an inf |
| `timeMessages` | array | Time Messages  Messages The timeMessages resource is a child of the timeRecordGroups resource. It's a unique identifier for the message associated with the time record group. A message gives some info |
| `timeRecordGroupId` | integer (int64) (read-only) | Unique identifier for the time record group containing the reported time record. |
| `timeRecordGroupVersion` | integer (int32) (read-only) | Version number for the time record group stored in the Workforce Management time repository. |
| `timeRecordId` | number (read-only) | Unique identifier for the time record. |
| `timeRecordVersion` | integer (int32) (read-only) | Version number for the time record stored in the Workforce Management time repository. |
| `timeStatuses` | array | Time Statuses  Statuses The timeStatuses resource is a child of the timeRecords resource and a grandchild of the timeRecordGroups resource. It's a unique identifier for the status of the time record g |
| `unitOfMeasure` | string (max 80, read-only) | Unit of measure for the time record, such as hours or units. |
| `attributeId` | number (read-only) | Unique identifier for the time record group attribute. |
| `attributeName` | string (max 240, read-only) | of the time record group attribute, such as Comment. |
| `attributeType` | string (max 240, read-only) | for the time record group attribute, such as Varchar. |
| `attributeValue` | string (max 240, read-only) | for the time record group attribute, such as a comment text. |
| `timeBuildingBlockId` | number (read-only) | Unique identifier for the time record group with the specified attributes. |
| `timeBuildingBlockVersion` | integer (int32) (read-only) | Version number for the time record group with the specified attributes. |
| `allowedException` | string (max 1, read-only) | Indicates whether to allow the exception associated with the time record group. Valid values are true and false. The default value is false. |
| `messageCode` | string (max 256, read-only) | Code for the message associated with the time record group. |
| `messageId` | integer (int64) (read-only) | Unique identifier for the message associated with the time record group. |
| `messageText` | string (max 240, read-only) | Text for the message associated with the time record group. |
| `ruleId` | integer (int64) (read-only) | Unique identifier for the rule from which messages were generated. |
| `ruleSetId` | integer (int64) (read-only) | Unique identifier for the rule set containing the rules from which messages were generated. |
| `ruleSetType` | string (max 32, read-only) | of the rule set containing the rules that messages were generated from, such as TCR for time calculation rule. |
| `severity` | string (max 30, read-only) | Severity for the message associated with the time record group. |
| `tag` | string (max 120, read-only) | Label attached to the message related to the time record group for identification. |
| `timeMessageTokens` | array | Time Message Tokens  Message Tokens The timeMessageTokens resource is a child of the timeMessages resource and a great-grandchild of the timeRecordGroups resource. It's a unique identifier for the tok |
| `messageTokenId` | integer (int64) (read-only) | Unique identifier for the message token. |
| `tokenName` | string (max 256, read-only) | of the token for the message associated with the time record group. |
| `tokenValue` | string (max 256, read-only) | for the token of the message associated with the time record group. |
| `displayValue` | string (max 80, read-only) | displayed for the time record group status, such as Submitted. |
| `statusCode` | string (max 32, read-only) | Code for the time record group status, such as D_TM_UI_STATUS for Time Card UI status. |


> _Showing 40 of 43 fields (core attributes). See Oracle docs for the full list._
### 5.2 POET / Project reference inputs

#### Projects (P + Organization)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projects`

#### Expenditure Types (E)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/expenditureTypes`

**Example Response Body**

```json
{
"items": [
  {
"ExpenditureTypeName": "Material Overhead",
"SystemLinkageFunction": "BTC",
"ExpenditureTypeId": 10027,
"ExpenditureTypeStartActiveDate": "1997-12-07",
"ExpenditureTypeEndActiveDate": "2005-01-01",
"SystemLinkageFunctionName": "Burden Transaction",
},
  {
"ExpenditureTypeName": "Poles",
"SystemLinkageFunction": "BTC",
"ExpenditureTypeId": 10161,
"ExpenditureTypeStartActiveDate": "2000-01-01",
"ExpenditureTypeEndActiveDate": "2000-01-01",
"SystemLinkageFunctionName": "Burden Transaction",
},
  {
"ExpenditureTypeName": "PJC_B&L_Expenses",
"SystemLinkageFunction": "ER",
"ExpenditureTypeId": 100000013998651,
"ExpenditureTypeStartActiveDate": "2008-01-01",
"ExpenditureTypeEndActiveDate": null,
"SystemLinkageFunctionName": "Expense Reports",
},
}
```


**Field Schema — `expenditureTypes`**

| Field | Type | Description |
|---|---|---|
| `ExpenditureTypeEndActiveDate` | string (date) (read-only) | Active finish date of an expenditure type. |
| `ExpenditureTypeId` | integer (int64) (read-only) | Unique identifier of an expenditure type. |
| `ExpenditureTypeName` | string (max 240, read-only) | Name of the expenditure type. |
| `ExpenditureTypeStartActiveDate` | string (date) (read-only) | Active start date of an expenditure type. |
| `SystemLinkageFunction` | string (max 3, read-only) | The system linkage that classifies the expenditure type in order to drive expenditure processing for the items classified by the expenditure type. |
| `SystemLinkageFunctionName` | string (max 80, read-only) | The system linkage name that classifies the expenditure type in order to drive expenditure processing for the items classified by the expenditure type. |

> Tasks (T): `GET /fscmRestApi/resources/11.13.18.05/projects/{ProjectId}/child/Tasks`

#### Project Labor Resources (validate/assign resource to project)

- **Method / Path:** `POST /fscmRestApi/resources/11.13.18.05/projectLaborResources`

**Example Request Body**

```json
{
"ProjectId":"300100190426224"
"ResourceId":"300100024326751",
"Name":"Devon Smith",
"Email":"prj_wf_in_grp@vision.com",
}
```

#### Project Resource Assignments (allocation)

- **Method / Path:** `POST /fscmRestApi/resources/11.13.18.05/projectResourceAssignments`

**Example Request Body**

```json
{
    "ProjectName": "zBIQA_Rel8_RM9",
    "ProjectRoleName": "Team Member",
    "ResourceEmail": "Veronica.Johnson@Oracle.com",
    "AssignmentStatusCode" : "ASSIGNED",
    "AssignmentLocation" : "San Francisco",
    "AssignmentStartDate" : "2019-06-27",
    "AssignmentEndDate" : "2019-06-27",
    "AssignmentComments" : "RRF-PJR Direct Assignment",
    "ProjectManagementFlowFlag": "false",    
    "UseProjectCalendarFlag": "false",
    "UseVariableHoursFlag": "true",
    "SundayHours": 1,
    "MondayHours": 2,
    "TuesdayHours": 3,
    "WednesdayHours": 4,
    "ThursdayHours": 5,
    "FridayHours": 6,
    "SaturdayHours": 7
}
```

**Example Response Body**

```json
{
"ResourceEmail" : "Olivia.Newman@Oracle.com",
"ProjectName" : "Test Project",
"ProjectRoleName" : "Team Member",
"AssignmentStatusCode" : "ASSIGNED",
"AssignmentLocation" : "San Francisco",
"AssignmentStartDate" : "2020-09-07",
"AssignmentEndDate" : "2020-09-27",
"AssignmentComments" : "Test",
"ProjectManagementFlowFlag": false,
"UseProjectCalendarFlag" : false,
"UseVariableHoursFlag" : false,
"UseWeeklyHoursFlag" : true,
"AssignmentHoursPerWeek":25
}
```

#### Person Assignment Labor Schedules (percentage allocation by POET)

- **Method / Path:** `POST /fscmRestApi/resources/11.13.18.05/personAssignmentLaborSchedules`

**Example Request Body**

```json
{
"PersonId": "300100026351987",
"AssignmentId": "300100026351999",
"PayElement": "Medical Employer Contribution",
"LegislativeDataGroupName":"US Legislative Data Group",
"LaborScheduleTypeCode": "ASE",

"versions":[{
"VersionName": "Vers-New1",
"VersionComments": "Version in Active Status",
"VersionStatus": "Active",
"VersionStartDate": "2019-07-12",
"VersionEndDate": "2019-08-11",
"distributionRules": [{
"LineNumber": 1,
"LinePercent": 100,
"ContractNumber": "Award 001",
"ProjectId": 300100061807046,
"TaskId": 100100037545950,
"ExpenditureOrganizationName": "Vision City Operations",
"WorkTypeId": 100000012472019,
"ExpenditureTypeId": 300100036998310,
"FundingSourceId": 300100038787369
}]
}]
}
```

#### Rate Schedules (valuation)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/rateSchedules`


### 5.3 OUTPUT to Payroll — Element Entries

#### Payroll Element Entries — create (where transferred hours land)

- **Method / Path:** `POST /hcmRestApi/resources/11.13.18.05/elementEntries`

**Example Request Body**

```json
{
   "PersonId": 300100003143709,
   "ElementTypeId": 300100003068055,
   "AssignmentId": 300100003143747,
   "EntryType": "E",
   "CreatorType": "F",
   "EntrySequence": 1,
   "elementEntryValues": [
   {
     "InputValueId": 300100003068067,
     "ScreenEntryValue": "1000"
   }
 ]
}
```

**Example Response Body**

```json
{
    "ElementEntryId": 300100559371979,
    "EffectiveStartDate": "2020-07-25",
    "EffectiveEndDate": "4712-12-31",
    "CreatorType": "F",
    "ElementTypeId": 300100003068055,
    "EntryType": "E",
    "EntrySequence": 1,
    "PersonId": 300100003143709,
    "Reason": null,
    "Subpriority": null,
    "PersonNumber": "300100003143709",
    "AssignmentId": 300100003143747,
    "AssignmentNumber": "E300100003143709",
    "PayrollRelationshipNumber": "300100003143743",
    "ElementName": "ZHRX_USP_RegEarnings_One",
    "UsageLevel": "PA",
    "elementEntryValues": {
        "items": []
    "links": [
        {
          ...}
    ]
}
               
            
            
         
                 Back to Top
```


**Field Schema — `elementEntries`**

| Field | Type | Description |
|---|---|---|
| `AssignmentId` | integer | Unique identifier for a person assignment. |
| `AssignmentNumber` | string (max 255, read-only) | Person's assignment number for the element entry. |
| `AutomaticEntry` | string (max 30, read-only) | Employment level of the element at which the entry is created. |
| `Category` | string (max 255, read-only) | Employment level of the element at which the entry is created. |
| `ClassificationId` | integer (int64) (read-only) | Employment level of the element at which the entry is created. |
| `CreatorType` | string (max 30) | Name of the user or the process that created the element entry record, such as batch element entry. |
| `CreatorTypeDisplayValue` | string (max 255, read-only) | Employment level of the element at which the entry is created. |
| `EffectiveEndDate` | string (date) | End Date Date at the end of the period within which the entry is available for processing with element entry identifier. |
| `EffectiveStartDate` | string (date) | Start Date Date at the beginning of the period within which the entry is available for processing. |
| `ElementEntryHistory` | array | Element Entry History  Entry History The elementEntryValues is a child of the elementEntries resource which includes values entered for an element, such as amount, periodicity, or rate. |
| `ElementEntryId` | integer (int64) | Unique identifier for an element entry. |
| `elementEntryValues` | array | Element Entry Values  Entry Values The elementEntryValues is a child of the elementEntries resource which includes values entered for an element, such as amount, periodicity, or rate. |
| `ElementName` | string (max 80) | of the element the entry is for, such as Performance Bonus. |
| `ElementTypeId` | integer (int64) | Unique identifier of the element type. |
| `EntrySequence` | integer (int64) | Unique number that identifies an element entry record when overlapping entries exists for the same element. |
| `EntryType` | string (max 30) | Type of the element entry, such as regular entry or override. |
| `InputCurrencyCode` | string (max 15, read-only) | Currency   Employment level of the element at which the entry is created. |
| `Intent` | string (max 200) | Apply internal finder validation. |
| `LegCode` | string (max 255, read-only) | Employment level of the element at which the entry is created. |
| `LegDataGroupId` | integer (int64) (read-only) | Employment level of the element at which the entry is created. |
| `OverrideFlag` | boolean (max 10, read-only) | Employment level of the element at which the entry is created. |
| `PayrollRelationshipNumber` | string (max 255, read-only) | Unique number that identifies the association between a person and a payroll statutory unit based on the payroll calculation and reporting requirements. |
| `PersonId` | integer (int64) | Unique identifier for a person. |
| `PersonNumber` | string (max 30, read-only) | Person number of the worker. |
| `PrimaryClassification` | string (max 120, read-only) | Employment level of the element at which the entry is created. |
| `ProcessingHistory` | array | Element Entries  Entries The elementEntries resource includes salary, benefits, or any other recurring or nonrecurring entries, such as bonus for a worker. |
| `ProcessingType` | string (max 30, read-only) | Processing Type   Employment level of the element at which the entry is created. |
| `ProcessingTypeDisplayValue` | string (max 10, read-only) | Employment level of the element at which the entry is created. |
| `Reason` | string (max 4000) | Reason for creating or updating an element entry. |
| `RetroActiveEntryFlag` | boolean (max 1, read-only) | Employment level of the element at which the entry is created. |
| `SecondaryClassification` | string (max 255, read-only) | Employment level of the element at which the entry is created. |
| `SettlementDate` | string (date) (read-only) | Employment level of the element at which the entry is created. |
| `StandardEntryUsage` | array | Element Entries  Entries The elementEntries resource includes salary, benefits, or any other recurring or nonrecurring entries, such as bonus for a worker. |
| `Subpriority` | integer (int32) | used to sequence the processing of element entries with the same priority. |
| `UsageLevel` | string (max 30, read-only) | Level   Employment level of the element at which the entry is created. |
| `MultipleEntryCount` | integer (int64) (read-only) | Unique identifier for an input value. |
| `BaseName` | string (max 80, read-only) | Unique identifier for the payroll |
| `DefaultValue` | string (max 60, read-only) | Default entry value for the element entry. |
| `DisplaySequence` | integer (int32) (read-only) | Sequence  Number assigned to an input value that determines the sequence in which the values appear. |
| `ElementEntryValueId` | integer (int64) | Unique identifier for an element entry value. |


> _Showing 40 of 73 fields (core attributes). See Oracle docs for the full list._
### 5.4 OUTPUT to Project Costing — read costed results

#### Project Costs (costed transactions)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projectCosts`

**Example Response Body**

```json
{
    "items": [
        {
            "TransactionNumber": 7873694,
            "BurdenedCostInProviderLedgerCurrency": 1500,
            "ProviderLedgerCurrencyCode": "USD",
            "ProviderLedgerCurrencyConversionRate": 1,
            "ProviderLedgerCurrencyConversionDate": "2011-11-01",
            "ProviderLedgerCurrencyConversionRateType": "100000013585009",
            "RawCostInProviderLedgerCurrency": 1500,
            "BillableFlag": true,
            "FundsStatus": "RESERVED_NO_CONTROL_BUD",
            "CapitalizableFlag": true,
            "ContractId": 300100047724342,
            "ConvertedFlag": null,
            "CreatedBy": "ABRAHAM.MASON",
            "CreationDate": "2019-06-17T10:28:22+00:00",
            "BurdenedCostInTransactionCurrency": 1500,
            "RawCostInTransactionCurrency": 1500,
            "DocumentEntryId": 100010023900193,
            "DocumentId": 100010023900192,
            "ExpenditureItemDate": "2011-11-01",
            "ExpenditureOrganizationId": 300100017216727,
            "ExpenditureTypeId": 10001,
            "AssignmentId": 300100026354770,
            "LastUpdateDate": "2019-06-17T10:28:22+00:00",
            "LastUpdatedBy": "ABRAHAM.MASON",
            "NonlaborResourceId": null,
            "NonlaborResourceOrganizationId": null,
            "OriginalTransactionReference": "7686832",
            "AccrualItemFlag": null,
            "PersonType": "EMP",
            "BurdenedCostInProjectCurrency": 1500,
            "ProjectId": 300100043916612,
            "RawCostInProjectCurrency": 1500,
            "Quantity": 100,
            "RawCostRateInTransactionCurrency": 15,
            "FundingSourceId": "300100038787369",
            "TaskId": 100100036066159,
            "TransactionSourceId": 100010023900191,
            "UnitOfMeasureCode": "HOURS",
            "WorkTypeId": 10020,
            "ExpenditureBusinessUnitId": 300100014554154,
            "ExpenditureBusinessUnit": "Vision City Operations",
            "TransactionSource": "PROJECTS",
            "Document": "Time Card",
            "DocumentEntry": "Straight Time",
            "ProjectName": "GMS Dev Res Spons Project1",
            "Proj
```

#### Project Expenditure Items

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projectExpenditureItems`

**Example Response Body**

```json
{
  "items" : [ {
    "ExternalBillRate" : null,
    "ExternalBillRateCurrency" : null,
    "ExternalBillRateSourceName" : null,
    "ExternalBillRateSourceReference" : null,
    "ExpenditureItemId" : 19803,
    "IntercompanyBillRate" : null,
    "IntercompanyBillRateCurrency" : null,
    "IntercompanyBillRateSourceName" : null,
    "IntercompanyBillRateSourceReference" : null,
    "links" : [ ...
 ]
  }, {
    "ExternalBillRate" : null,
    "ExternalBillRateCurrency" : null,
    "ExternalBillRateSourceName" : null,
    "ExternalBillRateSourceReference" : null,
    "ExpenditureItemId" : 19804,
    "IntercompanyBillRate" : null,
    "IntercompanyBillRateCurrency" : null,
    "IntercompanyBillRateSourceName" : null,
    "IntercompanyBillRateSourceReference" : null,
    "links" : [ ...
]
  }, {
    "ExternalBillRate" : null,
    "ExternalBillRateCurrency" : null,
    "ExternalBillRateSourceName" : null,
    "ExternalBillRateSourceReference" : null,
    "ExpenditureItemId" : 19845,
    "IntercompanyBillRate" : null,
    "IntercompanyBillRateCurrency" : null,
    "IntercompanyBillRateSourceName" : null,
    "IntercompanyBillRateSourceReference" : null,
    "links" : [ ... ]
  }, {
    "ExternalBillRate" : null,
    "ExternalBillRateCurrency" : null,
    "ExternalBillRateSourceName" : null,
    "ExternalBillRateSourceReference" : null,
    "ExpenditureItemId" : 19846,
    "IntercompanyBillRate" : null,
    "IntercompanyBillRateCurrency" : null,
    "IntercompanyBillRateSourceName" : null,
    "IntercompanyBillRateSourceReference" : null,
    "links" : [ ...]
  }
            
         
                 Back to Top
```

> Direct costing POST is not available; approved time is staged into `PJC_TXN_XFACE_ALL` and costed by *Import and Process Cost Transactions*. REST staging alternative: `projectExpenditureBatches` (GET/PATCH), then run the import.

### 5.5 ABSENCE — default & record on the time card

#### Absences — create/record

- **Method / Path:** `POST /hcmRestApi/resources/11.13.18.05/absences`

**Example Request Body**

```json
{
	"personNumber": "955160008182159",
	"employer": "Vision Corporation",
	"absenceType": "  ANC_VISION_SICKNESS_TYPE2",
	"startDate": "2017-08-10",
	"startTime": "08:00",
	"endDate": "2017-08-10",
	"endTime": "17:00",
	"absenceStatusCd": "SUBMITTED"
}
```

**Example Response Body**

```json
{
	"absenceEntryBasicFlag": true,
	"absencePatternCd": "II",
	"absenceStatusCd": "SUBMITTED",
	"absenceTypeId": 300100037938175,
	"absenceTypeReasonId": null,
	"blockedLeaveCandidate": null,
	"comments": null,
	"conditionStartDate": null,
	"confirmedDate": null,
	"createdBy": "HCM_USER10",
	"creationDate": "2017-10-09T02:25:07-07:00",
	"duration": 1,
	"endDate": "2017-08-10",
	"endDateDuration": null,
	"endDateTime": "2017-08-10T17:00:00-07:00",
	"endTime": "17:00",
	"lastUpdateDate": "2017-10-09T02:26:21.244-07:00",
	"lastUpdateLogin": "5AE04B480C095BDCE0530703F00A5255",
	"lastUpdatedBy": "HCM_USER10",
	"lateNotifyFlag": null,
	"notificationDate": null,
	"objectVersionNumber": 2,
	"openEndedFlag": false,
	"overridden": "N",
	"personAbsenceEntryId": 300100116862835,
	"personId": 300100052398992,
	"singleDayFlag": true,
	"source": "REST",
	"startDate": "2017-08-10",
	"startDateDuration": null,
	"startDateTime": "2017-08-10T08:00:00-07:00",
	"startTime": "08:00",
	"submittedDate": "2017-10-09",
	"unitOfMeasure": "D",
	"userMode": "ADMIN",
	"personNumber": "955160008182159",
	"absenceType": "  ANC_VISION_SICKNESS_TYPE2",
	"employer": "Vision Corporation",
	"absenceReason": null,
	"absenceDispStatus": null,
	"dataSecurityPersonId": 300100052398992,
	"effectiveStartDate": "2014-01-01",
	"effectiveEndDate": "4712-12-31",
	"links": [11]
         0:  {...
            ...}
}
```


**Field Schema — `absences`**

| Field | Type | Description |
|---|---|---|
| `absenceAttachments` | array | Absence Attachments  Attachments The absence attachments resource provides the attached documents added to the absence transactions. |
| `absenceCaseId` | integer (int64) | — |
| `absenceDispStatus` | string | Absence processing status displayed to the user. Valid values are defined in the lookup ANC_PER_ABS_ENT_DISPLAY_STATUS. |
| `absenceDispStatusMeaning` | string (max 255, read-only) | Description of the absence transaction status. |
| `absenceEntitlements` | array | Absence Entitlements  Entitlements The absenceEntitlements resource is a child of the absences resource. It provides a list of all the entitlements consumed by an absence. |
| `absenceEntitlementUniquePlans` | array | Absence Entitlement Unique Plans  Entitlement Unique Plans The absenceEntitlementUniquePlans resource provides information about the employee absences associated with the entitlement plan of the same |
| `absenceEntryBasicFlag` | boolean (max 30) | Mode Indicator  Default Value: false Indicates whether the absence is recorded in basic mode or advanced mode. The default value is true. |
| `absenceEntryCertifications` | array | Absence Certifications  Certifications The absenceEntryCertifications resource provides the list of all certifications entered as part of an absence. |
| `absenceEntryDetails` | array | Absence Entry Details  Entry Details The absenceEntryDetails resource provides a individual day breakdown and a shift breakdown of the absence request dates. |
| `absenceMaternity` | array | Absence Maternity Details  Maternity Details The absenceMaternity resource is a child of the absences resource. It provides details of maternity attributes when absence type is maternity. |
| `absencePatternCd` | string (max 20) | Unique code assigned to the absence pattern associated with an absence type. For example, absence pattern can be Generic for a vacation absence, Illness or injury for a sickness absence. |
| `absenceReason` | string | Reason for absence attached to the absence type. |
| `absenceRecordingsDDF` | array | absenceRecordingsDDF |
| `absenceStatusCd` | string (max 30) | Default Value: 'SUBMITTED' Absence status, such as submitted, withdrawn. |
| `absenceType` | string | Unique identifier for the absence type. |
| `absenceTypeId` | integer (int64) | Unique identifier for the absence type. |
| `absenceTypeReasonId` | integer (int64) | Unique identifier for the absence reason. |
| `absenceUpdatableFlag` | boolean (max 255, read-only) | Indicates whether the absence can be updated. If true, the absence can be updated. If false, the absence can't be updated. |
| `agreementId` | integer (int64) | Name |
| `agreementName` | string | of the agreement used to record absence. |
| `allowAssignmentSelectionFlag` | boolean (read-only) | Indicates whether an assignment can be selected for the absence transaction. If true, an assignment can be selected and shown on the absence transaction. |
| `ApprovalDatetime` | string (date-time) (read-only) | and time of the absence approval. |
| `approvalStatusCd` | string (max 30) | Status |
| `assignmentId` | integer (int64) | Unique identifier of the assignment for which the absence is recorded. When an employee has multiple active assignments, this attribute can be used to restrict the absence to a specific assignment. Yo |
| `assignmentName` | string (max 80, read-only) | Name of the worker's assignment. |
| `assignmentNumber` | string (max 30, read-only) | Number of the worker's assignment. |
| `authStatusUpdateDate` | string (date) | Last Updated |
| `bandDtlId` | integer (int64) | Detail |
| `blockedLeaveCandidate` | string (max 30) | Leave Status  Determines whether the worker is eligible for block leave or not. Block leave enables workers to report a fixed period away from work. |
| `certificationAuthFlag` | boolean (max 30) | absence |
| `childEventTypeCd` | string (max 30) | — |
| `comments` | string (max 2000) | Comments provided while recording the absence. |
| `conditionStartDate` | string (date) | Start Date Condition start date of an illness or injury leave. Used to indicate when the illness began or injury occurred, and could be different from the absence start date. |
| `confirmedDate` | string (date) | Confirmed start date of an absence. |
| `consumedByAgreement` | string (max 30) | — |
| `createdBy` | string (max 64, read-only) | of the employee who created the absence record. |
| `creationDate` | string (date-time) (read-only) | and time of the absence record creation. |
| `dataSecurityPersonId` | integer (int64) (read-only) | Unique person identifier assigned to verify data security. |
| `diseaseCode` | string (max 250) | Code |
| `duration` | number | Duration of the recorded absence. |
| `effectiveEndDate` | string (date) (read-only) | End date to check data security. |
| `effectiveStartDate` | string (date) (read-only) | Start date to check data security. |
| `employeeShiftFlag` | boolean (max 20) | — |
| `employer` | string | of the employer. |
| `endDate` | string (date) | End date of the recorded absence. |


> _Showing 45 of 374 fields (core attributes). See Oracle docs for the full list._
> Use `planBalances` (`GET /hcmRestApi/.../planBalances`) to validate available balance before defaulting an absence onto the card. LOVs: `absenceTypesLOV`, `absencePlansLOV`, `absenceTypeReasonsLOV`.

---

## 6. Physical Database Tables & Views

Where each type of data is physically stored in the Fusion schema. Sourced from **Tables and Views for Project Management** (`oedpp`) and **Tables and Views for HCM** (`oedmh`), release 26C. Suffix conventions: `_B` = base, `_TL` = translations, `_VL` = translated view, `_F` = date-effective, `_ALL` = multi-org, `_V`/`_VL` = view, `_INT`/`_XFACE` = interface/staging.

### 1. POET information

| Table / View | Module | Stores |
|---|---|---|
| `PJF_PROJECTS_ALL_B / _VL` | Projects | Base/translated project header — the 'P' and owning organization of POET. |
| `PJF_PROJ_ELEMENTS_B / _VL` | Projects | Project tasks (WBS elements) — the 'T' of POET. |
| `PJF_TASKS_V` | Projects | View exposing task attributes for a project. |
| `PJF_EXP_TYPES_B / _TL / _VL` | Projects | Expenditure types — the 'E' of POET. |
| `PJF_PROJ_ELEMENT_VERSION` | Projects | Financial vs. work-plan task structure versions. |

### 2. Project resources

| Table / View | Module | Stores |
|---|---|---|
| `PJF_PROJECT_PARTIES` | Projects | Project team members / resources assigned to a project. |
| `PJF_PROJECT_PARTIES_H` | Projects | History of project party (resource) assignments. |
| `PJT_PROJECT_RESOURCE` | Projects | Enterprise/project resource records. |
| `PJR_RESOURCE_CONDITIONS_B` | Resource Mgmt | Resource qualification/condition data. |

### 3. Project task

| Table / View | Module | Stores |
|---|---|---|
| `PJF_PROJ_ELEMENTS_B / _VL` | Projects | Task (WBS element) master. |
| `PJF_TASKS_V` | Projects | Task view. |
| `PJF_PROJ_ELEMENT_VERSION` | Projects | Financial vs. work-plan task structure versions. |
| `PJO_PLANNING_ELEMENTS` | Project Control | Planning resources/tasks for budgets & forecasts. |

### 4. Project allocation

| Table / View | Module | Stores |
|---|---|---|
| `PJR_ASSIGNMENT` | Resource Mgmt | Resource-to-project assignments (allocation). |
| `PJR_ASSIGNMENT_INT` | Resource Mgmt | Interface staging for resource assignments. |
| `PJR_AVAIL_ASSIGN` | Resource Mgmt | Assignment availability. |
| `PJR_ACTUAL_HOURS` | Resource Mgmt | Actual reported hours by resource assignment. |
| `HWM_ALLOCATIONS_HDR_F` | Workforce Mgmt (OTL) | Time allocation header — how time is split across POET on a time card. |
| `HWM_ALLOCATION_LINES_F` | Workforce Mgmt (OTL) | Time allocation lines (per project/task split). |
| `HWM_ALLOCATION_RULES_F` | Workforce Mgmt (OTL) | Allocation rules used to default splits. |

### 5. Project resource cost

| Table / View | Module | Stores |
|---|---|---|
| `PJC_EXP_ITEMS_ALL` | Project Costing | Expenditure items — costed transactions (result of processed time). |
| `PJC_COST_DIST_LINES_ALL` | Project Costing | Cost distribution lines (accounting) for expenditure items. |
| `PJC_EXP_GROUPS_ALL` | Project Costing | Expenditure batches/groups. |
| `PJC_TXN_XFACE_ALL` | Project Costing | Transaction import interface — external costs/time land here before processing. |
| `PJF_RATE_SCHEDULES_B / _VL` | Projects | Cost/bill rate schedules used to value resource time. |
| `PJF_RATE_SCHEDULE_LINES` | Projects | Individual rate lines within a schedule. |

### 6. Time → Payroll

| Table / View | Module | Stores |
|---|---|---|
| `HWM_TM_REC` | Workforce Mgmt (OTL) | Posted time records (the repository). |
| `HWM_TM_REC_EVENTS` | Workforce Mgmt (OTL) | Time record events (start/stop or quantity). |
| `HWM_TM_REC_EVENT_ATRBS` | Workforce Mgmt (OTL) | Attributes on each event (PayrollTimeType, POET, etc.). |
| `HWM_TM_REC_EVENT_REQS` | Workforce Mgmt (OTL) | Time record event requests (from timeRecordEventRequests REST). |
| `HWM_TIME_ENTRIES` | Workforce Mgmt (OTL) | Time entries on a time card. |
| `HWM_TIMECARDS` | Workforce Mgmt (OTL) | Time card headers. |
| `HWM_XFRS_UNQ_RECS / HWM_XFR_READY_REC_GRP` | Workforce Mgmt (OTL) | Transfer-ready records for downstream (Payroll/Projects). |
| `PAY_ELEMENT_ENTRIES_F` | Global Payroll | Element entries — where transferred time hours land in Payroll. |
| `PAY_ELEMENT_ENTRY_VALUES_F` | Global Payroll | Input values (hours, rate) on element entries. |
| `PAY_TIME_DEFINITIONS / PAY_TIME_PERIODS` | Global Payroll | Payroll time definitions and periods. |

### 7. Approved time → Costing

| Table / View | Module | Stores |
|---|---|---|
| `PJC_TXN_XFACE_ALL` | Project Costing | Interface table that receives approved time as unprocessed cost transactions. |
| `PJC_EXP_GROUPS_ALL` | Project Costing | Batch/group of imported transactions. |
| `PJC_EXP_ITEMS_ALL` | Project Costing | Costed expenditure items after 'Import and Process Cost Transactions'. |
| `PJC_COST_DIST_LINES_ALL` | Project Costing | Accounting distributions for the costed items. |
| `PJC_TXN_ERRORS` | Project Costing | Errors raised during transaction import/costing. |

### 8. Shift / work pattern / schedule

| Table / View | Module | Stores |
|---|---|---|
| `HTS_WORK_PATTERNS_B / _VL` | Workforce Scheduling | Work pattern definitions. |
| `HTS_WORK_PATTERN_SHIFTS` | Workforce Scheduling | Shifts within a work pattern. |
| `HTS_WORK_PATTERN_ASSIGNMENTS` | Workforce Scheduling | Work pattern assigned to workers. |
| `HTS_CORE_WORK_SHIFTS` | Workforce Scheduling | Core shift definitions. |
| `PER_SCHEDULE_ASSIGNMENTS` | Global HR | Work schedule assigned to a person/assignment. |
| `PER_SCHEDULE_ELIGIBILITY` | Global HR | Eligibility linking schedules to workers. |

### 9. Calendar & holidays

| Table / View | Module | Stores |
|---|---|---|
| `PER_CALENDAR_EVENTS / _TL / _VL` | Global HR | Calendar events including holidays. |
| `PER_CAL_EVENT_COVERAGE` | Global HR | Coverage (which workers/geographies a calendar event applies to). |
| `PER_SCHEDULE_EXCEPTIONS` | Global HR | Exceptions (non-working days) applied to a schedule. |
| `ANC_CALENDAR_B / _VL` | Absence Mgmt | Absence calendar definitions. |
| `ANC_CAL_EVENTSET_EVENT` | Absence Mgmt | Calendar event sets used by absence plans. |

### 10. Default absence record

| Table / View | Module | Stores |
|---|---|---|
| `ANC_PER_ABS_ENTRIES` | Absence Mgmt | Person absence entries — the recorded absence. |
| `ANC_PER_ABS_ENTRY_DTLS` | Absence Mgmt | Daily/detail breakdown of an absence entry. |
| `ANC_PER_ABS_DAILY_DTLS` | Absence Mgmt | Daily duration details for the absence. |
| `ANC_ABSENCE_TYPES_F` | Absence Mgmt | Absence type configuration. |
| `ANC_ABSENCE_PLANS_F` | Absence Mgmt | Absence plan configuration. |
| `ANC_PER_ACRL_ENTRY_DTLS` | Absence Mgmt | Accrual entry details / balances. |

---

## 7. Build Instructions (for the AI coding assistant)

Use this document as the complete functional + integration spec. Implement the module in these layers:

**A. Data capture layer.** Build a time-card UI + service that creates time entries and submits them via `POST /hcmRestApi/resources/11.13.18.05/timeRecordEventRequests` with `processMode="TIME_SUBMIT"`. On each event, populate `timeRecordEvent` (start/stop or quantity, reporterId, assignmentNumber) and `timeRecordEventAttribute` name/value pairs for **PayrollTimeType**, project **POET** (ProjectId, TaskId, ExpenditureType, Organization), and **Absence type** as applicable.

**B. Reference/defaulting layer.** Populate pickers and defaults from: `projects`, `projects/{id}/child/Tasks`, `expenditureTypes`, `projectLaborResources`, `projectResourceAssignments`/`personAssignmentLaborSchedules` (to default POET allocation), `rateSchedules`, `absenceTypesLOV`+`planBalances`, and the workforce schedule resources (for expected hours / non-working days).

**C. Validation layer.** Enforce: worker has Time Card Required; POET is valid & the person is a valid project resource; absence balance available; hours vs. schedule. Mirror OTL's time categories / rules where needed.

**D. Approval layer.** Manager approval workflow; only approved entries are eligible for transfer.

**E. Routing + output layer.** For each approved entry, classify by Time Type and apply the **consumer set** logic (Section 4). Then:
- *Payroll:* transfer hours to `elementEntries` (or trigger the Load Time Card Batches process).
- *Project Costing:* stage to `PJC_TXN_XFACE_ALL` / `projectExpenditurebatches` and run Import and Process Cost Transactions; read results from `projectCosts`/`projectExpenditureItems`.
- *Absence:* record via `absences`.

**F. Data model.** If persisting locally, mirror the semantics of the tables in Section 6 (time repository = `HWM_TM_REC*`; allocations = `HWM_ALLOCATIONS_*`; outputs = `PAY_ELEMENT_ENTRIES_F`, `PJC_EXP_ITEMS_ALL`, `ANC_PER_ABS_ENTRIES`).

**Key invariants to preserve:**
1. The three time attributes (Payroll Time Type, Expenditure Type, Absence Type) are the routing keys — never drop them.
2. POET must be fully resolved before an entry can cost to a project.
3. Capture is REST; transfer to Payroll/Projects is process-driven (ESS), not a synchronous REST push.
4. A single entry can go to multiple consumers (e.g. Projects **and** Payroll).

---
*Compiled from Oracle Fusion Cloud documentation, release 26C: REST API (`farws`, `fapap`), Tables & Views (`oedmh`, `oedpp`), and Implementing Time and Labor (`faitl`). Field schemas trimmed to core attributes; verify full column lists, flexfields, exact ESS process names, and security privileges against your pod before build.*
