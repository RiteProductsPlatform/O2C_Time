# Oracle Fusion REST APIs for a Custom Time Module (OTL Replacement)

> Compiled from Oracle Fusion Cloud REST API documentation (HCM `farws` and Project Management `fapap`, release 26C).
> **Base paths:** HCM = `/hcmRestApi/resources/11.13.18.05/` · Projects/PPM = `/fscmRestApi/resources/11.13.18.05/`
> Authentication: Basic Auth or OAuth 2.0 over HTTPS. Header: `Content-Type: application/json`.
>
> This edition includes **field-level schemas** (attribute, type, description) for the key resources, in addition to endpoints and example request/response bodies.

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

POET = **P**roject, **O**rganization, **E**xpenditure type, **T**ask — the charge string a time entry uses to cost to a project. Assembled from several resources (no single "POET" endpoint).

#### Projects (the "P" and org source)

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/projects`

**Example Response Body**

_(Response is an `items` array of the resource; see the Field Schema below for all returned attributes.)_


**Field Schema — `projects`**

| Field | Type | Description |
|---|---|---|
| `AllowCapitalizedInterestFlag` | boolean (max 1) | capitalized interest  Indicates that the project is enabled for capitalization of interest amounts. If the value is true then it means that the project is enabled for capitalization of interest amount |
| `AllowCrossChargeFlag` | boolean (max 1) | cross-charge transactions from other business units  An option at the project level to indicate if transaction charges are allowed from all provider business units to the project. Valid values are tru |
| `AssetAllocationMethodCode` | string (max 30) | Cost Allocation Method Code  Code of the method by which unassigned asset lines and common costs are allocated across multiple assets. Valid values are AU (for Actual units), CC (for Current cost), EC |
| `Attachments` | array | Project Attachments  Attachments The Attachments resource is used to view, create, update and delete attachments to a project. |
| `AutoAssetCreateFlag` | boolean (max 1) | Project Asset Creation Flag  Default Value: false Identifies whether automatic creation of project assets is enabled for project related item receipt costs and supplier costs . |
| `AutoAssetLineAllocateMode` | string (max 30) | Project Asset Cost Allocation Flag  Default Value: ALL_COSTS Identifies whether both asset associated and non-asset associated costs or only asset associated costs will be eligible for allocation to a |
| `BillingFlag` | boolean (max 1, read-only) | Flag   Indicates the billable status of the project. |
| `BurdeningFlag` | boolean (max 1, read-only) | Flag   Indicates that burden costs will be calculated for the project. |
| `BurdenScheduleFixedDate` | string (date) | Schedule Fixed Date A specific date used to determine the right set of burden multipliers for the project. |
| `BurdenScheduleId` | integer (int64) | Schedule ID Unique identifier of the burden schedule associated to the project. |
| `BurdenScheduleName` | string (max 30) | Schedule  Name of the burden schedule associated to the project. |
| `BusinessUnitId` | integer (int64) (read-only) | Unit ID  Default Value: -1 Unique identifier of the business unit to which the project belongs. |
| `BusinessUnitName` | string (max 240, read-only) | Unit   Name of the business unit to which the project belongs. |
| `CapitalEventProcessingMethodCode` | string (max 30) | Event Processing Method Code  Code of the method for processing events on capital projects. Valid values are M (for Manual), P (for Periodic), and N (for None). |
| `CapitalizableFlag` | boolean (max 1, read-only) | Flag   Indicates the capitalization status of the project. |
| `CIntRateSchId` | integer (int64) | Interest Rate Schedule ID Unique identifier of the rate schedule used to calculate the capitalized interest. |
| `CIntRateSchName` | string (max 30) | Interest Rate Schedule  The rate schedule used to calculate the capitalized interest. |
| `CIntStopDate` | string (date) | Interest Stop Date The date when capitalized interest will stop accruing. |
| `CrossChargeLaborFlag` | boolean (max 1) | Labor  Indicator to show that the project will allow processing of cross-charge transactions between business units for labor transactions. Valid values are true and false. By default, the value is fa |
| `CrossChargeNonLaborFlag` | boolean (max 1) | Nonlabor  Indicator to show that the project will allow processing of cross-charge transactions between business units for non labor transactions. Valid values are true and false. By default, the valu |
| `CurrencyConvDate` | string (date) | Currency Conversion Date Date used to obtain currency conversion rates when converting an amount to the project currency. This date is used when the currency conversion date type is Fixed Date (F). |
| `CurrencyConvDateTypeCode` | string (max 1) | Currency Conversion Date Type Code  Code of the date type that is used when converting amounts to the project currency. Valid values are A (for Accounting Date), P (for Project Accounting Date), T (fo |
| `CurrencyConvRateType` | string (max 30) | Currency Conversion Rate Type  Source of a currency conversion rate, such as user defined, spot, or corporate. In this case, the rate determines how to convert an amount from one currency to the proje |
| `EnableBudgetaryControlFlag` | boolean (max 1) | Budgetary Control  An option at the project level to indicate if budgetary control are enabled. Valid values are true and false. |
| `ExternalProjectId` | string (max 240) | Project ID  Unique identifier of the project that is created in the third-party application. |
| `HoursPerDay` | number | per Day Number of hours that a resource works on the project in a day. |
| `IncludeNotesInKPINotificationsFlag` | boolean (max 5) | Notes in KPI Notifications  Indicates that the notes about the KPI are included on the KPI notification report. Valid values are true and false. |
| `IntegrationApplicationCode` | string (max 30) | Application Code  The third-party application code in which the project is integrated. The valid values are ORA_EPM or blank. Attribute can't be set using the POST operation. |
| `IntegrationProjectReference` | string (max 240) | Project Reference  Identifier of the integrated project in a third-party application. Attribute can't be set using the POST operation. |
| `KPINotificationEnabledFlag` | boolean (max 5) | Notifications Enabled  Indicates that the workflow notifications are sent to the project manager after KPI values are generated. Valid values are true and false. |
| `LaborTpFixedDate` | string (date) | Transfer Price Fixed Date A specific date used to determine a price on a transfer price schedule for labor transactions. |
| `LaborTpSchedule` | string (max 50) | Transfer Price Schedule  Name of the transfer price schedule that associates transfer price rules with pairs of provider and receiver organizations for labor transactions. |
| `LaborTpScheduleId` | number | Transfer Price Schedule ID Unique identifier of the labor transfer price schedule. |
| `LegalEntityId` | integer (int64) | Entity ID Default Value: -1 Identifier of the legal entity associated with the project. |
| `LegalEntityName` | string (max 240) | Entity  Name of the legal entity associated with the project. A legal entity is a recognized party with given rights and responsibilities by legislation. Legal entities generally have the right to own |
| `NlTransferPriceFixedDate` | string (date) | Transfer Price Fixed Date A specific date used to determine a price on a transfer price schedule for nonlabor transactions. |
| `NlTransferPriceSchedule` | string (max 50) | Transfer Price Schedule  Name of the transfer price schedule that associates transfer price rules with pairs of provider and receiver organizations for nonlabor transactions. |
| `NlTransferPriceScheduleId` | number | Transfer Price Schedule ID Unique Identifier of the nonlabor transfer price schedule. |
| `NumberAttr01` | number | Project Code 1 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr02` | number | Project Code 2 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr03` | number | Project Code 3 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr04` | number | Project Code 4 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr05` | number | Project Code 5 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr06` | number | Project Code 6 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr07` | number | Project Code 7 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr08` | number | Project Code 8 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr09` | number | Project Code 9 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `NumberAttr10` | number | Project Code 10 Project code defined during implementation that provides the ability to capture a numeric value as additional information for a project. |
| `OwningOrganizationId` | integer (int64) | Organization ID Default Value: -1 Unique identifier of the organization that owns the project. |
| `OwningOrganizationName` | string (max 240) | An organizing unit in the internal or external structure of the enterprise. Organization structures provide the framework for performing legal reporting, financial control, and management reporting fo |
| `PlanningProjectFlag` | boolean (max 1) | Project  Indicates that the project is used to plan and schedule tasks and resources on the tasks. Valid values are true and false. |
| `ProjectCalendarId` | number | Calendar ID Unique identifier of the calendar associated to the project. |
| `ProjectCalendarName` | string (max 240) | Calendar Name  Name of the calendar associated to the project. |
| `ProjectClassifications` | array | Project Classifications  Classifications The Project Classification resource is used to view, create, update, and delete a project classification. A project classification includes a class category an |
| `ProjectCode01` | integer (int64) | of Values Project Code 1 Project code defined during implementation that provides a list of values to capture additional information for a project. |


> _Showing 55 of 421 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._
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


**Field Schema — `expenditureTypes`**

| Field | Type | Description |
|---|---|---|
| `ExpenditureTypeEndActiveDate` | string (date) (read-only) | Active finish date of an expenditure type. |
| `ExpenditureTypeId` | integer (int64) (read-only) | Unique identifier of an expenditure type. |
| `ExpenditureTypeName` | string (max 240, read-only) | Name of the expenditure type. |
| `ExpenditureTypeStartActiveDate` | string (date) (read-only) | Active start date of an expenditure type. |
| `SystemLinkageFunction` | string (max 3, read-only) | The system linkage that classifies the expenditure type in order to drive expenditure processing for the items classified by the expenditure type. |
| `SystemLinkageFunctionName` | string (max 80, read-only) | The system linkage name that classifies the expenditure type in order to drive expenditure processing for the items classified by the expenditure type. |

> The **Task ("T")** comes from the Project Tasks resource (Section 3). **Organization ("O")** is derived from the project's owning/expenditure organization and the person's assignment.

---

## 2. Project Resources
#### Project Enterprise Resources

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


**Field Schema — `projectLaborResources`**

| Field | Type | Description |
|---|---|---|
| `Allocation` | number | Percentage Default Value: 100 The percentage of hours a resource is allocated to the project for a specified duration. |
| `AssignmentStatus` | string | Status of the resource assignment on the project, such as Assigned, Planning, and Canceled. |
| `AssignmentStatusCode` | string (max 30) | Default Value: PLANNING_ONLY Code for the status of the assignment. |
| `AssignmentType` | string | Indicates whether a request is for a billable assignment. Examples are BILLABLE, NONBILLABLE, or leave blank. |
| `AssignmentTypeCode` | string (max 30) | Code  Code to indicate whether a request is for a billable assignment. Examples are BILLABLE, NONBILLABLE, or leave blank. |
| `BillablePercent` | integer | Percent Indicates the percentage of assignment time that is billable for an assignment that is defined as Billable assignment. For a nonbillable assignment, the value is ignored. Valid values are posi |
| `BillablePercentReason` | string | Percent Reason Indicates the reason that the billable percentage of the project resource assignment is less than 100%. For a nonbillable assignment, the value is ignored. |
| `BillablePercentReasonCode` | string (max 30) | Percent Reason Code  Code that indicates the reason that the billable percentage of the project resource assignment is less than 100%. For a nonbillable assignment, the value is ignored. |
| `CalendarId` | integer (int64) (read-only) | ID  Identifier of the calendar that establishes the normal working days, hours per day, and exceptions for a project enterprise resource. |
| `DailyHours` | number | Assignment Hours per Day Working hours of a resource for each working day during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is N. |
| `DefaultStaffingOwnerFlag` | boolean | Indicates whether all project resource requests will be assigned to the staffing owner by default. |
| `Email` | string (max 240) | Email address of the resource. |
| `FridayHours` | number | Assignment Hours on Fridays Working hours of a resource for every Friday during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is X. |
| `FromDate` | string (date) | The date when the resource assignment is to start on the project. |
| `LaborBillRate` | number | Rate The amount paid to a business by its customer for a unit of work completed by the project enterprise resource. |
| `LaborCostRate` | number | Rate The cost of a unit of work by the project enterprise resource. |
| `LaborEffort` | number | in Hours The number of hours that a resource is assigned or allocated to work on a project. |
| `MondayHours` | number | Assignment Hours on Mondays Working hours of a resource for every Monday during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is X. |
| `Name` | string (max 240) | Display name of the resource. |
| `ProjectCurrencyCode` | string (max 15) | Default Value: USD The code for the currency used in the project. The currency code is a three-letter ISO code associated with a currency. |
| `ProjectId` | integer (int64) | ID Unique identifier of the project associated to the resource assignment. To identify the project, provide a value for this attribute, or any one of the Project Number attribute or the Project Name a |
| `ProjectName` | string (max 240) | Name of the project. |
| `ProjectNumber` | string (max 25) | Alphanumeric identifier of the project. |
| `ProjectResourceAssignmentId` | integer (int64) | ID Unique identifier of the project resource assignment. |
| `ProjectRoleId` | integer (int64) | Role ID Default Value: 13 Identifier of the role that the selected resource is assigned to on a project assignment. To identify the project role, provide a value either for this attribute or the Proje |
| `ProjectRoleName` | string | Role Name Name of the role that the selected resource is assigned to on a project resource assignment. To identify the project role, provide a value either for this attribute or for the Project Role I |
| `ProjResourceId` | integer (int64) (read-only) | Unique identifier of the project resource. |
| `Reason` | string | Reason for requesting modification of the resource assignment. |
| `ResourceId` | integer (int64) | ID Unique identifier of the project enterprise resource. |
| `SaturdayHours` | number | Assignment Hours on Saturdays Working hours of a resource for every Saturday during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is X. |
| `ScheduleHoursType` | string (max 1) | Assignment Schedule Hours Indicator  Indicates whether working hours are assigned to resources based on the project calendar, per week, per day, or the day of the week. Valid values are Y, N, X, and W |
| `SundayHours` | number | Assignment Hours on Sundays Working hours of a resource for every Sunday during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is X. |
| `ThursdayHours` | number | Assignment Hours on Thursdays Working hours of a resource for every Thursday during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is X. |
| `ToDate` | string (date) | The date when the resource assignment is to end on the project. |
| `TuesdayHours` | number | Assignment Hours on Tuesdays Working hours of a resource for every Tuesday during the assignment date range. This value can be set only if the value of UseProjCalendarHourFlag is X. |


> _Showing 35 of 37 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._

---

## 3. Project Task

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


**Field Schema — `projectResourceAssignments`**

| Field | Type | Description |
|---|---|---|
| `AdjustmentType` | string (max 80, read-only) | Type of adjustment if some adjustment has happenned on the project resource assignment. |
| `AdjustmentTypeCode` | string (max 30, read-only) | Code   Code for the adjustment performed on the project resource assignment. |
| `AssignmentComments` | string (max 2000) | Additional Comments  Additional details for the project resource assignment. |
| `AssignmentEndDate` | string (date) | End Date The date until which the resource is engaged on the project assignment. If no value is passed when creating the assignment, it defaults to project end date. |
| `AssignmentExternalIdentifier` | string (max 100) | External Identifier  Identifier of the assignment in an external application. |
| `AssignmentHoursPerDay` | number | Hours per Day A period of time measured in hours for each day for the project resource assignment. Mandatory if you are passing Use Project Calendar Flag attribute value as N. |
| `AssignmentHoursPerWeek` | number | Hours per Week Hours for every week of the assignment duration. Applicable only if Use Weekly Hours Indicator value is true. |
| `AssignmentId` | integer (read-only) | ID  Unique identifier of the project resource assignment. |
| `AssignmentLocation` | string (max 240) | Location  Location for the work specified on the project resource assignment. |
| `AssignmentName` | string (max 240) | The name given to a project resource assignment. This name is used to identify an assignment. |
| `AssignmentStartDate` | string (date) | Start Date The date from which the resource is assigned to the project assignment. If no value is passed when creating the assignment, it defaults to the system date for all already started projects a |
| `AssignmentStatusCode` | string (max 30) | Status Code  Status code of the assignment. |
| `AssignmentStatusName` | string (max 80) | Status  Status of the assignment. |
| `AssignmentType` | string (max 80) | Indicates if the assignment is a billable or a nonbillable assignment. |
| `AssignmentTypeCode` | string (max 30) | Code  Code to indicate if the assignment is a billable assignment or a nonbillable assignment. |
| `BillablePercent` | integer | Percent Indicates the percentage of assignment time that is billable for an assignment that is defined as Billable assignment. For a nonbillable assignment, the value is ignored. Valid values are posi |
| `BillablePercentReason` | string (max 80) | Percent Reason  Indicates the reason why the billable percentage of the project resource assignment is less than 100%. For a nonbillable assignment, the value is ignored. |
| `BillablePercentReasonCode` | string (max 30) | Percent Reason Code  Code that indicates the reason why the billable percentage of the project resource assignment is less than 100%. For a nonbillable assignment, the value is ignored. |
| `BillRate` | number | Rate Rate that represents the targeted bill rate for the resource on the assignment. |
| `BillRateCurrencyCode` | string (max 15) | Rate Currency Code  Code of the currency used to define the bill rate. The bill rate currency must be the same as the project currency. |
| `CanceledBy` | string (max 240, read-only) | By   The user who canceled the project resource assignment, if the assignment is canceled. |
| `CanceledByResourceId` | integer (int64) (read-only) | by Resource ID  Unique Identifier of the resource who canceled the project resource assignment, if the assignment is canceled. |
| `CancellationDate` | string (date) (read-only) | Date of cancellation if the assignment is canceled. |
| `CancellationReason` | string (max 2000, read-only) | Reason   Reason of cancellation if the assignment is canceled. |
| `CostRate` | number | Rate Rate that represents the cost rate for the resource on the assignment. |
| `CostRateCurrencyCode` | string (max 15) | Rate Currency Code  Code of the currency used to define the cost rate. |
| `CreatedFromFlow` | string (max 30) | from Flow  The flow from which the project resource assignment was created. For example, BRYNTUM indicates the project resource assignment was created from the resource schedule Gantt Chart. |
| `FridayHours` | number | Hours Hours for Friday of every week for the assignment time period. Applicable only if Use Variable Hours Indicator is true. |
| `LastUpdatedFromFlow` | string (max 30) | Updated from Flow  The flow from which the project resource assignment was updated. Examples are BYNTUM_ADJUST or BRYNTUM_CANCEL. These values indicate the assignment schedule was adjusted or canceled |
| `MondayHours` | number | Hours Hours for Monday of every week for the assignment time period. Applicable only if Use Variable Hours Indicator value is true. |
| `ProjectId` | integer | ID Unique identifier of the project associated to the resource assignment. To identify the project, you may provide a value only for this attribute, the Project Number attribute, or the Project Name a |
| `ProjectManagementFlowFlag` | boolean | Management Flow Indicator Flag that indicates if the action is called in the project manager flow. Set this value only if the service is being called in the project manager flow. Default value will be |
| `ProjectName` | string (max 240) | Name of the project associated to the resource assignment. To identify the project associated to the assignment, you may provide a value only for this attribute, Project ID attribute, or the Project N |
| `ProjectNumber` | string (max 25) | Unique number of the project associated to the resource assignment. To identify the project associated to the assignment, you may provide a value only for this attribute or the Project ID attribute or |
| `ProjectResourceAssignmentSchedules` | array | Project Resource Assignment Schedules  Resource Assignment Schedules The Project Resource Assignment Schedules resource is used to view schedule details of project resource assignments with variable w |
| `ProjectRoleId` | integer | Role ID Identifier of the role that the selected resource is assigned to on a project assignment. To identify the project role, you may provide a value for this attribute or for Project Role Name attr |
| `ProjectRoleName` | string (max 240) | Role Name  Name of the role that the selected resource is assigned to on a project resource assignment. To identify the project role, you may provide a value for only this attribute or for Project Rol |
| `ProjResourceId` | integer (int64) (read-only) | Resource ID  Identifier of the project labor resource associated with the project resource assignment. |
| `ReservationExpirationDate` | string (date) | Expiration Date Date until which the resource should be reserved on the project. On or before this date, you should either confirm the assignment or cancel the reservation. |
| `ReservationReason` | string (max 80) | Reason  Reason for reserving a resource on the project resource assignment. You may provide a value for this attribute or for Resource Reason Code attribute but not both. Applies only if the Assignmen |
| `ReservationReasonCode` | string (max 30) | Reason  Code for the reason for reserving a resource on the project resource assignment. You may provide a value for this attribute or for Reservation Reason attribute but not both. Applies only if th |
| `ResourceEmail` | string (max 240) | Email  Email of the resource who is selected for the assignment. To identify the resource, you may provide a value for this attribute or for Resource ID attribute but not both. |
| `ResourceHCMPersonId` | integer (int64) (read-only) | Person ID  HCM person identifier for the project enterprise resource who is selected for the assignment. |
| `ResourceId` | integer | ID Unique identifier of the resource who is selected for the assignment. To identify the resource, you may provide a value for this attribute or for Resource Email attribute but not both. Resource is |
| `ResourceName` | string (max 240, read-only) | Name of the resource that is selected for the assignment. |


> _Showing 45 of 63 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._
#### Person Assignment Labor Schedules – list

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


**Field Schema — `personAssignmentLaborSchedules`**

| Field | Type | Description |
|---|---|---|
| `AssignmentDepartment` | string (max 240, read-only) | Department   The department of the assignment. |
| `AssignmentId` | integer (int64) | Unique identifier of the assignment for this Person Assignment Labor Schedule header. |
| `AssignmentName` | string (max 255) | of the assignment for this Person Assignment Labor Schedule header. |
| `AssignmentNumber` | string (max 255) | of the assignment for this Person Assignment Labor Schedule header. |
| `BusinessUnitId` | integer (int64) | Unique identifier of the business unit that's used for Element Level labor schedules only. |
| `BusinessUnitName` | string (max 240) | Unit  Name of the business unit that's associated to the Element Level labor schedule. |
| `CostAllocationId` | integer (int64) (read-only) | Identifier of the payroll costing configuration specific to payroll costing configuration labor schedules of the type KFF. |
| `DepartmentId` | integer (int64) | Identifier of the organization that represents the department associated with the organization type labor schedule. |
| `DepartmentName` | string (max 240) | of the organization that represents the department associated with the organization type labor schedule. |
| `IncludeChildNodes` | string (max 1) | Indicates whether the organization type labor schedule should include child nodes in the organization or department tree derived from the project business unit definition. |
| `LaborScheduleId` | integer (int64) | The unique identifier of the Person Assignment Labor Schedule header. |
| `LaborScheduleName` | string (max 240) | The name of the labor schedule header. |
| `LaborScheduleType` | string (max 80) | The name for the labor schedule type that identifies the attributes that drive the distributions. |
| `LaborScheduleTypeCode` | string (max 30) | The code for the labor schedule type. |
| `LegislativeDataGroupId` | integer | Unique identifier of the legislative data group for the pay element. |
| `LegislativeDataGroupName` | string | of the legislative data group associated to the pay element. |
| `PayElement` | string (max 80) | The payroll element code for this labor schedule. Applies to labor schedules of type element. |
| `PayElementId` | integer (int64) | The payroll element identifier for this labor schedule. Applies to labor schedules of type element. |
| `PayElementName` | string (max 80) | The payroll element name for this labor schedule. Applies to labor schedules of type element. |
| `PayrollCostingAllocInstCode` | string (read-only) | Code of the payroll costing configuration specific to payroll costing configuration labor schedules of the type KFF. |
| `PayrollCostingAllocInstName` | string (read-only) | of the payroll costing configuration specific to payroll costing configuration labor schedules of the type KFF. |
| `PayrollCostingSegmentConcatenation` | string (max 2000) | Concatenated segments specific to payroll costing configuration labor schedules of the type KFF. |
| `PersonEmail` | string (max 240, read-only) | Email of the person. |
| `PersonId` | integer (int64) | Unique identifier of the person. |
| `PersonName` | string (max 240) | Full name, first then last, of the person. |
| `PersonNumber` | string (max 30) | Human Resources number of the person. |
| `Precedence` | integer (int32) | The precedence that's used for payroll costing configuration labor schedules of the type KFF. |
| `RuleSource` | string (max 20) | Source of the labor schedule creation. Either UI, REST, or FBDI. |
| `Segment1` | string | Segment 1 of payroll costing configuration labor schedules of the type KFF. |
| `Segment10` | string | Segment 10 of payroll costing configuration labor schedules of the type KFF. |
| `Segment11` | string | Segment 11 of payroll costing configuration labor schedules of the type KFF. |
| `Segment12` | string | Segment 12 of payroll costing configuration labor schedules of the type KFF. |
| `Segment13` | string | Segment 13 of payroll costing configuration labor schedules of the type KFF. |
| `Segment14` | string | Segment 14 of payroll costing configuration labor schedules of the type KFF. |
| `Segment15` | string | Segment 15 of payroll costing configuration labor schedules of the type KFF. |
| `Segment16` | string | Segment 16 of payroll costing configuration labor schedules of the type KFF. |
| `Segment17` | string | Segment 17 of payroll costing configuration labor schedules of the type KFF. |
| `Segment18` | string | Segment 18 of payroll costing configuration labor schedules of the type KFF. |
| `Segment19` | string | Segment 19 of payroll costing configuration labor schedules of the type KFF. |
| `Segment2` | string | Segment 2 of payroll costing configuration labor schedules of the type KFF. |
| `Segment20` | string | Segment 20 of payroll costing configuration labor schedules of the type KFF. |
| `Segment21` | string | Segment 21 of payroll costing configuration labor schedules of the type KFF. |
| `Segment22` | string | Segment 22 of payroll costing configuration labor schedules of the type KFF. |
| `Segment23` | string | Segment 23 of payroll costing configuration labor schedules of the type KFF. |
| `Segment24` | string | Segment 24 of payroll costing configuration labor schedules of the type KFF. |


> _Showing 45 of 97 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._

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


**Field Schema — `projectCosts`**

| Field | Type | Description |
|---|---|---|
| `AccountingDate` | string (date) (read-only) | The date used to determine the accounting period for a project cost. |
| `AccountingPeriod` | string (max 15, read-only) | Period   The accounting period of the cost distribution in the provider organization's accounting calendar. The provider is the organization that owns the labor or nonlabor resource that incurred the |
| `AccrualItemFlag` | boolean (max 1, read-only) | item   Indicates if the project cost belongs to an expenditure batch that will accrue cost in a period and automatically reverse them in the next period. A value of true means that the project cost is |
| `AdjustingItem` | integer (int64) (read-only) | Item  Indicates that the project cost transaction was created as a result of adjusting another project cost. A value of true means that the project cost was created due to the adjustment of another pr |
| `Adjustments` | array | Adjustments  The Adjustments resource is used to view the adjustments performed on project costs. |
| `AdjustmentStatus` | string (max 80, read-only) | Status   Indicates the status of an adjustment made to the project cost. A list of valid values - Pending and Rejected - is defined in the lookup type PJC_ADJ_STATUS. |
| `AllowAdjustments` | string (max 1, read-only) | adjustments   Indicates if the project cost is eligible to be adjusted. A value of true means that you can perform adjustments on the project cost and a value of false means that you can't perform adj |
| `AssignmentId` | integer (int64) (read-only) | ID  Identifier of the human resources assignment of the person that incurred the cost that was charged to the project. |
| `AssignmentName` | string (max 80, read-only) | Name of the human resources assignment of the person that incurred the cost that was charged to the project. |
| `AssignmentNumber` | string (max 30, read-only) | Number of the human resources assignment of the person that incurred the cost that was charged to the project. |
| `BillableFlag` | boolean (max 1, read-only) | Specifies if the project cost is billable. A value of true means that the project cost is billable and a value of false means that the project cost is not billable. |
| `BorrowedAndLentDistributed` | string (max 80, read-only) | and Lent Distributed   Indicates if borrowed and lent transactions have been created for the project cost. A list of valid values is defined in the lookup PJC_CC_PROCESSED_CODE. |
| `BorrowedAndLentDistributedCode` | string (max 1, read-only) | and Lent Distributed   Code that indicates if borrowed and lent transactions have been created for the project cost. A list of valid values is defined in the lookup PJC_CC_PROCESSED_CODE. |
| `BurdenCostCreditAccount` | string (read-only) | Cost Credit Account  The ledger account that receives the credit amount for the burden cost associated with a project cost. |
| `BurdenCostDebitAccount` | string (read-only) | Cost Debit Account  The ledger account that receives the debit amount for the burden cost associated with a project cost. |
| `BurdenedCostCreditAccount` | string (read-only) | Cost Credit Account  The ledger account that receives the credit amount for the burdened cost associated with a project cost. The burdened cost includes the sum of the raw and burden cost. |
| `BurdenedCostDebitAccount` | string (read-only) | Cost Debit Account  The ledger account that receives the debit amount for the burdened cost associated with a project cost. The burdened cost includes the sum of the raw and burden cost. |
| `BurdenedCostInProjectCurrency` | number (read-only) | Cost in Project Currency  Total project cost in the currency of the project that is incurring the unprocessed cost, including the burden cost. |
| `BurdenedCostInProviderLedgerCurrency` | number (read-only) | Cost in Provider Ledger Currency  Total project cost in the provider ledger currency that includes the burden cost. |
| `BurdenedCostInReceiverLedgerCurrency` | number (read-only) | Cost in Receiver Ledger Currency  Total project cost in the receiver ledger currency that includes the burden cost. |
| `BurdenedCostInTransactionCurrency` | number (read-only) | Cost in Transaction Currency  Total project cost in the transaction currency for a project that is enabled for burdening, including the burden cost. |
| `CapitalEventNumber` | integer (int64) (read-only) | Event Number  Identifying number of the capital event associated with the project cost. |
| `CapitalizableFlag` | boolean (max 1, read-only) | Specifies if the project cost is capitalizable. A value of true means that the project cost is capitalizable and a value of false means that the project cost is not capitalizable. |
| `Comment` | string (max 240, read-only) | Comment entered for the project cost. |
| `ContractId` | integer (int64) (read-only) | ID  Identifier of the contract for the project cost of a sponsored project. |
| `ContractName` | string (max 300, read-only) | Name of the contract for the project cost of a sponsored project. |
| `ContractNumber` | string (max 120, read-only) | Number of the contract for the project cost of a sponsored project. |
| `ConvertedFlag` | boolean (max 1, read-only) | Indicates if the project cost was converted from a legacy system. A value of true means that the project cost is converted from a legacy system and a value of false means that the project cost is not |
| `CostActionId` | integer (int64) (read-only) | Cost Action ID  The payroll costing unique identifier for the pay action. |
| `CostActionType` | string (max 120, read-only) | Cost Action Type   The unique payroll action identifier of the cost. This identifier is used to gather accounting information associated with the cost. |
| `CostElement` | string (max 255, read-only) | Element   Reference to the cost element details in the originating source system that's associated with the project cost. |
| `CostId` | integer (int64) (read-only) | Cost ID  The unique identifier of the payroll cost. |
| `CrossChargeType` | string (max 80, read-only) | Name of the type of cross-charge processing to be performed on the project cost. A list of valid values is defined in the lookup type PJC_CC_CROSS_CHARGE_TYPE. |
| `CrossChargeTypeCode` | string (max 2, read-only) | Code of the type of cross-charge processing to be performed on the project cost. A list of valid values is defined in the lookup type PJC_CC_CROSS_CHARGE_TYPE. |
| `Document` | string (max 240, read-only) | of the document used to capture the project cost. |
| `DocumentEntry` | string (max 240, read-only) | Entry   Name of the document entry used to capture the project cost. |
| `DocumentEntryId` | integer (int64) (read-only) | Entry ID  Identifier of the document entry used to capture the project cost. |
| `DocumentId` | integer (int64) (read-only) | ID  Identifier of the document used to capture the project cost. |
| `Email` | string (max 240, read-only) | Email address of the person through whom the project cost is incurred. A person must be associated with all time card and expense report transactions and is optional for other types of transactions. |
| `ExpenditureBusinessUnit` | string (max 240, read-only) | Business Unit   Name of the expenditure business unit that incurred the project cost. |
| `ExpenditureBusinessUnitId` | integer (int64) (read-only) | Business Unit ID  Identifier of the expenditure business unit that incurred the project cost. |
| `ExpenditureCategory` | string (max 240, read-only) | Category   The cost group associated with a project cost. The expenditure category is derived based on the expenditure type and it is a method of grouping expenditure types by the type of cost. |
| `ExpenditureItemDate` | string (date) (read-only) | Item Date  Date on which the project cost was incurred. |
| `ExpenditureOrganization` | string (max 240, read-only) | of the expenditure organization to which the project cost is charged. |
| `ExpenditureOrganizationId` | integer (read-only) | Organization ID  Identifier of the expenditure organization to which the project cost is charged. |
| `ExpenditureType` | string (max 240, read-only) | A classification of cost that is assigned to each project cost. Expenditure types are grouped into cost groups (expenditure categories) and revenue groups (revenue categories). |
| `ExpenditureTypeClass` | string (max 80, read-only) | Class   Additional classification of the project cost that drives the expenditure processing for the project cost. |
| `ExpenditureTypeClassCode` | string (max 3, read-only) | Class Code   Code that identifies the additional classification of the project cost that drives the expenditure processing for the project cost. |
| `ExpenditureTypeId` | integer (int64) (read-only) | ID  Identifier of the expenditure type. |
| `ExternalBillRate` | number | Bill Rate The unit rate at which a project cost is billed on external contracts. |
| `ExternalBillRateCurrency` | string (max 15) | Bill Rate Currency  The currency in which a project cost is billed on external contracts. |
| `ExternalBillRateSourceName` | string (max 150) | Bill Rate Source Name  Name of the external source application from where the external bill rate originates. |
| `ExternalBillRateSourceReference` | string (max 30) | Bill Rate Source Reference  Identifier of the external bill rate in the external source application. |
| `FundingSourceId` | string (max 150, read-only) | Source ID   Identifier of the funding source of a sponsored project cost. |
| `FundingSourceName` | string (max 360, read-only) | Source Name   Name of the funding source of a sponsored project cost. |


> _Showing 55 of 207 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._
#### Project Expenditure Items – query processed items

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


**Field Schema — `projectExpenditureItems`**

| Field | Type | Description |
|---|---|---|
| `ExpenditureItemId` | integer (int64) | The identifier of the expenditure item. |
| `ExternalBillRate` | number | Bill Rate The unit rate at which an expenditure item is billed on external contracts. |
| `ExternalBillRateCurrency` | string (max 15) | Bill Rate Currency  The currency in which an expenditure item is billed on external contracts. |
| `ExternalBillRateSourceName` | string (max 150) | Bill Rate Source Name  The name of the external source from where the external bill rate originates. |
| `ExternalBillRateSourceReference` | string (max 30) | Bill Rate Source Reference  The unique identifier of the external bill rate in the external source. |
| `IntercompanyBillRate` | number | Bill Rate The unit rate at which an expenditure item is billed on intercompany contracts. |
| `IntercompanyBillRateCurrency` | string (max 15) | Bill Rate Currency  The currency in which an expenditure item is billed on intercompany contracts. |
| `IntercompanyBillRateSourceName` | string (max 150) | Bill Rate Source Name  The name of the external source from where the intercompany bill rate originates. |
| `IntercompanyBillRateSourceReference` | string (max 20) | Bill Rate Source Reference  The unique identifier of the intercompany bill rate in the external source. |
| `ProjectExpenditureItemsDFF` | array | Project Expenditure Items Descriptive Flexfields  Expenditure Items Descriptive Flexfields The Project Expenditure Items Descriptive Flexfields resource is used to view and update additional informati |
| `__FLEX_Context` | string (max 30) | Prompt  Code that identifies the context for the segments of the project expenditure items. |
| `__FLEX_Context_DisplayValue` | string | Prompt Name of the context for the segments of the project expenditure items. |

#### Rate Schedules – cost/bill rates

- **Method / Path:** `GET /fscmRestApi/resources/11.13.18.05/rateSchedules`


**Field Schema — `rateSchedules`**

| Field | Type | Description |
|---|---|---|
| `CurrencyCode` | string (max 15) | Currency code associated with the rate schedule. The currency code is a three-letter ISO code associated with a currency. A currency is required to create a rate schedule. The value can't be updated. |
| `CurrencyName` | string (max 80) | Currency name associated with the rate schedule. |
| `Description` | string (max 250) | The description of the rate schedule. |
| `ProjectRatesSetCode` | string (max 30) | Code  Code of the reference data set for the project rates schedule. A project rates set ID or Code is required to create a rate schedule. Review the list of values using the Setup and Maintenance wor |
| `ProjectRatesSetId` | integer (int64) | Identifier of the reference data set for the project rates schedule. A project rates set ID or Code is required to create a rate schedule. The project rates set value can't be updated |
| `ProjectRatesSetName` | string (max 80, read-only) | Name of the reference data set for the project rates schedule. A project rates set is required to create a rate schedule. Review the list of values using the Setup and Maintenance work area and the Ma |
| `RateScheduleId` | integer (int64) (read-only) | The unique identifier of the rate schedule. |
| `RateScheduleName` | string (max 30) | of the rate schedule that contains rates or markup percentage for person, job, nonlabor expenditure type, nonlabor resource, and resource class. A rate schedule name is required to create a rate sched |
| `ScheduleTypeCode` | string (max 30) | Default Value: EMPLOYEE Type of rate schedule. Valid values are Person, Job, Project Role, Nonlabor, and Resource class. The schedule type is required to create a rate schedule. The value can't be upd |
| `ScheduleTypeName` | string (max 80) | Code for the type of rate schedule. Valid values are JOB, NONLABOR, EMPLOYEE, and RESOURCE_CLASS. The schedule type is required to create a rate schedule. The value can't be updated. |
| `JobSetCode` | string (max 30) | Code  Code of the reference data set for the jobs associated with a job rate schedule type. A job set ID or Code is required to create a rate schedule with a job schedule type. The value can't be upda |
| `JobSetId` | integer (int64) | Identifier of the reference data set for the jobs associated with a job rate schedule type. A job set ID or Code is required to create a rate schedule with a job schedule type. The value can't be upda |
| `JobSetName` | string (max 80, read-only) | Name of the reference data set for the jobs associated with a job rate schedule type. A job set is required to create a rate schedule with a job schedule type. The value can't be updated. |
| `EndDateActive` | string (date) | Date after which the rate schedule line is no longer effective. |
| `ProjectRoleId` | integer (int64) | Role ID Identifier of the project role for which a rate is defined in the rate schedule. A Project Role ID or Project Role Name is required to create a project role rate. |
| `ProjectRoleName` | string (max 240) | Role  Name of the project role for which a rate is defined in the rate schedule. A Project Role Name or Project Role ID is required to create a project role rate. |
| `Rate` | number | The rate, assigned to the rate schedule line, that's to be applied to calculate the raw cost and revenue amounts. A rate or markup is required to create a rate. |
| `RateId` | integer (int64) (read-only) | Unique identifier of the rate. |
| `StartDateActive` | string (date) | Date from which the rate schedule line is effective. A start date is required to create a rate. The value can't be updated if the rate is being used. |
| `UnitOfMeasureCode` | string (max 30, read-only) | Unit of measure code associated with the resource class in the resource class rate schedule line. A unit of measure is required to create a rate for material items or financial resources and can only |
| `UnitOfMeasureName` | string (max 80, read-only) | Unit of measure associated with the resource class in the resource class rate schedule line. A unit of measure is required to create a rate for material items or financial resources and can only be up |

> **Note:** `projectCosts` supports **GET** and **PATCH** (plus `adjustProjectCosts` action) but **not a direct POST** — cost transactions are created by the *Import and Process Cost Transactions* process (Section 7).

---

## 6. How OTL Sends Time (Hours) to Payroll

**Step A — Capture time (REST):** OTL records time via **Time Record Event Requests**. `processMode: "TIME_SUBMIT"` posts to the time repository. Payroll/project attributes (e.g. `PayrollTimeType`, project POET) are passed as `timeRecordEventAttribute` name/value pairs.

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


> _Showing 40 of 43 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._
**Step B — Transfer to Payroll (ESS process):** **"Load Time Card Batches" / "Transfer Time Cards from Time and Labor to Payroll"** moves approved hours into Payroll as **Element Entries**.

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


> _Showing 40 of 73 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._
> Supporting LOVs: `payrollTimeDefinitionsLOV`, `payrollTimePeriodsLOV`, `payrollElementDefinitionLOV`, `payrollRelationships`.


---

## 7. After Manager Approval → Sending Time to Project Costing

Process-driven, not a single REST push. After approval:

1. **Transfer Time to Projects** — moves approved time to Project Costing as *unprocessed* transactions.
2. **Import and Process Cost Transactions** — costs the transactions (rates/burdening).

Results queryable via `GET .../projectCosts` and `GET .../projectExpenditureItems` (schemas in Section 5).

**REST alternative for a fully custom module:** stage transactions with **Project Expenditure Batches** then run the import.
- `GET/PATCH /fscmRestApi/resources/11.13.18.05/projectExpenditureBatches` (submit a batch)
- Adjustments: `POST /fscmRestApi/resources/11.13.18.05/projectCosts/{ProjectCostsUniqID}/action/adjustProjectCosts`

---

## 8. Employee Shift, Work Pattern & Schedule

Primarily **setup/config** (HCM Data Loader objects "Work Schedule" / "Work Schedule Assignment"). REST resources:

**Workforce Scheduling**
- `workforceScheduleDefinitions` — `GET /hcmRestApi/resources/11.13.18.05/workforceScheduleDefinitions`
- `workforceScheduleShifts` — `GET /hcmRestApi/resources/11.13.18.05/workforceScheduleShifts`
- `scheduleRequests`, `staffingGrids`, `schedulingShiftsLOV`

**Time & Labor:** `timeLayoutSets`, `webClockEvents`, `geofences`

> A specific person's assigned schedule/pattern/availability is managed via HDL (Work Schedule Assignment), not a first-class writable REST resource.

---

## 9. Calendar & Holidays

Holiday calendars are modeled as **Calendar Events / work-schedule exceptions** (config, loaded via HDL). Non-working days are derived from a worker's assigned Work Schedule Definition and its exceptions; query via the Workforce Schedule Definition/Shift resources (Section 8).

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


> _Showing 45 of 374 fields (core attributes). See Oracle docs for the full list including flexfields and accounting details._
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
*Generated from Oracle Fusion Cloud Applications REST API reference (release 26C). Field schemas are trimmed to core attributes for readability; verify the complete attribute list, flexfields, and privileges against your pod's documentation before build.*
