# Fusion BIP master-data extracts

Pulls bulk Fusion master data for the O2C Time cache tables. Verified end to end
against a live Fusion pod — every object name, column and literal below was
confirmed by running it, not inferred.

```
bip_client.py    SOAP client for the BIP v2 services
extracts.py      the extract definitions (SQL + column contract)
run_extract.py   CLI: check / validate / deploy / run
```

**All eleven extracts have been run against a pod.** The `verified` flag and
the VERIFIED/ALL split in `run_extract.py` remain, because they are what keeps a
newly-added extract out of the monthly MasterSync until somebody has actually
run it — an extract with a wrong object name returns zero rows while reporting
success (note 2).

## Use

Credentials come from four environment variables. **bash:**

```sh
export FUSION_BASE_URL=https://<pod>.<domain>
export FUSION_USER=<integration service account>
export FUSION_PASSWORD=<password>
export ORDS_BASE_URL=https://<host>/ords/o2c_time    # --load only
```

**PowerShell** — `export` is not a PowerShell command, and this repo is worked
on from Windows:

```powershell
$env:FUSION_BASE_URL = "https://<pod>.<domain>"
$env:FUSION_USER     = "<integration service account>"
$env:FUSION_PASSWORD = "<password>"
$env:ORDS_BASE_URL   = "https://<host>/ords/o2c_time"   # --load only
```

They last for the session only, which is the point — nothing is written to disk.

```sh

python run_extract.py --check                       # connectivity + entitlements
python run_extract.py --validate                    # compile + row counts, writes nothing
python run_extract.py --deploy                      # publish models (once per pod)
python run_extract.py --run ALL --chunked --out ./extracts
python run_extract.py --run WORKERS --effective-date 2026-08-01

# the full inbound path: extract AND load into the cache
python run_extract.py --load ALL
python run_extract.py --load WORKERS,PROJECTS
```

Every mode needs one of `--check / --deploy / --validate / --run / --load`;
running the script bare prints usage and exits, on purpose.

`--run` writes CSV. `--load` does the same extract and then POSTs it into the
`OC_TIME_*` cache. Until `--load` existed the inbound path **stopped at the
file** — the CSVs were written and nothing carried a row into the database, so
the only master data the app ever had came from `90_test_seed.sql`.

`--deploy` needs **BI Data Model Developer**. `--run` alone needs only the right
to run the models someone else deployed — that is the right split for a
production service account.

## The extracts

| Extract | INT | Target cache | Sources |
|---|---|---|---|
| `WORKERS` | INT-001 | `OC_TIME_WORKER` | `PER_ALL_PEOPLE_F`, `PER_PERSON_NAMES_F`, `PER_ALL_ASSIGNMENTS_M`, `PER_EMAIL_ADDRESSES`, `PER_PERIODS_OF_SERVICE`, `PER_ASSIGNMENT_SUPERVISORS_F`, `HR_LOCATIONS_ALL_F`, `HR_ALL_ORGANIZATION_UNITS_F_VL` |
| `PROJECTS` | INT-002 | `OC_TIME_PROJECT` | `PJF_PROJECTS_ALL_B/_TL`, `PJF_PROJECT_TYPES_TL`, `PJF_PROJECT_PARTIES`, `HZ_PARTIES` |
| `TASKS` | INT-002 | `OC_TIME_TASK` | `PJF_PROJ_ELEMENTS_B/_TL` |
| `ALLOCATIONS` | INT-003 | `OC_TIME_ALLOCATION` | `PJF_PROJECT_PARTIES`, `PJR_ASSIGNMENT` |
| `ABSENCES` | INT-006 | `OC_TIME_ABSENCE` | `ANC_PER_ABS_ENTRIES`, `ANC_PER_ABS_ENTRY_DTLS`, `ANC_ABSENCE_TYPES_VL` |
| `CALENDAR` | INT-005 | `OC_TIME_CALENDAR` | `PER_CALENDAR_EVENTS` |
| `SHIFTS` | INT-004 | `OC_TIME_CALENDAR` (SHIFT layer) | `HTS_SHIFTS_VL` |
| `EXP_TYPES` | INT-002 | reference — legal values for the config | `PJF_EXP_TYPES_B/_TL` |

The SELECT alias list **is** the CSV header **is** the upsert column list, so the
three cannot drift.

## Seven things that cost real time

Recorded because none is discoverable from the WSDL and each fails silently or
misleadingly.

**1. `uploadObject` needs `objectType='xdmz'`, not `'xdm'`.** A bare `xdm` is
rejected outright: *"Only support types - xdoz / xdmz / xssz / xmaz /
xsbzxdrz"*. The payload must be a ZIP containing `_datamodel.xdm`.

**2. An undeclared bind silently becomes NULL.** This is the dangerous one. If
the model does not declare `:P_EFFECTIVE_DATE` in `<parameters>`, BIP does not
error — it binds NULL, every date comparison fails, and the extract returns
**zero rows while reporting success**. `build_data_model()` now auto-declares
every `:BIND` it finds. Symptom: an ad-hoc run with the value inlined returns
thousands of rows, the deployed model returns none.

**3. Output is `<DATA_DS><ROWSET><ROW>`,** not the `<G_1>` group declared in the
model. Parsing `G_1` yields zero rows.

**4. Responses can be gzip-encoded — including SOAP faults.** Without
decompression a failure reads as binary noise instead of a message.

**5. Schedules live under `HTS_`, not `ZMM_`.** On a Fusion pod `ZMM_SR_*` is
Service Request scheduling (CX). HCM availability is `HTS_SHIFTS_VL`,
`HTS_WORK_PATTERNS_VL`, `HTS_SCHEDULES`. Also worth knowing:
`HTS_WORKERS_WITH_SHIFTS_V` and `HTS_SCHEDULES_DAY_SHIFT_VIEW` are delivered
views that already produce the worker × day × shift shape `V_OC_TS_DAY_SHIFT`
needs.

**6. Literal codes are short, not spelled out.** Guessing these produces zero
rows with no error:

| Column | Wrong | Right |
|---|---|---|
| `PJF_PROJ_ELEMENTS_B.OBJECT_TYPE` | `PJF_TASK` | **`PJF_TASKS`** |
| `PJF_PROJECT_PARTIES.PROJECT_PARTY_TYPE` | `PROJECT_TEAM_MEMBER` | **`IN`** (`CO` = customer) |
| `PER_CALENDAR_EVENTS.CATEGORY` | `PUBLIC_HOLIDAY` | **`PH`** |

**7. Two objects are not where you would expect.**
`HR_ALL_ORGANIZATION_UNITS_F` has no `NAME` — use `..._F_VL`.
`PJF_PROJECT_TYPES_B` has no `PROJECT_TYPE` — it is on the `_TL`.

## Why ALLOCATIONS aggregates both sides

Neither source is one row per (project, person), and joining them raw produces
duplicates that violate `UK_OC_TAL_ASSIGN`:

- `PJF_PROJECT_PARTIES` holds several rows per (project, person) from
  re-assignment over time — ~1,000 cases on the pod tested.
- `PJR_ASSIGNMENT` holds several concurrent assignments per (project, resource),
  fanning 5,043 parties out to 14,534 rows.

So `PJR` is collapsed in an inline aggregate *before* the join, and the parties
side is collapsed by the outer `GROUP BY` into one span (earliest start, latest
end). `BILLABLE_PERCENT` is **SUM**med, not MAXed — one person can hold two
concurrent assignments on a project and RULE-001 cares about the combined load.

## How --load works

Chunks of 500 rows to `POST /oc/time/admin/sync/{entity}`. The MERGE lives in
ORDS, not here — next to the constraints it has to satisfy, so this loader, OIC
and a manual repair all behave identically.

**Order is a foreign-key constraint, not a preference:**

```
WORKERS -> PROJECTS -> TASKS -> ALLOCATIONS -> ABSENCES
```

`OC_TIME_ALLOCATION` has FKs to both project and worker, `OC_TIME_TASK` to
project. Load allocations first and every row fails. `--load ALL` walks this
order regardless of the order you name things in.

**One job row per entity, not per chunk.** The first chunk opens an
`OC_TIME_SYNC_JOB` and the response returns its id; later chunks pass it back.
So 5,976 workers is one line on the Sync Status page, not twelve.

**A bad row does not cost the batch.** Failures go to `OC_TIME_SYNC_FAILED` with
the reason, and the run continues — one worker with a missing manager must not
lose the other 5,975. `POST sync/retry/{failedId}` re-drives one once the cause
is fixed.

**What the sync deliberately does not overwrite:**

| Column | Why |
|---|---|
| `OC_TIME_WORKER.APP_ROLE` | this app's entitlement, not HCM's — syncing it would demote every manager |
| `OC_TIME_PROJECT.REVENUE_MODEL`, `LEAVE_LOSS_FLAG` | commercial attributes this module owns |
| `OC_TIME_ALLOCATION.BILLING_STATUS` | our own classification |

Workers who disappear from an extract are **not** deleted — `STATUS` carries
`Terminated` for that, and a delete would break FKs from existing timesheets.

## POET — settled 02-Aug-2026

An OTL time card needs Project / Organization / Expenditure type / Task.

**Organization — from the worker.** `WORKERS` returns `EXPENDITURE_ORG` from
`PER_ALL_ASSIGNMENTS_M.ORGANIZATION_ID` through `HR_ALL_ORGANIZATION_UNITS_F_VL`
— the same table already joined for `LEGAL_EMPLOYER`, on a different key.

They are **not** interchangeable, and the pod proves it: 5,988 workers all have
a legal employer, but only 4,759 have an expenditure organization, across 686
distinct organizations. The legal employer is who employs the person; the
expenditure organization is the costing unit the work books to. The 1,229 with
neither are a real data gap, and `V_OC_TIME_POET_READINESS` is what surfaces it.

`OC_TIME_ALLOCATION.EXPENDITURE_ORG` is a per-project override, normally null,
so the worker's own value applies by default.

**Expenditure type — from configuration, not from the task.** This was the open
question and the answer was not the expected one:

- `PJF_EXP_TYPES_B` exists with 262 active types (30 of them `UOM = HOURS`), but
  the column is `EXPENDITURE_CATEGORY_ID`, not `EXPENDITURE_CATEGORY`.
- **`PJF_TXN_CONTROLS` does not exist on this pod.** The only object matching
  `%TXN_CONTROL%` is `PJC_TXN_CONTROLS_STAGE`, a staging table.

So there are no live transaction controls to read a per-task expenditure type
from, and the `TASK_EXP_TYPES` extract was removed rather than left failing.
The value lives in `OC_TIME_CONFIG.defaultExpenditureType`, seeded to
`Regular Labor`.

Run `EXP_TYPES` before changing that config: several types named `...Labor` are
`DOLLARS` (Craft Labor Straight Time, Consultant Labor…) and would be wrong for
hours. The UOM is the constraint that matters, not the name.

## Two joins that were wrong, and what they are now

Both were written from the standard Fusion model and both were wrong. Recorded
because the corrections are not guessable.

**`PROJECTS.PROJECT_MANAGER_ID`.** The role table is `PJT_PROJECT_ROLES_VL` —
prefix **`PJT_`**, not `PJF_` — and its column is `NAME`, not
`PROJECT_ROLE_NAME`. Matched on `= 'Project Manager'` exactly, because
`LIKE '%PROJECT MANAGER%'` also catches *Associate Project Manager*, a different
person with different authority.

Written as a **scalar subquery, not a join**: a project can carry the same role
more than once over time, and a join would emit one project row per party,
silently duplicating projects into a MERGE keyed on project number.

187 of 424 projects resolve to a manager. RULE-015 routes every approval through
this, so the 237 without one have no approver — visible, not silent.

**`PROJECTS.TIME_ENTRY_ENABLED`.** Fusion does have an answer for this after
all: `PJF_PROJECT_PARTIES.PJS_TRACK_TIME`. Using it selects **48** projects out
of 424. The earlier guess — "has any internal party" — would have let 327
through, which is most of the way back to the problem §2.4 describes.

## Scheduling

`--run ALL` is the monthly **MasterSync**. It must finish **before**
`MonthlyPopulation`, which builds `OC_TS_WEEK` / `OC_TS_ENTRY` from the cache —
run it first and the whole month is built from last month's allocations.

Daily deltas are a REST job, not this. BIP is read-only, so every write-back
(INT-007 OTL push, INT-009 `statusChangeRequests`) stays REST.

Load the CSVs with `SOURCE_METHOD='BIP'` and the `SYNC_JOB_RUN_ID` of the run,
so a suspect row can be traced back to the job that wrote it.

## Notes

- Credentials come from the environment only; never commit them, and never let
  them reach a browser (NFR-005).
- `extracts/` is git-ignored — the output contains real names and email
  addresses.
- `--insecure` skips TLS verification. Lower environments only.
- Verified counts on the reference pod as of 2026-08-01: WORKERS 5,976 ·
  PROJECTS 423 · TASKS 10,534 · ALLOCATIONS 1,595 · CALENDAR 150 · SHIFTS 64.
  ABSENCES returns 1 because that pod's absence data stops at 2025-11-26 — not a
  defect; run with an earlier `--effective-date` to see it populate.
