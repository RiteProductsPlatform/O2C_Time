# Time Management Tool — Oracle Fusion Integration Reference

## 1. Solution Overview

Your app's flow maps to Fusion this way:
1. **Prepopulate** time grids from Projects (WBS/Tasks) and resource assignments, from HCM worker/assignment data, and from work schedules + org calendars (Section 3b).
2. **Employee** creates/edits/submits time in your app.
3. **Manager** approves/rejects (in your app, and/or mirrored into OTL's own approval workflow).
4. **Downstream sync**: push approved time into Oracle Time and Labor (OTL), which is the system of record; OTL's native processing then feeds **Project Costing** and **Payroll** — your app does not need to write directly into Payroll or Project Costs.
5. Your app also pushes the finalized time payload to your **other product** (outside Fusion) in parallel.

---

## 2. HCM — Worker & Assignment Data
Base: `/hcmRestApi/resources/11.13.18.05/`

| Purpose | Method | Path |
|---|---|---|
| Get all workers | GET | `/workers` |
| Get a worker | GET | `/workers/{workersUniqID}` |
| Create/Update a worker | POST/PATCH | `/workers` |

Note: Oracle's own guidance says not to use these endpoints for bulk extraction or for detecting changes — use HCM Extracts / Atom feeds for that. For your prepopulation logic, `GET /workers` (filtered by personNumber/personId) plus assignment sub-resources is the right source for employee/assignment master data.

**Person number → person ID.** Most downstream resources key off the internal `PersonId`, not the business-facing person number. The standard hop:

```
GET /workers?q=PersonNumber=12345&fields=PersonId&onlyData=true
GET /absences?q=personId=300000012345678
```

Watch the casing — `workers`/`emps` use PascalCase (`PersonId`), while `absences` uses camelCase (`personId`). Use `workers` rather than `emps` if you need contingent workers, pending workers, or terminated people, since `emps` covers employees only. Both resources are date-effective; add `&effectiveDate=YYYY-MM-DD` when chasing historical or future-dated rows.

---

## 3. Projects — WBS, Resource Assignments (for prepopulation)
Base: `/fscmRestApi/resources/11.13.18.05/`

| Purpose | Method | Path |
|---|---|---|
| Get all tasks for a project (WBS) | GET | `/projects/{ProjectId}/child/Tasks` |
| Create/Update/Delete a task | POST/PATCH/DELETE | `/projects/{ProjectId}/child/Tasks/{TasksUniqID}` |
| Get all project resource assignments | GET | `/projectResourceAssignments` |
| Get a project resource assignment | GET | `/projectResourceAssignments/{AssignmentId}` |
| Create a project resource assignment | POST | `/projectResourceAssignments` |
| Adjust/replace resource assignment schedule | POST | `/projectResourceAssignments/{AssignmentId}/action/adjustAssignmentSchedule`, `/action/replaceResource` |

Use `projectResourceAssignments` (filtered by person/project) plus `Tasks` to build your prepopulated grid of project × WBS task × resource for each employee.

**This gives you the columns of the grid, not the rows.** Resource assignments tell you *what* an employee can charge to; work schedules (Section 3b) tell you *which days and how many hours* to prefill. You need both.

---

## 3b. Work Schedules & Organizational Calendars
Base: `/hcmRestApi/resources/11.13.18.05/`

Two distinct concepts here, and it's worth keeping them separate in your head:

- **Work schedule** — per-employee. Which days and hours *this person* is expected to work. Drives the shape of their prefilled grid.
- **Organizational / absence calendar** — org-level. Holidays and working-day patterns for a legal entity, department, or similar group over a date range. Supporting reference data that Absence Management and schedule calculation consume behind the scenes.

### 3b.1 Work Schedules

| Purpose | Method | Path |
|---|---|---|
| Create/import a schedule | POST | `/scheduleRequests` |
| Get a schedule request | GET | `/scheduleRequests/{schedRequestId}` |
| Retrieve schedules via the time record resource | GET | `/timeRecordGroups` filtered with `groupType=Schedule` |

`timeRecordGroups` is multi-purpose — the same resource returns time cards, absences, or schedules depending on `groupType`, which is convenient if you're already calling it for time card retrieval in Section 4. One resource, one auth path, one client.

> **⚠️ Verify before building on this.** `scheduleRequests` is primarily a *write/import* surface: you POST a schedule change and get back a request record with a processing status. It is not obviously a clean "read this employee's expected hours for date range X" endpoint, which is what prepopulation actually needs. The `timeRecordGroups` + `groupType=Schedule` route is the more promising read path, but the exact finder name and parameter syntax need confirming against your pod. Run `/scheduleRequests/describe` and `/timeRecordGroups/describe` and check the registered finders before committing to a design.

### 3b.2 Organizational (Absence) Calendars

Technically named `absenceCalendars` in the API despite being a general org calendar concept.

| Purpose | Method | Path |
|---|---|---|
| Get all / one calendar | GET | `/absenceCalendars`, `/absenceCalendars/{CalendarId}` |
| Create/Update/Delete | POST/PATCH/DELETE | `/absenceCalendars`, `/absenceCalendars/{CalendarId}` |
| Advanced search | POST | `/absenceCalendars/action/findByAdvancedSearch` |

### 3b.3 How this fits your prepopulation logic

The practical layering, per employee per period:

1. **Work schedule** establishes the baseline — which days are working days and the expected hours on each.
2. **Org calendar** removes public holidays and applies org-level working patterns.
3. **Absences** (Section 5) removes approved leave days so employees don't double-enter.
4. **Project resource assignments + tasks** (Section 3) supply the chargeable columns.

Strictly speaking you *can* skip step 2 — holidays generally already influence schedule and absence calculations inside Fusion. But if you're computing expected hours yourself rather than reading a resolved schedule, you'll want the holiday list explicitly, or your grid will show expected hours on Christmas Day. Decide early whether Fusion resolves the schedule for you or your app does the arithmetic; that choice determines whether `absenceCalendars` is a required call or optional reference data.

---

## 4. Time and Labor (OTL) — Core of Your Time Entry Flow
Base: `/hcmRestApi/resources/11.13.18.05/`

| Purpose | Method | Path |
|---|---|---|
| Create/import a time entry (creates the time card if it doesn't exist) | POST | `/timeRecordEventRequests` |
| Get time record groups (time cards, incl. statuses/messages/attributes) | GET | `/timeRecordGroups` (supports `finder` filters by personNumber, date range, groupType) |
| Get a time record group / time record | GET | `/timeRecordGroups/{id}`, child `/timeRecords` |
| Time attributes (e.g., payroll time type, **project**, task) | GET | `/timeRecordGroups/{id}/child/timeAttributes` |
| Update transfer/consumption status after sending to a downstream system (payroll, project costing, etc.) | POST | `/statusChangeRequests` |

Key details from Oracle's use-case docs:
- `timeRecordEventRequests` accepts a `processMode` of `TIME_SUBMIT`, which both creates the entry **and submits the time card for approval** in one call — useful for your "employee creates and submits" step.
- Time attributes explicitly include **project** and task as importable fields alongside payroll time type, confirming OTL is project-aware.
- After OTL data is extracted and loaded into payroll or another consumer, you call `statusChangeRequests` with a `consumerCode` (e.g., `PYR` for payroll) to mark entries as transferred — this is the officially documented way to reconcile status between OTL and your app/payroll.

This is the primary integration surface for your tool: your app pushes finalized/approved time here, and Oracle's internal OTL processes handle onward flow into Project Costing and Payroll.

---

## 5. Absences (for context/overlap handling)
Base: `/hcmRestApi/resources/11.13.18.05/absences`

| Purpose | Method | Path |
|---|---|---|
| Get all absence records | GET | `/absences` (filter with `q=personId=...` or `q=personNumber=...`) |
| Get one absence record | GET | `/absences/{absencesUniqID}` |
| Create/Update/Delete an absence | POST/PATCH/DELETE | `/absences` |
| Daily/shift breakdown of an absence | GET/POST | `/absences/{id}/child/absenceEntryDetails`, `/action/absenceDailyDetailsBreakdown` |

Note that `/absences/{absencesUniqID}` is a **single-record fetch keyed on `personAbsenceEntryId`** — you must already know the specific absence's key. For "give me this person's absences," use the collection GET with a `q` filter. Confirm on `/absences/describe` whether `personNumber` is directly queryable on your pod; if not, do the `PersonNumber → PersonId` hop from Section 2 first.

You can combine filters and add paging:

```
GET /absences?q=personId=300000012345678;startDate>=2026-01-01&limit=50&offset=0&onlyData=true
```

If your time grid needs to reflect approved leave (so employees don't double-enter time on absence days), pull this alongside schedule data during prepopulation.

---

## 6. Project Costing (downstream — read-mostly)
Base: `/fscmRestApi/resources/11.13.18.05/`

| Purpose | Method | Path |
|---|---|---|
| View/adjust project costs (time card items become cost records here) | GET/PATCH/POST(adjust) | `/projectCosts` |
| View/update expenditure batches pending approval | GET/PATCH | `/projectExpenditureBatches` |

There is no direct "create" endpoint here for external systems — cost records are populated automatically once OTL time is processed and interfaced into Project Costing. Your app should not attempt to post directly into `projectCosts`; treat it as a query/audit endpoint only.

---

## 7. Payroll (downstream — no direct write needed)
Base: `/hcmRestApi/resources/11.13.18.05/`

| Purpose | Method | Path |
|---|---|---|
| View payroll relationships/assignments (for reference/validation) | GET | `/payrollRelationships`, `/payrollRelationships/.../payrollAssignments` |

Payroll consumes time through Oracle's standard OTL-to-Payroll extract/load process, not via a direct REST write from your app. Use `statusChangeRequests` (Section 4) with `consumerCode: "PYR"` to confirm/reconcile once payroll has consumed the data.

---

## 8. Financials — AR Invoices & GL (typically downstream of Project Billing)
Base: `/fscmRestApi/resources/11.13.18.05/`

| Purpose | Method | Path |
|---|---|---|
| Create/Get/Update a receivables (AR) invoice | POST/GET/PATCH | `/receivablesInvoices` |
| View journal batches / headers (GL) | GET/PATCH | `/journalBatches`, child `/journalHeaders` |

In a typical project-billing flow, approved project time drives billing events in Projects, which generates AR invoices and GL journals through Oracle's own subledger accounting — your time tool would not normally call these directly. Include them here mainly for visibility/audit querying if your team needs to confirm that time ultimately reached billing/GL.

---

## 9. Contracts

Enterprise Contracts in Fusion is mainly a contract lifecycle/CLM product, not a direct consumer of time data. If "CONTRACT" in your scope means contract-billing terms driving project revenue, that's governed within Projects/Project Billing configuration rather than a REST call your time app needs to make directly. Flag this to your architecture team if there's a more specific contract-linkage requirement — it would need separate investigation.

---

## 10. Suggested Integration Sequence

1. Nightly/on-demand: pull `workers` for employee master data, and `projectResourceAssignments` + `Tasks` to establish which projects/WBS tasks each employee can charge to.
2. For the same employees and date range, pull **work schedules** (Section 3b) to determine expected working days and hours — this defines the shape of the prefilled grid.
3. Pull `absenceCalendars` for applicable holidays, **if** your app computes expected hours itself rather than consuming a Fusion-resolved schedule.
4. Cross-check `absences` for the same date range to avoid conflicting entries on approved leave days.
5. Employee edits/submits in your app → your app calls `timeRecordEventRequests` (processMode `TIME_SUBMIT`) to write into OTL, and also sends the same payload to your other product.
6. Manager approval: either mirror your own approval gate before calling OTL, or rely on OTL's native approval workflow triggered by the submit call — decide which system is the approval "source of truth" to avoid double workflows.
7. Once OTL processes and interfaces the data to Payroll/Project Costing (automatic, native Fusion processes), call `statusChangeRequests` to reconcile status back with your app.
8. Use `projectCosts` / `receivablesInvoices` / `journalBatches` only for read/audit confirmation that data landed correctly downstream.

---

## 11. Notes

- All endpoints require authentication (Basic Auth or OAuth) — set this up per your Fusion environment's security configuration.
- Test all POST/PATCH flows in a non-production Fusion instance first.
- Field-level schemas for each resource can be pulled from Oracle's REST API docs (`docs.oracle.com`) under the respective book (HCM: `farws`, Financials: `farfa`, Project Management: `fapap`).
- **Prefer `/describe` over the published docs.** Docs are versioned per release and your pod may be on a different update than the page you're reading. `GET /{resource}/describe` returns the queryable attributes and registered finders actually available in *your* environment. When they disagree, `/describe` wins.
- Useful query modifiers across resources: `fields=` to trim payloads, `onlyData=true` to strip HATEOAS `links` blocks, `limit=`/`offset=` for paging, `effectiveDate=` on date-effective resources, and `;` to chain conditions inside a single `q=`.

---

## 12. Open Items to Confirm

| Item | Why it matters | How to resolve |
|---|---|---|
| Read path for per-employee work schedules | Prepopulation depends on it; `scheduleRequests` may be write-only in practice | `/scheduleRequests/describe`, `/timeRecordGroups/describe`; check `groupType` finder |
| `groupType=Schedule` filter syntax on `timeRecordGroups` | Determines whether one resource serves time cards + schedules | `/timeRecordGroups/describe` finders list |
| Whether `personNumber` is directly queryable on `absences` | Saves a round trip per employee | `/absences/describe` |
| `findByAdvancedSearch` payload shape on `absenceCalendars` | Needed only if you query holidays explicitly | `/absenceCalendars/describe` |
| Approval source of truth (your app vs OTL native workflow) | Architectural, not an API question — but blocks step 6 | Internal decision with architecture team |
