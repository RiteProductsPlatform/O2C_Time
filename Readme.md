# O2C Timesheet Module — V2

Oracle Visual Builder application for project time capture, approval and hand-off.
Functionally the same module as `O2C/Time Module/O2C_Time`, rebuilt on the Redwood
starter app that Visual Builder generated here, following the VBCS page-builder
documentation (`vbcs-docs`: `knowledge/`, `rules/`, `skills/templates/`).

---

## 1. What this is

A self-contained application — its own ATP schema, its own ORDS surface, its own
VBCS web app. It does not read or write the O2C main application's tables.

**Oracle Time & Labor is the system of record.** This module prepopulates from
Fusion, captures and approves time, then pushes approved time to OTL, which feeds
Project Costing and Payroll natively. We never write to Payroll or Costing
directly, and downstream financials are read-only.

```
  Fusion HCM ──┐                                    ┌──> Oracle Time & Labor
  (workers,    │                                    │    (SYSTEM OF RECORD)
   schedules,  ├──> ┌──────────────────────┐ ───────┤         │
   absences)   │    │   O2C TIME MODULE    │        │         ├─> Project Costing
               │    │  (this application)  │        │         └─> Payroll
  Fusion PPM ──┘    │                      │        │
  (projects,        │  capture · approve   │        └──> our other product
   WBS tasks,       │  adjust · confirm    │             (parallel push)
   assignments)     └──────────┬───────────┘
                               │
                               │ fills XX_O2C_TIMESHEET_ACCRUAL_IF
                               ▼
                    ┌──────────────────────┐
                    │  O2C Accrual app     │  ← PULLS after month-end
                    │  (separate product)  │     manager approval
                    └──────────────────────┘
```

### The accrual contract — direction matters

On month confirmation this module **fills** `XX_O2C_TIMESHEET_ACCRUAL_IF` with the
consolidated timesheet (employee × project × WBS task × day) plus day-wise
`Reversal(−)` / `Adjustment(+)` rows. The accrual application then **pulls**:

```
GET  /oc/time/admin/accrual/pull/{year}/{month}   → unprocessed rows for the month
POST /oc/time/admin/accrual/ack/{batchId}         → { "status": "Y" | "E" }
```

Only rows from a confirmation whose `ACCRUAL_STATUS = 'Success'` are served, and
only unprocessed rows — so the pull is resumable and cannot double-count.
`Reversal` rows carry **negative** hours, so the consumer can `SUM()` the three
hour columns with no sign handling and get the net position.

---

## 2. Layout

```
O2C_TIME_V2/
├── db/                      SQL, carried over from V1 — all idempotent
│   ├── 01..10_*.sql         schema, package, seed
│   ├── install_time.sql     ordered installer
│   └── ords/11..13_*.sql    oc.time · oc.time.approval · oc.time.admin
│
├── services/
│   ├── catalog.json         one backend: oc_time
│   └── oc_time/openapi3.json  68 operations
│
└── webApps/vbredwoodapp/
    ├── app-flow.json        26 application variables + the session context
    ├── app-flow.js          shared display helpers ($application.functions.*)
    ├── pages/shell-page.*   Redwood applayout: drawer nav (RBAC), manager
    │                        switcher, messages banner + toast, router outlet
    │   └── shell-page-chains/   8 chains: bootstrap, navigate, drawer,
    │                            manager switch, 3 notification handlers
    ├── resources/css/o2ctime.css   shared design system (capsules, chips)
    │                               plus a <page-name>.css beside every page
    └── flows/               11 flows, one page each, 94 action chains
```

**Counts:** 11 flows · 11 pages + shell · 102 action chains (94 in flows, 8 in the
shell) · 32 JSON files · 57 of the 68 ORDS operations called from the UI (see §6).

---

## 3. Install

```sh
# 1. REST-enable the schema (once)
#    RA-002: anonymous access is acceptable in lower environments ONLY.
#    Harden to https + API key / OAuth2 before PROD.
sqlplus o2c_time/<pwd>@<tns>
  BEGIN ORDS.ENABLE_SCHEMA(p_enabled => TRUE,
                           p_schema  => 'O2C_TIME',
                           p_url_mapping_type    => 'BASE_PATH',
                           p_url_mapping_pattern => 'o2c_time',
                           p_auto_rest_auth      => FALSE); COMMIT; END;
  /

# 2. Install everything (re-runnable; nothing is dropped)
cd db
sqlplus o2c_time/<pwd>@<tns> @install_time.sql
```

Then:

1. **Load Fusion master data** via OIC into `OC_TIME_WORKER`, `OC_TIME_PROJECT`,
   `OC_TIME_TASK`, `OC_TIME_ALLOCATION`, `OC_TIME_ABSENCE` (INT-001 … INT-006).
2. **Sync the calendar layers** —
   `POST /oc/time/admin/calendar/sync/{CORPORATE|PROJECT|CLIENT|SHIFT}`.
3. **Run population** — `POST /oc/time/admin/jobs/populate/{periodId}`.
4. **Point VBCS at the schema** — `services/catalog.json` →
   `backends.oc_time.servers[0].url`, and `app-flow.json` →
   `variables.ordsBaseUrl` (used by the client-document download, which streams a
   binary and so does not go through `callRest`).

---

## 4. How V2 differs from V1

Same requirements, same database, same REST contract. What changed is the web
app, which now follows the documented VBCS patterns rather than a hand-rolled
design system.

| Area | V1 | V2 |
|---|---|---|
| Web app | `vbtimeapp`, custom `rw-*` CSS, plain `<div>` layout | `vbredwoodapp`, Oracle Redwood — `oj-sp-general-overview-page` roots, JET grid/spacing/typography classes |
| Shell | custom `<aside>` nav, hand-built toast `<div>` | `oj-web-applayout-*` frame, `oj-drawer-popup` + `oj-navigation-list`, `oj-sp-messages-banner` + `oj-sp-messages-toast` |
| Notifications | pages fired an `appToast` app event | pages call `Actions.fireNotificationEvent` → `vbNotification` → `showNotificationMessage` (`knowledge/03`); transient messages render in the toast per the Pages sheet, persistent ones in the banner |
| Data providers | chains reassigned the ADP variable on every load | array-linked ADPs: `"data": "{{ $page.variables.xArray }}"`, chains assign the array only (`knowledge/09 §3`) |
| Navigation | `navigateToPage('shell/<x>/main')` | `navigateToFlow({flow, page})` — every destination is its own flow (`rules/rules.md §5.5`) |
| GET caching | none | `_t: Date.now()` on every GET, declared in the OpenAPI spec so VBCS does not strip it (`knowledge/04 §4`) |
| CSS | two files of bespoke design system | one shared file (status capsules, flag chips, grid states) plus a `<page>.css` per page as S2 requires — everything else is Redwood `--oj-core-*` variables |

### Defects found while porting, fixed in V2

| Where | Problem | Fix |
|---|---|---|
| `db/ords/13_ords_time_admin.sql` | The compliance handler still selected `corrections` and `contractor_unbilled`, dropped from `v_oc_ts_compliance` by the 30-Jul revision. `getCompliance` would fail at runtime. | Handler now selects the view's actual columns, including `employee_defaulted` |
| `shell-page-chains/showNotificationMessage.js` (VB scaffold) | `messageId` had no `defaultValue` (→ `NaN` keys), auto-dismiss tested `displayMode === 'transient'` (never true from JS chains), and read `event.type` only | `defaultValue: "1"`, string keys via `String()`, `!== 'persist'`, and `event.severity \|\| event.type` |
| PAGE-002, PAGE-003, PAGE-004 | Page modules fired listeners as `{detail:{x}}` while the listener read `{{ $event.x }}` — the parameter arrived `undefined`, so remove / open / approve did nothing | Payloads are flat objects matching the declared parameter |
| PAGE-003 | `projectFilter` (FLD-028) had no `onValueChanged`; typing in it never re-filtered | `filterProjectsChain` re-derives from a cached array on every keystroke |
| PAGE-007, PAGE-010 | Optional query params passed as `parameters:` rather than `uriParams:` — VBCS drops them, so the manager scope filter and the unresolved-only filter were silently ignored | Both now go in `uriParams` |
| PAGE-001, PAGE-004 | Referenced `Late submission` as a status and `contractor_unbilled_flag` / `correction_flag`, all removed by the 30-Jul revision | Uses the current 7 statuses and 6 flags |

---

## 5. Status and flag model

The schema in `db/` implements the **30-Jul-2026 revision**: 7 statuses, 6 flags.
`STATUS_AND_FLAG_MODEL.md` describes this as pending sign-off, but the DDL, the
package and the seed data have already been migrated — `DEFAULTED_BY` exists,
`HAS_REVERSAL_FLAG` is the renamed `HAS_CANCEL_FLAG`, and `CORRECTION_FLAG` /
`CONTRACTOR_UNBILLED_FLAG` are gone. V2's UI matches the schema.

**Statuses (7):** `Not yet submitted` · `Submitted` · `Approved` · `Rejected` ·
`Defaulted` · `Overridden and approved` · `Closed`

**Flags (6):** `Defaulted` · `Late submission` · `Advance closure` ·
`Overridden & approved` · `Reversal` · `Adjustment`

Both are rendered from one place — `$application.functions.statusClass()` and
`$application.functions.weekFlags()` in `app-flow.js` — so the employee's page and
the manager's pages cannot describe the same week differently. `Defaulted` is
reported with its cause (`DEFAULTED_BY`), because a week defaulted by a manager
missing the delivery cut-off is not the employee's failure and does not hold pay.

Three decisions in `STATUS_AND_FLAG_MODEL.md §7` are still open; the code follows
the document's own recommendation in each case (salary stopping acts on
`DEFAULTED_BY = 'EMPLOYEE'`; `Defaulted` blocks confirmation; both `Defaulted` and
`Overridden and approved` remain as status *and* flag).

---

## 6. Pages

| Page | Requirement | Flow | Chains |
|---|---|---|---|
| My Timesheet | PAGE-001 | `my-timesheet` | 13 |
| Client Timesheets | PAGE-002 | `client-timesheets` | 4 |
| Team Approvals (landing) | PAGE-003 | `team-approvals` | 7 |
| View Timesheet (monthly summary) | PAGE-004 | `view-timesheet` | 9 |
| Approval Detail (weekly / daily) | PAGE-005 | `approval-detail` | 14 |
| Leave Loss Coverage | PAGE-006 | `leave-loss-coverage` | 8 |
| Salary Stopping | PAGE-007 | `salary-stopping` | 8 |
| Calendar (Fusion Sync) | PAGE-009 | `calendar-sync` | 5 |
| Sync Status | PAGE-010 | `sync-status` | 7 |
| Accrual Integration | PAGE-011 | `accrual-integration` | 5 |
| Integrations | PAGE-012 | `integrations` | 3 |

**PAGE-008 Period Control is deliberately not a screen** — removed 29-Jul, it is
reference data maintained outside the app. `oc.time.admin` still exposes it
read-only and its cut-off dates still drive FLD-003 and FLD-036.

### ORDS operations the UI does not call (11 of 68)

Not gaps — each is deliberate:

| Operation | Why |
|---|---|
| `pullAccrual`, `ackAccrual` | Called by the **accrual application**, not by this UI. That is the contract. |
| `downloadClientDoc` | Streams a binary; the page opens it directly via `ordsBaseUrl` rather than pulling a 20 MB blob through `callRest`. |
| `saveEntry`, `removeLine` | Superseded by `saveEntriesBatch` — the grid saves in one transaction, and a removed line is saved as zeros through the same path. |
| `ensureWeek` | Weeks are created by the population job; the UI never needs to conjure one. |
| `approveAllWeeks` | PAGE-005 loops per week instead, so a refusal on one week does not discard the others. |
| `getAdminPeriods`, `getLookups`, `getConfig`, `getCompliance` | Read-only endpoints with no screen (PAGE-008 removed; compliance is REP-005 reporting). |

---

## 7. Conformance to the requirements metadata

Checked against `O2C_Timesheet_Requirements_Metadata_COMPLETE.xlsx` (21 sheets;
headers on row 3). Gaps found and closed:

| Sheet | Requirement | Action |
|---|---|---|
| Pages · Actions | PAGE-009 `components_required: sync-buttons`, ACT-030 *Sync Calendar Layer* | **Added.** RA-005 closed calendar *authoring*, not syncing — a per-layer Sync button now calls `syncCalendarLayer`. |
| Pages | `pagination_required = Yes` for PAGE-010 and PAGE-011 | **Added.** `scroll-policy="loadMoreOnScroll"`, fetchSize 25, on all five tables. |
| Pages | `error_state_behavior = Toast error` (every page) | **Changed.** Transient notifications now render in `oj-sp-messages-toast`; the banner is reserved for `displayMode: 'persist'`. |
| Pages | `empty_state_behavior` — exact wording per page | **Aligned.** Each empty state now leads with the metadata phrase. |

Deliberate deviations, each with a reason:

| Item | Metadata says | Built as | Why |
|---|---|---|---|
| ACT-018 | Download / Upload day-wise Excel on PAGE-005 | **not built** | No ORDS endpoint exists for it in either V1 or V2. Needs a backend before a UI. |
| ACT-033 | *Run Accrual Job* on PAGE-011 | **not built** | RA-019 settled the accrual hand-off as a **pull**: the accrual application collects from the interface table. There is no push job to run. |
| ACT-006 | *Set Day Shift* on PAGE-001 | read-only | RULE-011 makes shift one-per-day and read-only from HCM. The rule wins over the action. |
| ACT-019 | *Approve All Pending Weeks* | Select-all + Approve | PAGE-005 loops per week so one refusal does not discard the rest; the outcome is the same, `approveAllWeeks` stays unused. |
| ACT-027/28/29 | PAGE-008 period actions | no screen | PAGE-008 was removed 29-Jul; it is reference data. |
| Data_Dictionaries | 9 statuses / 8 flags | **7 / 6** | Superseded by the 30-Jul-2026 revision, which the shipped DDL, package and seed already implement (see §5). The workbook is stale on this point. |
| Pages | `responsive_behavior = Desktop/tablet` (all pages) | desktop/tablet | This is why `knowledge/14`'s mobile-first `oj-sm-*` grid declarations and the `index.html` mobile guard are **not** applied. Wide tables scroll inside their own `overflow-x` containers per `14 §3`. |

---

## 8. Conformance to the VBCS standards

Audited against `rules/VBCS_Coding_Standards.md` (S1–S8),
`rules/checklist.md`, `rules/rules.md`, `rules/vbcs-best-practices.md` and
`knowledge/14`. **FAIL-level violations: 0.**

| Standard | Result |
|---|---|
| S1 no inline JS in bindings | clean — 47 ternaries/concatenations moved to `$page.functions.*` / `$application.functions.*`; no `document.getElementById` |
| S2 no inline CSS | clean — 0 `style=` attributes; 13 page CSS files (`mts-`, `ctim-`, `apdt-` … prefixes) beside the shared design system |
| S3 no raw fetch | clean — every call is `Actions.callRest` |
| S5 no hardcoded URLs | clean in all `.js`/`.html`. `ordsBaseUrl` remains in `app-flow.json` as environment config, mirroring `catalog.json` |
| S6 endpoint schemas | all 57 called operations are in `openapi3.json` with responses |
| S7 no bare `object` types | clean. ADPs are `vb/ArrayDataProvider2` declaratively, per `knowledge/03`/`09` and the VB scaffold — S7's `"any"` guidance targets ADPs built in code |
| S8 no `oj-bind-for-each` for records | 7 uses, all ≤10 non-record items (6 flag chips, 7 day headers, ≤7 rejected dates) — inside S8's stated exception |
| SES (`14 §7`) | clean — no `window`/`document` in any chain or page module |

Defects fixed during the audit:

- **`window.confirm` in 5 chains and `window.open` in 1 page module** would have
  thrown `SES_UNCAUGHT_EXCEPTION` under JET's lockdown, breaking Confirm Month,
  Advance Approve, Run Defaulting, Approve All Coverage, Remove Document and
  Download. Replaced with `oj-dialog` + `Actions.callComponentMethod` on Oracle's
  own cookbook pattern, and an `<a :href>` for the download.
- **`AbortError`** is now swallowed in all 48 reporting catch blocks — JET aborts
  in-flight requests on re-render, which was being reported as "service
  unreachable".
- **Two pages had no page module** (`leave-loss-coverage`, `salary-stopping`),
  breaking the `knowledge/01` page trio. Created.
- **The Visual Builder scaffold flow `flows/main`** was dead and non-conformant;
  its files are deleted (the empty directory may linger until OneDrive releases
  its lock).

Outstanding **WARN**-level items, not yet done:

- `noData` slots on 23 `oj-select-single` / 21 `oj-table` (page-level empty
  states already exist via `oj-bind-if`);
- `label-edge="inside"` — currently `"top"` on 19 form layouts;
- justification comments on the 7 permitted `oj-bind-for-each` uses.

---

## 9. Validation performed

Static cross-reference over the web app — **0 errors, 0 warnings**:

- all 32 JSON files parse;
- every `callRest` endpoint resolves to an `operationId` in the service;
- every chain referenced by a page (including `shell/…`) resolves to a file, and
  every chain file on disk is reachable;
- every chain's class name matches its file name and is returned;
- every `$listeners.*` and `$page.listeners.*` used in HTML is declared in that
  page's `eventListeners`;
- every `$variables.*` used in HTML is declared in that page's JSON;
- every `$page.functions.*` exists in its page module, and every
  `$application.functions.*` / `$application.variables.*` exists in `app-flow.*`;
- every `oj-*` component used in HTML is imported in the page JSON.

**Not done, and required before UAT:** execution against a real ATP/ORDS instance,
`SHOW ERRORS` on the package after compilation, running the app in the Visual
Builder designer, and the SC-01 … SC-25 functional scenarios from the `Tests`
sheet. Nothing here has been run against a live backend.

---

## 10. Known leftovers

- **`webApps/vbredwoodapp/flows/main/`** — the Visual Builder starter flow. Its
  files are deleted; the empty directory may persist until OneDrive releases its
  file lock, and can be removed by hand.
- **OTL push (INT-007)** is not wired. `OC_TS_MONTH_CONFIRM.OTL_STATUS` tracks it
  and PAGE-011 renders `Pending` without treating it as a failure, because the
  actual `POST /timeRecordEventRequests` is an OIC flow that does not exist yet.
- **Notifications (NOTIF-001 … NOTIF-011)** raise audit events; email/in-app
  delivery is an OIC responsibility.
- **Master-data sync (INT-001 … INT-006)** — target tables, upsert keys and the
  failed-record queue exist; the OIC flows that fill them do not.
