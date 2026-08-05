# O2C Time — what comes from where

Consolidated sourcing matrix: which Fusion data arrives by **BIP extract on a
schedule (OIC)**, which must be **REST**, and what is still missing.

Compiled 05-Aug-2026 from `doc/Oracle_Fusion_Time_Module_REST_APIs*.md`,
`doc/Oracle_Fusion_BIP_Data_Extraction_APIs.md`,
`doc/Time_Module_Build_Spec_for_Claude.md`, `integration/bip/README.md` and the
extract definitions in `integration/bip/extracts.py`.

Counts marked *(pod)* were measured against the reference pod on 01/02-Aug-2026,
not inferred.

---

## 1. BIP extracts — bulk, scheduled by OIC

Eleven extracts exist in `integration/bip/extracts.py` and all eleven have been
run against a pod. **`integration/bip/README.md` documents only eight** — the
three schedule extracts are missing from its table. Corrected here.

`ABSENCES` is struck through: it still exists and still runs, but it is no longer
the source the module reads — absence is fetched live per person per date (§4). Ten
extracts feed the cache.

| Extract | INT | Target | Fusion sources | Suggested cadence |
|---|---|---|---|---|
| `WORKERS` | INT-001 | `OC_TIME_WORKER` | `PER_ALL_PEOPLE_F`, `PER_PERSON_NAMES_F`, `PER_ALL_ASSIGNMENTS_M`, `PER_EMAIL_ADDRESSES`, `PER_PERIODS_OF_SERVICE`, `PER_ASSIGNMENT_SUPERVISORS_F`, `HR_LOCATIONS_ALL_F`, `HR_ALL_ORGANIZATION_UNITS_F_VL` | **daily** |
| `PROJECTS` | INT-002 | `OC_TIME_PROJECT` | `PJF_PROJECTS_ALL_B/_TL`, `PJF_PROJECT_TYPES_TL`, `PJF_PROJECT_PARTIES`, `HZ_PARTIES`, `PJT_PROJECT_ROLES_VL` | monthly |
| `TASKS` | INT-002 | `OC_TIME_TASK` | `PJF_PROJ_ELEMENTS_B/_TL` | monthly |
| `ALLOCATIONS` | INT-003 | `OC_TIME_ALLOCATION` | `PJF_PROJECT_PARTIES`, `PJR_ASSIGNMENT` | **daily** |
| ~~`ABSENCES`~~ | INT-006 | ~~`OC_TIME_ABSENCE`~~ | — | **superseded — read live, §4** |
| `CALENDAR` | INT-005 | `OC_TIME_CALENDAR` (HOLIDAY) | `PER_CALENDAR_EVENTS` | monthly |
| `SHIFTS` | INT-004 | `OC_TIME_CALENDAR` (SHIFT) | `HTS_SHIFTS_VL` | monthly |
| `WORK_PATTERNS` | INT-004 | `OC_TIME_CALENDAR` (pattern ref) | `HTS_WORK_PATTERNS_VL` | monthly |
| `WORK_SCHEDULES` | INT-004 | `OC_TIME_CALENDAR` (schedule assign) | `HTS_SCHEDULES` | monthly |
| `WORKER_SHIFTS` | INT-004 | `OC_TIME_CALENDAR` (SHIFT) | `HTS_WORKERS_WITH_SHIFTS_V` / `HTS_SCHEDULES_DAY_SHIFT_VIEW` | monthly |
| `EXP_TYPES` | INT-002 | reference for `OC_TIME_CONFIG` | `PJF_EXP_TYPES_B/_TL` | on change |

**Why BIP and not REST for these:** one report returns thousands of rows where
REST needs paginated calls; the data model JOINs across objects so project + WBS
task + resource assignment arrive pre-stitched; and a full extract can detect
deletions, which incremental REST cannot.

**How OIC should invoke it.** SOAP `runReport` on
`/xmlpserver/services/ExternalReportWSSService` (or `/xmlpserver/services/v2/ReportService`),
`attributeFormat=csv`, `sizeOfDataChunkDownload=-1` for small extracts and
chunked for large. Decode `reportBytes` (base64) and POST to
`/oc/time/admin/sync/{entity}` in chunks of 500. The MERGE lives in ORDS, next to
the constraints it must satisfy, so OIC, the Python loader and a manual repair
all behave identically.

**Two ordering rules that are constraints, not preferences:**

```
WORKERS -> PROJECTS -> TASKS -> ALLOCATIONS
```
`OC_TIME_ALLOCATION` has FKs to both project and worker, `OC_TIME_TASK` to
project. Load allocations first and every row fails. (`ABSENCES` used to be last
in this chain; it is now read live — §4.)

MasterSync must finish **before** `POST jobs/populate/:periodId`
(MonthlyPopulation), which builds `OC_TS_WEEK`/`OC_TS_ENTRY` from the cache. Run
it after and the month is built from last month's allocations.

---

## 2. REST — required, BIP cannot do it

BIP is **read-only**. Every write-back is REST, and a few reads have no usable
extract.

### 2.1 Writes (all REST, no alternative)

| Purpose | Method / path | State |
|---|---|---|
| OTL time push (INT-007) | `POST /hcmRestApi/.../timeRecordEventRequests` (`processMode=TIME_SUBMIT`) | **not built** — blocked, see §3.1 |
| Absence create/update | `POST|PATCH /hcmRestApi/.../absences` | not built |
| Payroll element entries | `POST /hcmRestApi/.../elementEntries` | not built, out of scope today |
| Costing batch stage | `GET|PATCH /fscmRestApi/.../projectExpenditureBatches` | not built |
| Costing adjustment | `POST /fscmRestApi/.../projectCosts/{id}/action/adjustProjectCosts` | not built |
| Project status change (INT-009) | `statusChangeRequests` | not built |

### 2.2 Reads REST must serve

| Data | Method / path | Why not BIP |
|---|---|---|
| **Absences, per person per date** | `GET /hcmRestApi/.../absences?q=personNumber=… AND date range` | **the decision of 05-Aug-2026 — see §4.** A nightly extract cannot answer "on leave on this date" for a date it did not cover |
| Absence plan balance | `GET /hcmRestApi/.../planBalances` | balance is computed by Absence Mgmt, not a table read; needed to validate a leave entry |
| Expenditure types | `GET /fscmRestApi/.../expenditureTypes` | also extractable; REST is fine for a 262-row list |
| Financial (chargeable) tasks | `GET /fscmRestApi/.../projectFinancialTasks` | second opinion on the chargeable-task gap, §3.5 |
| Project tasks live | `GET /fscmRestApi/.../projects/{ProjectId}/child/Tasks` | on-demand picker refresh |
| Project labor resources | `GET /fscmRestApi/.../projectLaborResources` | validating a person is a resource before charging |
| Resource assignments | `GET /fscmRestApi/.../projectResourceAssignments` | live allocation check |
| Person labor schedules | `GET /fscmRestApi/.../personAssignmentLaborSchedules` | the **only** source of per-POET percentage split incl. `ExpenditureOrganizationName`, `ExpenditureTypeId`, `ContractNumber`, `FundingSourceId`, `WorkTypeId` |
| Rate schedules | `GET /fscmRestApi/.../rateSchedules` | valuation, if revenue is ever in scope |
| Costed results read-back | `GET /fscmRestApi/.../projectCosts`, `/projectExpenditureItems` | proves the push landed |
| Workforce schedules | `GET /hcmRestApi/.../workforceScheduleDefinitions`, `/workforceScheduleShifts` | partial — see §3.3 |

**Base paths:** HCM `/hcmRestApi/resources/11.13.18.05/` · PPM/Financials
`/fscmRestApi/resources/11.13.18.05/`. Auth: Basic or OAuth 2.0, server-side
only (NFR-005).

### 2.3 Sending cost to Project Costing — REST, then one ESS step

**Corrected.** An earlier version of this section said costing could only be
reached by a scheduled transfer process. `doc/Unprocessed_Project_Costs_REST_API.md`
shows otherwise: the **Unprocessed Project Costs** resource accepts a third-party
cost directly.

```
POST /fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts
```

One row per approved entry; POET travels in the
`ProjectStandardCostCollectionFlexfields` child block
(`_PROJECT_ID_Display`, `_TASK_ID_Display`, `_EXPENDITURE_TYPE_ID_Display`,
`_ORGANIZATION_ID_Display`, `_EXPENDITURE_ITEM_DATE`). Required fields are
`BusinessUnitId`, `ExpenditureBatch`, `OriginalTransactionReference` and
`Quantity`. `OriginalTransactionReference` carries **our entry id** and is the
idempotency key.

Only the conversion step remains ESS: Fusion's *Import Costs* program turns
unprocessed costs into project costs. Rejections are readable with
`GET …?q=StatusCode='R'&expand=Errors`.

**Payroll is out of scope** — no `elementEntries` write, no transfer process.

---

## 3. Anything else needed — the real gaps

### 3.1 Fusion `PersonId` and `AssignmentNumber` are not extracted — blocks INT-007

`OC_TIME_WORKER.FUSION_PERSON_ID` and `OC_TIME_ALLOCATION.FUSION_ASSIGNMENT_ID`
**exist as columns and no extract populates them.** Neither appears in
`extracts.py` nor in the `sync/{entity}` MERGE.

This is the single biggest gap. `timeRecordEventRequests` requires
`assignmentNumber`, and `absences` is keyed on `personId` — so as things stand
the OTL push cannot be built and no live absence call can name the person.

**Action:** add `PERSON_ID` and `ASSIGNMENT_NUMBER`/`ASSIGNMENT_ID` to the
`WORKERS` extract (both are on `PER_ALL_ASSIGNMENTS_M`, already joined) and carry
them through the loader.

### 3.2 "Time Card Required" eligibility is not sourced

The build spec's validation layer requires *"worker has Time Card Required"*
before an entry is accepted. It is neither extracted nor modelled. Without it the
module will accept time from people Fusion says should not report any.

### 3.3 A person's assigned work schedule is not a first-class REST resource

Both REST docs say so explicitly: use HDL for Work Schedule Assignment. So
`WORKER_SHIFTS` / `WORK_SCHEDULES` must stay BIP — `HTS_WORKERS_WITH_SHIFTS_V`
and `HTS_SCHEDULES_DAY_SHIFT_VIEW` already produce the worker × day × shift shape
`V_OC_TS_DAY_SHIFT` needs. Do not plan to replace these with REST.

Note also: schedules are `HTS_*`, **not** `ZMM_*` — `ZMM_SR_*` is CX Service
Request scheduling.

### 3.4 Expenditure type is configuration on this pod, not a task attribute

`PJF_TXN_CONTROLS` **does not exist** on the pod (only `PJC_TXN_CONTROLS_STAGE`,
a staging table). So there are no transaction controls to read a per-task
expenditure type from, `OC_TIME_TASK.EXPENDITURE_TYPE` is null for every row, and
the value comes from `OC_TIME_CONFIG.defaultExpenditureType` = `Regular Labor`.

Resolution must be `NVL(task, config)` in both `V_OC_TIME_POET_READINESS` and the
push, or the readiness panel and the push will disagree about what is ready.

**Confirm before UAT:** run `EXP_TYPES` and check UOM. Several types named
`...Labor` are `DOLLARS` (Craft Labor Straight Time, Consultant Labor) and are
wrong for hours — 30 of 262 are `HOURS`. The UOM is the constraint, not the name.

### 3.5 Data-quality gaps in Fusion, not code (all *(pod)* measured)

| Gap | Measured | Consequence |
|---|---|---|
| Workers with no expenditure organization | 1,229 of 5,988 | POET cannot resolve; `V_OC_TIME_POET_READINESS` lists them |
| Projects with no Project Manager | 237 of 424 | RULE-015 has no approver to route to |
| Projects with `PJS_TRACK_TIME='Y'` | only 48 of 424 | everything else is invisible to time entry — verify that is intended |
| Projects/allocations with no chargeable WBS task | 15 projects / 42 allocations | nothing to charge against |
| `444` task `01.03` named "Leave" | `BILLABLE_FLAG='N'`, `IS_LEAVE='N'` | leave-looking task treated as ordinary non-billable work |
| Absence rows on the pod | **1** (data stops 2025-11-26) | see §4 — an empty leave row may be correct data |

### 3.6 Not sourced from Fusion at all — needs a decision

| Item | Note |
|---|---|
| `MAIN_PROJECT_ID` | no populator; needs the project-number match to `OC_PROJECT` confirmed first |
| `REVENUE_MODEL` / `PROJECT_MODEL` | null for every synced project, so leave-loss never triggers for them; module-owned, deliberately not synced — needs a source or a screen |
| `LEAVE_LOSS_FLAG` | same |
| `OC_TIME_ALLOCATION.BILLING_STATUS` | our own classification, deliberately never overwritten by sync |
| `OC_TIME_WORKER.APP_ROLE` | this app's entitlement, not HCM's — syncing it would demote every manager |
| Payroll reference | Payroll Time Type, payroll relationship, LDG, `payrollTimeDefinitionsLOV` — nothing extracted; needed only if the Payroll consumer is in scope |
| Contract / funding source / work type | available on `personAssignmentLaborSchedules`; not modelled. Needed if costing requires them |
| Period & cut-off dates | local by decision (PAGE-008 removed); not from Fusion |
| Absence types as an LOV | arrives inside `ABSENCES`; a standalone list is needed only to *create* absences |

### 3.7 Scheduling — nothing to replace

There is **no scheduler in this codebase**: `DBMS_SCHEDULER`, `CREATE_JOB`,
`CREATE_SCHEDULE` and `CREATE_PROGRAM` appear nowhere in `db/` or `integration/`.
Every job is a PL/SQL function exposed as a POST endpoint for OIC to call:

| Endpoint | Member |
|---|---|
| `POST oc/time/admin/jobs/daily` | `populate_daily` |
| `POST oc/time/admin/jobs/populate/:periodId` | `populate_month` |
| `POST oc/time/admin/jobs/defaulting/:periodId` | `run_weekly_defaulting` |
| `POST oc/time/admin/jobs/delivery-defaulting/:periodId` | `run_delivery_defaulting` |
| `POST oc/time/admin/jobs/accrual/:periodId` | `run_accrual_top_up` |
| `POST oc/time/approval/salaryhold/run/:periodId` | `run_salary_stopping` |
| `POST oc/time/admin/sync/retry/:failedId` | one failed row |

`run_salary_stopping` filters `DEFAULTED_BY='EMPLOYEE'`, which only
`run_weekly_defaulting` sets — so it must run **after** weekly defaulting for the
same period or it holds nobody. Delivery defaulting writes `'MANAGER'` and
deliberately never triggers a hold.

**Period auto-close (RA-009) has no endpoint at all** — if OIC owns scheduling,
that job still has to be written.

None of these has ever run on a schedule against real data. Run each once by hand
and inspect its `OC_TIME_SYNC_JOB` row before leaving it unattended.

---

## 4. Absence is read live, per person, per date

**Decided 05-Aug-2026.** Absence comes from Fusion for **that person and those
dates**, queried as the screen loads — not from the synced `OC_TIME_ABSENCE` copy.

This replaces an earlier entry here that recorded "synced absences do not render
correctly" as a deferred UI defect. That framing was wrong. The fault is the
*source*, not the rendering: a scheduled extract cannot answer "is this person on
leave on this date" for a date the extract did not cover, and the reference pod
demonstrates it — `ABSENCES` returns **one** row because that pod's absence data
stops at 2025-11-26. Time spent on the grid bindings would have found nothing wrong
with the grid.

```
GET /hcmRestApi/resources/11.13.18.05/absences
    ?q=personNumber={employeeId} AND startDate<={weekEnd} AND endDate>={weekStart}
```

**It still lands as entry rows.** Leave hours feed the week total, the leave-loss
calculation (RULE-009) and the accrual figures, so the live result is written as
`OC_TS_ENTRY` rows with `IS_LEAVE='Y'` rather than drawn as a display-only overlay —
an overlay would leave all three short while looking correct on screen.

**Open, and now a functional question rather than a bug:** an entry requires a
project, so a leave row must attach to one of the person's allocations. Someone with
no active allocation has nowhere to hang it and the row is dropped silently. Needs a
rule — the organization project, the last allocation held, or reported as an
exception.

**Diagnostic note for later:** absence display problems are to be investigated by
checking what the source returned for that person and that date, before looking at
the screen.
