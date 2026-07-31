# CrewRite — Consolidated Knowledge Base

> Single-source reference distilled from the FSD, RBAC TSD, physical data model, and the
> live VBCS application. The `crewrite-expert` agent uses this as its primary index and
> falls back to the source documents (paths in the last section) for finer detail.
> Last built: 2026-07-22.

---

## 1. What CrewRite is

CrewRite (a.k.a. **Crew Rite V2**) is an enterprise **workforce orchestration and
time-tracking platform** for large-scale field/construction operations. It is a
**multi-tenant product** serving 11+ customer deployments from a single codebase.

- **Front end:** Oracle **VBCS** (Visual Builder), Redwood theme — app id `vbredwoodapp`.
- **Back end:** Oracle **ORDS / PL-SQL** over schema **`TIMERITE`** (ORDS module `/ords/timerite`).
- **Overlays:** Oracle **Fusion HCM** (employees, jobs, assignments, absences) and
  **FSCM** (customers, contracts, projects, tasks, non-labor resources, PO data).
- **Downstream:** validated data is pushed asynchronously via **OIC** to **Oracle Time & Labor
  (OTL)**, **Oracle Payroll**, and **Oracle Projects**.

**Document IDs:** FSD = `CR-FSD-2026-001` v2.0 (Mar 3 2026). RBAC TSD = v3.0 (Apr 5 2026).

### The single most important design decision — Crew ≠ Project
The reason the legacy app is being rebuilt: **decouple Crew Definition from
Project/Contract/Customer affiliation.** In the old app a crew was permanently tied to one
customer/contract/project at creation, making crews non-reusable and overloading the screen.
New design: a crew is pure identity + membership; it can be assigned to Project A for 3 months,
then Project B, with no change to the crew, and can span multiple projects in one week.

### Design principles
- **Multi-tenant product mindset** — fields shown/hidden via configuration; customer-specific
  fields via context-sensitive **DFFs**. ("We are not building this for one customer… disable it from configuration.")
- **Hierarchical default inheritance** — Installation → Customer → Contract → Project (future: Task);
  **lowest non-null value wins (NVL cascade)**.
- **Field rationalization** — every timesheet field must have a documented source (field-source matrix).
- **Timesheet completeness** — every approved timesheet must total **≥ 40 hours/week/resource**
  (regular + OT + PTO + holidays) before transfer to OTL. Incomplete = revenue leakage.

---

## 2. Module architecture (A–E)

| Module | Name | Scope |
|---|---|---|
| **A** | Crew Definition | Master data: crew header + resource membership (persons & equipment), effective dating. **NO project/contract/customer affiliation.** |
| **B** | Time Tracking Defaults | Hierarchical config (installation/customer/contract/project) controlling time-entry behavior. |
| **C** | Assignment / Schedule | Crew-to-project assignment, auto/manual timesheet generation, combination templates, exceptions. |
| **D** | Time Entry | Daily/weekly capture (hour & non-hour), review, approval workflow, OTL/Payroll/Projects transfer. |
| **E** | Integration & Reporting | OTL transfer, Payroll element creation, Projects cost feed, lockdown, audit/traceability. |

Whiteboard-confirmed flow: **Crew → Defaults → Assignments → Time Sheet (Entry, Approval, Report) → Reports/Integration.**

---

## 3. Module A — Crew Definition

Master data foundation. Captures **only identity and membership**. Project affiliation, billing/cost
rates, and scheduling are explicitly excluded.

**Crew Header fields (CR-A-001…011):** Crew Name, Crew Type (LOV), Timekeeper Primary (req), Timekeeper
Secondary, **Time Card Approver (NEW, req)**, Supervisor (req), Union Name (configurable, can be hidden
per customer), **Resource Type Control** (Person/Equipment/Both — NEW), Effective Start/End Date,
**Active Flag** (NEW, replaces legacy "Disbanded" with inverted logic).
*Removed from header:* Customer/Contract/Project Number, Project Specific, Crewtime Scope, Time Entry Method,
Crew Measure, Crew Start/End Day, Time In/Quantity grids, Mileage.

**Person Resource (CR-A-020…031):** Employee Number, Person Name (Last, First), **Craft/Trade (NEW, HCM)**,
**HR Job Title (NEW, HCM)**, **System Person Type = EMP or CWK (NEW, drives conditional fields)**,
Home Location, **PO Number / PO Line Number / Price Type (NEW — required when CWK)**, Effective Start/End,
Active Flag (auto-deactivated on termination).

**Equipment Resource (CR-A-040…047):** Equipment Number, Equipment Name/Description, Equipment Class (LOV),
Equipment Location, Non-Labor Resource Code (LOV), Effective Start/End, Active Flag.

**Business rules:** CR-A-BR01 terminated employees blocked from new entry (notify timekeeper, auto-deactivate).
CR-A-BR02 CWK ⇒ PO Number/Line mandatory; CWK time creates AP Receipts via pass-through.
CR-A-BR03 equipment linked to a person operator derives its time from the operator (linkage captured in Module C).
CR-A-BR05 Union Name configurable per installation. CR-A-BR06 DFFs available at resource level.

---

## 4. Module B — Time Tracking Defaults

Hierarchical configuration so timekeepers don't hand-enter 150+ fields per timesheet.

**Default hierarchy (priority 1 highest → 4 lowest):**
1. **Installation / System Settings** (business unit, operating unit) — CrewRite Settings screen
2. **Customer** — work week, OT, shifts, per diem, bonus
3. **Contract** — overrides within a customer
4. **Project** — final resolution point; every customer field overridable here
- **Future:** Task level.
- **Resolution = NVL:** lowest non-null wins. UI shows a **Default button + pencil icon** for overrides;
  overridden values are visually distinguished.

**Field groups:**
- **Work Week (CR-B-001…006):** Week Start/End Day, Period Days, Required Hours/Day, Default Start/End Time.
- **Shifts (CR-B-010…014, NEW):** Enable Shifts (master toggle — forces start/end entry), Enable Shift
  Differential, Number of Shifts (generates rows), Shift Definition sub-table (Name, From/To, Differential
  Rate/Multiplier), OT Shift Name.
- **Overtime (CR-B-020…024):** OT Allowed, OT Threshold Measure (Daily/Weekly), OT Limit (Hours),
  **OT Multiplier (NEW, e.g. 1.5×/2.0×)**, **Double-Time Threshold (NEW)**.
- **Documentation & Validation (CR-B-030…037):** Time Card Print Level (NEW), Time Card Approval Required,
  Time Card Collation, Time Card Balancing (vs badge records), Client ERS Enabled, Client ERP System,
  Equipment Module Enabled, Billing Frequency.
- **Additional Compensation (CR-B-040…054):** Per Diem (Enabled/Hours Threshold/Rate/Amount/Managed by HR),
  Bonus (Enabled/Hours/Rate/Amount), Safety Bonus, **Dynamic Element sub-table (NEW)** (Element Name,
  Customer Label, Rate/Amount, Rate Type), **Element-to-Payroll Mapping (NEW)**, **Customer Element Label (NEW)**,
  Default Expenditure Type, **Crew Time Entry Enabled (NEW — only flagged projects appear in LOVs)**,
  **Distance Threshold Miles (NEW — auto per diem/mileage eligibility)**, **Hazard/Uplift Rate (NEW)**.

**Business rules:** BR01 NVL cascade + override UI. BR02 **per diem is auto-generated** (checks: enabled at
project + employee eligible in HCM + distance threshold), never manually entered. BR03 routing — **Hours → OTL → Projects;
Non-hourly → Payroll + Projects directly.** BR04 customer-facing labels differ from internal payroll names.
BR05 bulk setup via **FBDI** (500+ customers). BR06 shift differentials have two angles: payroll costing vs contract
billing. BR07 REST for setup (low volume), nightly sync for high-volume. BR08 only `Crew Time Entry Enabled` projects appear.

---

## 5. Module C — Assignment / Schedule

Bridges crew definition and time entry; absorbs all project-affiliation fields removed from Module A.

**Three operational scenarios / time-entry modes:**
1. **Dedicated Crew** — assign crew to one project; system **auto-generates** weekly timesheets; review exceptions only.
2. **Multi-Project Crew ("hopping")** — use a **Combination ID**; enter hours; system expands to full POET.
3. **Manual Entry** — timekeeper picks crew/project/task/POET/date/hours per entry.

**Key fields (CR-C-001…022):** Crew, Customer/Contract/Project (cascading LOVs; project filtered by
`Crew Time Entry Enabled`), Task, Expenditure Type, Expenditure Organization (from employee dept), Hours/Day,
Assignment Start/End, Time Type, Schedule Time In/Out, **Location (State/County/City from project address DFF
— for US state income tax)**, Trade/Billing Title (overrides HCM job title), Write-In Rate, Bill/Cost Rate
(equipment), Shift Differential, **Combination ID**, Mileage Tracking, Comments (crew-level & person-level).

**Concepts:**
- **Combination** — a reusable per-customer template bundling POET + attributes; critical for timekeepers
  managing 200–300 crew across 10+ projects.
- **Crew Explode** — expanding a crew into individual resources so the timekeeper can select/deselect members
  for partial deployment (e.g. 12 of 15 this week).
- **Equipment-to-Person linkage** — equipment time derived from operator's logged hours (8h operator = 8h crane).

**Business rules:** BR01 auto timesheets pre-populate all active members; only exceptions adjusted.
BR03 field-source matrix required for every field. BR04 location from project DFF (US tax). BR07 distance-based
per diem/mileage eligibility. BR08 **Absence records (PTO, holidays, jury duty) from Oracle Absence Management
are display-only, NOT re-sent to OTL, but DO count toward the 40-hour check.**

---

## 6. Module D — Time Entry, Review & Approval

**Two-tab timesheet:**
- **Tab 1 – Hour-Based (Labor):** matrix grid, crew members = rows, days = columns, each cell = hours;
  row/column/grand totals; frozen left column. Handsontable-style.
- **Tab 2 – Non-Hour Elements (Non-Labor):** per diem, bonuses, allowances; person name matches Tab 1 rows;
  system-generated values (auto per diem) are read-only.

**Data elements (CR-D-001…019):** Employee Name/Number, Project/Task/Expenditure Type/Org, Time Type, Hours/day,
Weekly Total (calc), Week-Ending Date, Location, Trade/Billing Title, Write-In Rate, Shift + Shift Differential,
Per Diem Amount (auto), Bonus Elements, Customer-Specific DFFs, Comments, Status.

**Lifecycle:** Draft → Submitted (runs 40-hour completeness check) → Approved (customer signature may be
collected via printed card) → **Transferred** (locked; hours→OTL, non-hourly→Payroll, POET→Projects).
**Rejected** returns to Draft with comments.

**Business rules:** BR01 40-hour completeness with color-coded indicator (red/yellow < 40, green complete).
BR02 absences read-only, count toward 40h, not re-sent to OTL. BR03 OT auto-split into Regular + OT by threshold
(daily or weekly). BR04 per diem auto-generation. BR05 **Lockdown** freezes all timesheets during payroll windows.
BR06 late submissions → **retro payroll**. BR07 staging tables retained permanently (audit). BR09 equipment derived
time sent to Projects as a separate record. BR10 time card balancing vs badge records requires justification.
BR12 integration status dashboard (pending / transferred / failed with drill-down).

---

## 7. Integration & data flow (Cross-cutting)

| Direction | Data | Method |
|---|---|---|
| HCM → CrewRite | Employees, persons, jobs, assignments, absences, shifts, eligibility | REST (setup) + nightly sync (volume) |
| FSCM → CrewRite | Customers, contracts, projects, tasks, NLR, PO data | REST; filtered by `Crew Time Entry Enabled` |
| CrewRite → OTL | Approved hour-based entries + Time Type + POET | OIC async, post-approval |
| CrewRite → Payroll | Non-hourly elements (per diem, bonuses) | OIC async, direct Element Entries API |
| CrewRite → Projects | POET + cost/billing (hourly + non-hourly) | OIC async, costed/uncosted configurable |
| Absence Mgmt → CrewRite | PTO, holidays, jury duty | REST, display-only (not re-sent to OTL) |

**Glossary:** POET = Project/Organization/Expenditure Type/Task · OTL = Oracle Time & Labor ·
CWK = Contingent Worker (PO-based) · DFF = Descriptive Flexfield · FBDI = File-Based Data Import ·
ORDS = Oracle REST Data Services · OIC = Oracle Integration Cloud · VBCS = Visual Builder Cloud Service ·
NVL cascade = lowest non-null value in hierarchy wins · Derived Time = equipment time from operator's hours ·
Write-In Rate = override pay rate · Lockdown = freeze timesheets for a payroll period.

---

## 8. Physical data model (schema `TIMERITE`)

Core `CR_*` tables (PKs / notable keys):

- **CR_CREWS** (`CR_CREWS_ID`, UK `CREW_CODE`; `STATUS`, `IS_DELETED`) — crew header (Module A).
- **CR_CREW_LINES** (`CR_CREW_LINES_ID`, UK `CREW_ID+LINE_NUMBER`; `LINE_TYPE` person/equip; FKs person/equip) — membership.
- **CR_PERSONS** (`CR_PERSONS_ID`, UK `PERSON_CODE+CREW_ID`, FK crew) — person resources.
- **CR_EQUIPMENT** (`CR_EQUIPMENT_ID`, UK `EQUIPMENT_CODE+CREW_ID`, FK crew) — equipment resources.
- **CR_CUSTOMERS** (`CUSTOMER_ID`, UK `CUSTOMER_NUMBER`) / **CR_CONTRACTS** (`CONTRACT_ID`, UK `CONTRACT_NUMBER`,
  FK customer) / **CR_PROJECTS** (`PROJECT_ID`, UK `PROJECT_NUMBER`, FK contract+customer).
- **Defaults (Module B):** CR_INSTALLATION_DEFAULTS (`INSTALLATION_ID`), CR_CUSTOMER_DEFAULTS (UK `CUSTOMER_ID`),
  CR_CONTRACT_DEFAULTS (UK `CONTRACT_ID`), CR_PROJECT_DEFAULTS (UK `PROJECT_ID`) — one row per level, mirroring the NVL cascade.
- **CR_ASSIGNMENTS** (`ASSIGNMENT_ID`, UK POET = `CREW_ID+PROJECT_ID+TASK_NUMBER+EXPENDITURE_TYPE`; FKs crew/customer/contract/project) — Module C.
- **CR_ASSIGNMENT_PERSONS** (`ASSIGNMENT_PERSON_ID`, UK `ASSIGNMENT_ID+PERSON_ID+EFFECTIVE_START_DATE`) — crew-explode result.
- **CR_ASSIGNMENT_EQUIPMENT** (`ASSIGNMENT_EQUIPMENT_ID`, UK `ASSIGNMENT_ID+EQUIPMENT_ID+MOB_START_DATE`; `LINKED_PERSON_ID` for derived time).
- **CR_COMPENSATION_ELEMENTS** (`COMP_ELEMENT_ID`; `PARENT_TYPE+PARENT_ID`) — dynamic comp elements at any default level.
- **CR_SHIFT_DEFINITIONS** (`SHIFT_DEF_ID`; `PARENT_TYPE+PARENT_ID`) — shift rows at any default level.

**Runtime/transactional tables** (from the ORDS services, not in the setup diagram):
CR_TIME_CARD_HEADER, CR_TIME_CARD_LINES, CR_COMBINATIONS, CR_TIMESHEET_IMPORTS, plus the dynamic-layout setup
tables CR_SETUP_PAGES / CR_SETUP_COMPONENTS / CR_SETUP_OPTIONS / CR_SETUP_PAGE_CONFIG.

`PARENT_TYPE/PARENT_ID` on comp-element and shift tables is the polymorphic link that lets one child table
attach to installation/customer/contract/project rows — the physical expression of the default hierarchy.

---

## 9. RBAC / Security (TSD v3.0)

CrewRite uses a **centralized Spring Boot Authorization Service** shared across Rite Digital PaaS apps
(Crew Rite V2, Onboard Rite, Equip Rite). Crew Rite's ORDS backend calls it via REST.

- **Layers:** (1) Identity = Entra ID / Oracle IDCS (OIDC/OAuth2). (2) Authorization = Spring Boot RBAC service +
  RBAC DB. (3) App backends (ORDS for Crew Rite) validate token + call authz on each request. (4) VBCS renders per permissions.
- **Role source of truth:** Oracle Fusion HCM **`userAccounts?expand=userAccountRoles`** API (service account).
  Roles cached per session **12h**.
- **Login flow:** VBCS→IDP→backend exchanges code→`POST /authz/session-context {application_code, person_number}`→
  service checks cache→(miss) calls HCM→maps Oracle roles→builds `{resolved_role, pages:[{page_code, access_level, actions}]}`.
- **Per-request:** `POST /authz/check-permission {session_id, page_code, action_code}`. Defense in depth: VBCS checks
  are UX only; ORDS must re-verify.
- **Fail-safe:** authz unreachable → retry once → **Employee-equivalent** role + `X-Rbac-Degraded: true` banner.
  No mapping → `IS_DEFAULT=Y` role (Employee).
- **RBAC tables:** RBAC_APPLICATIONS, RBAC_APP_ROLES (priority + is_default), RBAC_ROLE_MAPPINGS (Oracle→app,
  EXACT/PATTERN), RBAC_PAGES, RBAC_PAGE_PERMISSIONS, RBAC_ACTIONS, RBAC_ACTION_PERMISSIONS, RBAC_USER_ROLE_CACHE,
  RBAC_AUDIT_LOG — all partitioned by `APPLICATION_ID`.

**Crew Rite V2 roles:** Crew Admin, Time Keeper, Supervisor, Approver, Employee, Payroll Admin.
Multi-role priority (1 highest): Crew Admin > Approver > Time Keeper > Supervisor > Payroll Admin > Employee.

**Access matrix (FULL / READ / HIDDEN):**

| Page | Crew Admin | Time Keeper | Supervisor | Approver | Employee | Payroll Admin |
|---|---|---|---|---|---|---|
| Dashboard | FULL | FULL | FULL | FULL | FULL | READ |
| Crew Definition | FULL | FULL | READ | READ | HIDDEN | READ |
| Time Tracking Defaults | FULL | READ | READ | READ | HIDDEN | READ |
| Assignment / Schedule | FULL | FULL | READ | READ | HIDDEN | READ |
| Time Entry | FULL | FULL | READ | READ | READ | READ |
| Time Approval | FULL | HIDDEN | HIDDEN | FULL | HIDDEN | READ |
| Integration Status | FULL | READ | READ | READ | HIDDEN | READ |
| Lockdown Management | FULL | HIDDEN | HIDDEN | HIDDEN | HIDDEN | HIDDEN |
| Reports & Audit | FULL | READ | READ | READ | READ | READ |
| Admin: Role Mappings / App Config | FULL | HIDDEN | HIDDEN | HIDDEN | HIDDEN | HIDDEN |

Sample Oracle→Crew Rite mappings: `ORA_PER_WORKFORCE_ADMINISTRATOR`→Crew Admin, `XX_CR_TIMEKEEPER`→Time Keeper,
`ORA_PER_LINE_MANAGER_ABSTRACT`→Supervisor, `XX_CR_APPROVER`→Approver, `XX_CR_PAYROLL_VIEWER`→Payroll Admin,
`ORA_PER_EMPLOYEE_ABSTRACT`→Employee.

---

## 10. The VBCS application (`CrewRite_Mounika`)

- **Web app:** `webApps/vbredwoodapp` (Redwood). Single flow `main` with ~26 pages under
  `flows/main/pages/`, e.g.: `main-dashboard`, `main-crew-detail`, `main-defaults`, `main-assignments-schedule`,
  `main-assignment-detail`, `main-assignment-overrides`, `main-combinations`, `main-review-combination`,
  `main-timesheets`, `main-timesheet-tabs`, `main-timekeeper`, `main-equip-timesheet`, `main-review-timesheets-vd`,
  `main-timesheets-vd`, `main-otl-import`, `main-setup-admin`, `main-datagrid(_dev)`. Fragments: `oracle-search`, `page-header`.
- **Backends (services/catalog.json):**
  - `timeriteOrds` → `http://129.158.228.138:8080/ords/timerite` (all `CR_*` CRUD).
  - `workersApi` → `http://132.145.153.37:8082` (HCM Workers API — `/common/v1/workers`, `/common/v1/persons/summary`).
  - `oracleFusionSaaS` → `…/fscmRestApi/resources/11.13.18.05` (basic auth).
  - `oracleCrmSaaS` → `…/crmRestApi/resources/11.13.18.05`.
- **Service → endpoint highlights (all ORDS unless noted):**
  - CrewsService: `/crews/`, `/crews_v/`, `/persons/`, `/equipment/`, `/crewritemodified/persons|equipments/{crewId}`.
  - TimeCardHeaderService `/cr_time_card_header/`, TimeCardLinesService `/cr_time_card_lines/`.
  - CombinationsService `/cr_combinations/`, TimesheetImportsService `/cr_timesheet_imports/`.
  - SetupMaintenanceService `/cr_setup_pages|components|options|page_config/` (dynamic layout engine).
  - Defaults family: installation_defaults, customer_defaults, contract_defaults, project_defaults, defaults_view,
    defaults_post_new, defaults_patch_new, compensation_service, shifts_service / shift_defination, project_dff.
  - Oracle passthrough: oracle_contracts, oracle_projects, oracle_hub_organizations.
- **`db/` DDL & seeds:** `defaults_page_ddl.sql`, `create_timesheet_import_tables.sql`,
  `create_otl_system_mappings_table.sql`, `create_otl_templates_table.sql`, `create_bulk_import_procedure.sql`,
  `seed_setup_pages.sql`, `seed_review_timesheet_setup.sql`.
- **QA:** Playwright tests under `qa/`. **`.agent/`** holds a VBCS/Redwood coding knowledge base + rules
  (action chains, JET components, best practices) — useful for *how the app is built*, distinct from *what it does*.

---

## 11. Open items & migration risks (from FSD §10–11)

**Open items (owners):** verify Shimbro/shift variations (Anil), billing-title flexfield (Anil/Dinesh),
costed vs uncosted for non-hourly to Projects (Krishna/Dinesh), **build Field-Source Matrix (Bala)**,
finalize Defaults screen name (Krishna), validate equipment attrs w/ FSCM, confirm CWK pass-through merge,
EBS-on-GitHub install, FBDI bulk-defaults template (Bala/Mythili), non-hourly element term, **migration script
to split legacy crews into Module A + C (Bala/Dinesh)**, equipment-person linkage schema, per-diem field
sufficiency, equipment-module toggle level.

**Migration:** each legacy crew record → one Module A crew (project fields stripped) + one or more Module C
assignment records. **Risks:** data-split migration (High), user retraining (Med), combination migration (Med),
CWK integration merge (Med), bulk 500+ customer FBDI setup (High).

---

## 12. Source documents (read these for verbatim detail)

Paths are relative to the CrewRite project root (`c:\Users\SamJoshuvaPaulJeevan\OneDrive - RITE\CrewRite`).

- **FSD:** `AI Build/Functional Documents/CrewRite_FSD_FINAL_v2.0.docx` (may be OneDrive-locked; copy to a temp
  path before extracting). Full spec: modules A–D field tables, business rules, UX, migration, open items, glossary.
- **RBAC TSD:** `AI Build/Techinical Solution Documents/RBAC_Solution_Design_v3.0.docx` (also v1.0/v2.0, and a
  `CrewRite_RBAC_Solution_Design_*` variant in the same folder).
- **Data model:** `AI Build/Data Model/CrewRite.html` (entity/key diagram, schema `TIMERITE`).
- **Requirements & tests:** `AI Build/Functional Documents/` — `CrewRite Client_Requirement_Gathering - Cianbro.xlsx`,
  `TCC_CrewRite_Consolidated_Requirements.xlsx`, `Open Items.xlsx`, `Test Cases/CrewRite Application_Test Cases.xlsx`,
  and `Cianbro Client Docs/` (OT rules, per-diem logic/rates, shift differentials, time types, expenses).
- **Demos/decks:** `AI Build/Miron Demo/`, `AI Build/Presentations/OPA_vs_Custom_RBAC_Comparison.pptx`.
- **Live app:** `CrewRite_Mounika/` — VBCS sources (`webApps/vbredwoodapp`), ORDS service defs (`services/`),
  DDL (`db/`), VBCS coding knowledge (`.agent/`).

### How to extract a .docx to text (Windows / Python 3.11 available)
```bash
python - <<'PY'
import zipfile, re, html
def docx_text(p):
    xml = zipfile.ZipFile(p).read('word/document.xml').decode('utf-8','ignore')
    xml = re.sub(r'</w:p>','\n',xml); xml = re.sub(r'</w:tr>','\n',xml); xml = re.sub(r'</w:tc>',' | ',xml)
    return html.unescape(re.sub(r'<[^>]+>','',xml))
print(docx_text(r'PATH\TO\file.docx'))
PY
```
If a .docx is permission-denied (open in Word / OneDrive placeholder), `cp` it to a temp dir first, then extract.
For `.xlsx`, use `openpyxl` or unzip `xl/sharedStrings.xml` + `xl/worksheets/`.
