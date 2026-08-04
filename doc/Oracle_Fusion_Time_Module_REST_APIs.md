# Oracle Fusion REST APIs for a Custom Time Module (OTL Replacement)

> Compiled from Oracle Fusion Cloud REST API documentation (HCM `farws` and Project Management `fapap`, release 26C).
> **Base paths:** HCM = `/hcmRestApi/resources/11.13.18.05/` · Projects/PPM = `/fscmRestApi/resources/11.13.18.05/`
> Authentication: Basic Auth or OAuth 2.0 over HTTPS. Header: `Content-Type: application/json`.

## Architecture Overview

| Requirement | Nature | Mechanism |
|---|---|---|
| 1. POET information | REST (reference data) | `projects`, task, `expenditureTypes`, org |
| 2. Project resources | REST | `projectEnterpriseResources`, `projectLaborResources` |
| 3. Project task | REST | `projects/{id}/child/Tasks`, `projectPlans/{id}/child/Tasks`, `projectFinancialTasks` |
| 4. Project allocation | REST | `projectResourceAssignments`, `personAssignmentLaborSchedules` |
| 5. Project resource cost | REST | `projectCosts`, `projectExpenditureItems`, `rateSchedules` |
| 6. Time → Payroll | REST + ESS process | `timeRecordEventRequests` capture; transfer via **Load Time Card Batches** → `elementEntries` |
| 7. Approved time → Costing | ESS process (+ REST read) | **Import & Process Cost Transactions**; results in `projectCosts`/`projectExpenditureItems` |
| 8. Shift / work pattern / schedule | Config + partial REST | Work Schedules via HDL; `workforceScheduleDefinitions`, `workforceScheduleShifts` |
| 9. Calendar & holidays | Config (HDL) | Calendar Events / schedule exceptions |
| 10. Default absence record | REST | `absences`, `planBalances` |

---

## 1. POET Information

POET = **P**roject, **O**rganization, **E**xpenditure type, **T**ask — the charge string a time entry uses to cost to a project. It is assembled from several resources (there is no single "POET" endpoint).

#### Projects (the "P" and org source)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projects`

**Example Response Body**

```json
{
   -items: [25]
   -0: {
      BusinessUnitId: 204
      BusinessUnitName: "Vision Operations"
      ExternalProjectId: null
      HoursPerDay: null
      LegalEntityId: 204
      LegalEntityName: "Vision Operations"
      ...
       }
   -1: {
      ...
       }
  ...
}
```

#### Expenditure Types (the "E")

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

> The **Task ("T")** comes from the Project Tasks resource (see Section 3). **Organization ("O")** is derived from the project's owning/expenditure organization and the person's assignment.

---

## 2. Project Resources
#### Project Enterprise Resources (all enterprise resources)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projectEnterpriseResources`

**Example Response Body**

```json
{
  "items": [
    {
      "ResourceEmail": "george_white_in_grp@oracle.com",
      "ResourceId": 300100023180799,
      "ResourceDisplayName": "George White",
      "ResourceType": "NAMED_PERSON",
      "ResourceProjectPrimaryRole": "Oracle DBA",
      "links": [
        ...
      ]
    },
    
            
         
                 Back to Top
```

#### Project Labor Resources – list

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projectLaborResources`

**Example Response Body**

```json
{
"items": [
  {
"ProjectId": 300100169584611,
"ProjectRoleId": 13,
"DefaultStaffingOwnerFlag": null,
"ResourceId": 300100023180799,
"Name": "George White",
"Email": "prj_george_white_in_grp@oracle.com",
"ProjectRoleName": "Team Member",
"ProjectResourceAssignmentId": null,
"CreatedBy": "ABRAHAM.MASON",
"CreationDate": "2018-11-29T08:19:44.369+00:00",
"LastUpdatedBy": "ABRAHAM.MASON",
"LastUpdateDate": "2018-11-29T08:19:44.413+00:00",
"Allocation": 100,
"LaborEffort": null,
"AssignmentStatusCode": "PLANNING_ONLY",
"AssignmentStatus": "Planned",
"LaborBillRate": null,
"LaborCostRate": null,
"FromDate": null,
"ToDate": null,
"ProjResourceId": 300100169584643,
"ProjectCurrencyCode": "USD"
}
```

#### Project Labor Resources – add resource to a project

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


---

## 3. Project Task

Tasks are exposed as a child of Projects and of Project Plans, plus a dedicated financial-tasks resource.

- **All tasks of a project:** `GET /fscmRestApi/resources/11.13.18.05/projects/{ProjectId}/child/Tasks`
- **Work-plan tasks:** `GET /fscmRestApi/resources/11.13.18.05/projectPlans/{ProjectId}/child/Tasks`
- **Financial (billable/costable) tasks:** `GET /fscmRestApi/resources/11.13.18.05/projectFinancialTasks`

#### Project Plans (contains task structure)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projectPlans`

**Example Response Body**

```json
{
"items": [
  {
"CalendarId": 300100010293735,
"CurrencyCode": "USD",
"Description": null,
"EndDate": null,
"FinanciallyEnabledFlag": false,
"Name": "TAP_PJT_Draft_Project ",
"OrganizationId": -1,
"PercentComplete": 0,
"PrimaryProjectManagerName": "Connor Horton",
"ProjectId": 300100038328105,
"ProjectNumber": "300100038328105",
"ScheduleTypeCode": "FIXED_EFFORT",
"StartDate": "2014-07-01",
"Status": "Submitted",
"StatusCode": "SUBMITTED",
"ViewAccessCode": "ORA_PJT_PRJ_PLAN_VIEW_TEAM",
"ProjectCode01": null,
"ProjectCode02": null,
"ProjectCode03": null,
"ProjectCode04": null,
"ProjectCode05": null,
"ProjectCode06": null,
"ProjectCode07": null,
"ProjectCode08": null,
"ProjectCode09": null,
"ProjectCode10": null,
"ProjectCode11": null,
"ProjectCode12": null,
"ProjectCode13": null,
"ProjectCode14": null,
"ProjectCode15": null,
"ProjectCode16": null,
"ProjectCode17": null,
"ProjectCode18": null,
"ProjectCode19": null,
"ProjectCode20": null,
"ProjectCode21": null,
"ProjectCode22": null,
"ProjectCode23": null,
"ProjectCode24": null,
"ProjectCode25": null,
"ProjectCode26": null,
"ProjectCode27": null,
"ProjectCode28": null,
"ProjectCode29": null,
"ProjectCode30": null,
"ProjectCode31": null,
"ProjectCode32": null,
"ProjectCode33": null,
"ProjectCode34": null,
"ProjectCode35": null,
"ProjectCode36": null,
"ProjectCode37": null,
"ProjectCode38": null,
"ProjectCode39": null,
"ProjectCode40": null,
"TextAttr01": null,
"TextAttr02": null,
"TextAttr03": null,
"TextAttr04": null,
"TextAt
```


---

## 4. Project Allocation

How a person's effort is allocated/assigned across projects and tasks.

#### Project Resource Assignments – list

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projectResourceAssignments`

#### Project Resource Assignments – create

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

#### Person Assignment Labor Schedules – list (percentage allocation by POET)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/personAssignmentLaborSchedules`

#### Person Assignment Labor Schedules – create

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


---

## 5. Project Resource Cost

#### Project Costs – query costed transactions

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

#### Project Expenditure Items – query processed/costed items

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

#### Rate Schedules – cost/bill rates used to value time

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/rateSchedules`

> **Note:** `projectCosts` supports **GET** and **PATCH** (and an `adjustProjectCosts` action) but **not a direct POST** — cost transactions are created by the *Import and Process Cost Transactions* process (see Section 7), not created ad-hoc via REST.

---

## 6. How OTL Sends Time (Hours) to Payroll

**Step A — Capture time (REST):** OTL records time through the **Time Record Event Requests** resource. `processMode: "TIME_SUBMIT"` posts the entry to the time repository. Payroll/project attributes (e.g. `PayrollTimeType`) are passed as `timeRecordEventAttribute` name/value pairs.

#### Time Record Event Requests – submit time

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

#### Time Record Event Requests – get by id

- **Method / Path:** `GET /hcmRestApi/resources/11.13.18.05/timeRecordEventRequests/{timeRecordEventRequestId}`

**Example Response Body**

```json
{
    "timeRecordEventRequestId": 300100123220029,
    "processMode": "TIME_SUBMIT",
    "processInline": null,
    "links": [...]
}
```

#### Time Records – read a posted record (read-only)

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

**Step B — Transfer to Payroll (ESS process, not REST):** The **"Load Time Card Batches" / "Transfer Time Cards from Time and Labor to Payroll"** scheduled process moves approved hours into Payroll as **Element Entries**. Your custom module either triggers this process or writes element entries directly:

#### Payroll Element Entries – list

- **Method / Path:** `GET /hcmRestApi/resources/11.13.18.05/elementEntries`

**Example Response Body**

```json
{
  "items": [ {
    "ElementEntryId": 300100004914639,
    "EffectiveStartDate": "2010-01-01",
    "EffectiveEndDate": "4712-12-31",
    "CreatorType": "F",
    "ElementTypeId": 300100003068055,
    "EntryType": "E",
    "EntrySequence": null,
    "PersonId": 300100003143709,
    "Reason": null,
    "Subpriority": null,
    "PersonNumber" : "300100003143709",
    "AssignmentId": null,
    "AssignmentNumber": "E300100003143709",
    "PayrollRelationshipNumber": "300100003143743",
    "ElementName": "ZHRX_USP_RegEarnings_One",
    "UsageLevel": "PA",
    "links": [
        {
          ...}
    ]
}
               
            
            
         
                 Back to Top
```

#### Payroll Element Entries – create

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

> Supporting LOVs: `payrollTimeDefinitionsLOV`, `payrollTimePeriodsLOV`, `payrollElementDefinitionLOV`, `payrollRelationships`.


---

## 7. After Manager Approval → Sending Time to Project Costing

This is **process-driven**, not a single REST push. After approval:

1. **Transfer Time to Projects** — moves approved time from Time & Labor to Project Costing as *unprocessed* transactions.
2. **Import and Process Cost Transactions** — costs the transactions (applies rates/burdening).

Results become queryable via:

- `GET /fscmRestApi/resources/11.13.18.05/projectCosts`
- `GET /fscmRestApi/resources/11.13.18.05/projectExpenditureItems`

**REST alternative for a fully custom module:** stage external transactions with **Project Expenditure Batches** and then run the import.

- `GET/PATCH /fscmRestApi/resources/11.13.18.05/projectExpenditureBatches` (submit a batch)
- Costing adjustments: `POST /fscmRestApi/resources/11.13.18.05/projectCosts/{ProjectCostsUniqID}/action/adjustProjectCosts`

---

## 8. Employee Shift, Work Pattern & Schedule

Work schedules and patterns are primarily **setup/config** (HCM Data Loader objects "Work Schedule" and "Work Schedule Assignment"). REST resources available:

**Workforce Scheduling**
- `workforceScheduleDefinitions` — `GET /hcmRestApi/resources/11.13.18.05/workforceScheduleDefinitions`
- `workforceScheduleShifts` — `GET /hcmRestApi/resources/11.13.18.05/workforceScheduleShifts`
- `scheduleRequests`, `staffingGrids`, `schedulingShiftsLOV`

**Time & Labor**
- `timeLayoutSets`, `webClockEvents`, `geofences`

> For a specific person's assigned schedule/pattern/availability, use HDL (Work Schedule Assignment) — it is not a first-class writable REST resource.

---

## 9. Calendar & Holidays

Holiday calendars are modeled as **Calendar Events / work-schedule exceptions** (configuration, loaded via HDL). Non-working days for a worker are derived from their assigned Work Schedule Definition and its exceptions. Query via the Workforce Schedule Definition/Shift resources listed in Section 8.

---

## 10. Default the Absence Record

#### Absences – list

- **Method / Path:** `GET /hcmRestApi/resources/11.13.18.05/absences`

**Example Response Body**

```json
{
  "items" : [ {
	"absenceEntryBasicFlag" : true,
	"absencePatternCd" : "GENERIC",
	"absenceStatusCd" : "SAVED",
	"absenceTypeId" : 300100107398880,
	"absenceTypeReasonId" : null,
	"blockedLeaveCandidate" : "NA",
	"comments" : null,
	"conditionStartDate" : null,
	"confirmedDate" : null,
	"createdBy" : "ZHRA-LNMGR1",
	"creationDate" : "2017-07-04T08:01:45-07:00",
	"duration" : 8.5,
	"endDate" : "2017-07-04",
	"endDateDuration" : null,
	"endDateTime" : "2017-07-04T17:00:00-07:00",
	"endTime" : "17:00",
	"lastUpdateDate" : "2017-07-04T08:07:29.580-07:00",
	"lastUpdateLogin" : "53801BEEE624A011E0530703F00A9F33",
	"lastUpdatedBy" : "ZHRA-LNMGR1",
	"lateNotifyFlag" : null,
	"notificationDate" : "2017-07-04",
	"objectVersionNumber" : 2,
	"openEndedFlag" : false,
	"overridden" : "N",
	"personAbsenceEntryId" : 300100109892733,
	"personId" : 923460008154805,
	"singleDayFlag" : true,
	"source" : "ANC",
	"startDate" : "2017-07-04",
	"startDateDuration" : null,
	"startDateTime" : "2017-07-04T08:30:00-07:00",
	"startTime" : "08:30",
	"submittedDate" : null,
	"unitOfMeasure" : "H",
	"userMode" : "EMP",
	"personNumber" : null,
	"absenceType" : null,
	"employer" : null,
	"absenceReason" : null,
	"absenceDispStatus" : null,
	"dataSecurityPersonId" : 923460008154805,
	"effectiveStartDate" : "2003-01-01",
	"effectiveEndDate" : "4711-12-31",
		"links":[18]
            0:  {...
               ...}
     }
  {
	"absenceEntryBasicFlag" : true,
	"absencePatternCd" : "II",
	"absenceStatusCd" : "SUBMITTED",
	"absenceTypeId" : 300100037938140,
	"absenceTypeReasonId" : null,
	"blockedLeaveCandidate" : "NA",
	"comments" : null,
	"conditionStartDate" : null,
	"confirmedDate" : null,
	"createdBy" : "HR_SPEC_ALL",
	"creationDate" : "2017-09-21T23:29:00-07:00",
	"duration" : 1,
	"endDate" : "2017-10-02",
	"endDateDuration" : null,
	"endDateTime" : "2017-10-02T17:00:00-07:00",
	"endTime" : "17:00",
	"lastUpdateDate" : "2017-09-21T23:29:53.218-07:00",
	"lastUpdateLogin" : "599C27BE3B444555E0530703F00AC9C7",
	"lastUpdatedBy" : "HR_SPEC_ALL",
	"lateNotifyFlag" : false,
	"notificationDate" : "2017-09-21",
	"objectVersionNumber" : 1,
	"openEndedFlag" : false,
	"overridden" : "N",
	"personAbsenceEntryI
```

#### Absences – create/record absence

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

#### Plan Balances – available balance

- **Method / Path:** `GET /hcmRestApi/resources/11.13.18.05/planBalances`

> Supporting LOVs: `absenceTypesLOV`, `absenceTypeReasonsLOV`, `absencePlansLOV`, `absenceBusinessTitlesLOV`. `absencesNoEntitlements` records absences without entitlement processing.

---

## Quick Endpoint Index

| # | Purpose | Method | Resource path |
|---|---|---|---|
| 1 | Projects (POET-P/O) | GET/POST/PATCH | `/fscmRestApi/.../projects` |
| 1 | Expenditure Types (POET-E) | GET | `/fscmRestApi/.../expenditureTypes` |
| 2 | Enterprise resources | GET | `/fscmRestApi/.../projectEnterpriseResources` |
| 2 | Project labor resources | GET/POST/PATCH/DELETE | `/fscmRestApi/.../projectLaborResources` |
| 3 | Project tasks | GET | `/fscmRestApi/.../projects/{id}/child/Tasks` |
| 3 | Financial tasks | GET | `/fscmRestApi/.../projectFinancialTasks` |
| 4 | Resource assignments | GET/POST | `/fscmRestApi/.../projectResourceAssignments` |
| 4 | Person labor schedules | GET/POST | `/fscmRestApi/.../personAssignmentLaborSchedules` |
| 5 | Project costs | GET/PATCH | `/fscmRestApi/.../projectCosts` |
| 5 | Expenditure items | GET/PATCH | `/fscmRestApi/.../projectExpenditureItems` |
| 5 | Rate schedules | GET | `/fscmRestApi/.../rateSchedules` |
| 6 | Submit time | POST | `/hcmRestApi/.../timeRecordEventRequests` |
| 6 | Read posted time | GET | `/hcmRestApi/.../timeRecords` |
| 6 | Payroll element entries | GET/POST | `/hcmRestApi/.../elementEntries` |
| 7 | Expenditure batches | GET/PATCH | `/fscmRestApi/.../projectExpenditureBatches` |
| 8 | Schedule definitions | GET | `/hcmRestApi/.../workforceScheduleDefinitions` |
| 8 | Schedule shifts | GET | `/hcmRestApi/.../workforceScheduleShifts` |
| 10 | Absences | GET/POST/PATCH | `/hcmRestApi/.../absences` |
| 10 | Plan balances | GET | `/hcmRestApi/.../planBalances` |

---
*Generated from Oracle Fusion Cloud Applications REST API reference (release 26C). Verify exact field lists and privileges against your pod's documentation before build.*
