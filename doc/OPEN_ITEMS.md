# O2C Timesheet — open items

As at 11-Aug-2026.

---

## 1. On hold — decided to defer

| # | Item | Note |
|---|---|---|
| H1 | VBCS unbilled-reason dropdown | DB side is done (`23_unbilled_reason_per_line.sql`). Needs the page, an LOV endpoint and the save chain. **Downgraded 12-Aug:** PRJ-ORG was retired (`status='Closed'`) and non-billable time now books to the *real* project against a COMMON task — Onboarding, Training, Travel, Client Holiday, which `V_OC_TS_TASK_LOV` already appends to every active project. So there is a working route today and this is no longer blocking; it adds a free-text reason on any line, which is finer-grained than a fixed task list. |
| H2 | Orphan allocations | Employee leaves a project and joins nothing. The change stays `Pending` in `OC_TIME_SYNC_CHANGE` with a note. Hours are wrong but there is nowhere to move them. |
| H3 | Employee cut-off for adjustments | `oc_time_default_adjustments` reads `DELIVERY_CUTOFF`. If it should be `PAYROLL_CUTOFF`, one line. |
| H4 | Future prepopulated days | Retro reallocation adjusts up to today. Days already populated beyond it still carry the old project and want re-populating, not adjusting. |
| H5 | Period control from the O2C main app | Not started. |
| ~~H8~~ | ~~**Task column becomes an LOV on existing lines**~~ **BUILT 13-Aug** (`26_change_line_task.sql` + change-task dialog). Option A taken: the task name is a button, opening a dialog with that project's LOV. Inline `oj-select-single` was rejected — it needs a per-row DataProvider, which cannot be built inside an `oj-bind-for-each`, and a plain `<select>` hits the same parser trap as the day strip. | Raised 12-Aug. Today TASK (WBS) is static text; an employee with several tasks on one project cannot move hours between them without deleting the line and re-adding it. Make it an `oj-select-single` per row, fed by the same `getTaskLov` the Add-line dialog uses, filtered to the row's own project. **Leave lines stay read-only** — RULE-008 makes leave system-owned, and it is already excluded from the LOV by `SELECTABLE_FLAG='N'`, so the guard is `isLeave !== 'Y'` on the editor, not a change to the LOV. Same rule already governs whether the day cells accept input. |
| ~~H8a~~ | ~~**Decision: what happens when the chosen task already has a line?**~~ **REFUSE, decided 12-Aug.** | `UK_OC_TSE_CELL` is `(ts_week_id, project_id, task_id, entry_date, entry_type)`. Changing a line's task rewrites part of that key, so if the employee picks a task that already exists on the same project the update collides. Three options: **merge** the two lines by summing hours per day; **refuse** with "that task is already on this timesheet"; or **swap** the two lines' tasks. Merge is friendliest and silently changes numbers; refuse is safest and most annoying. Not a coding question — decide it, then it is a small build. |
| H7 | **A leave cancelled in Fusion is never removed** | `syncAbsence` MERGEs — inserts and updates, never deletes — so a cancelled leave keeps its cached row and keeps appearing on the timesheet. Worse, cancelling *every* leave in the window returns an empty payload and the chain returns early without calling `syncAbsence` or `runPopulation` at all, so nothing is touched. **Fix:** the live read is authoritative for the window it asked about, so reconcile instead of merge — delete cached rows inside `from..to` that are absent from the payload, merge the rest, repopulate; and run the reconcile on the empty payload rather than returning early. Scope strictly to the requested window so it can never touch a date the read did not cover. Confirmed 12-Aug; the chain already documents the gap in its own comment. |
| H6 | OIC sync runs are invisible on the admin screen | `v_oc_time_sync_status` reads `oc_time_sync_job`; `OC_TIME_LOAD_XML` writes only `oc_time_sync_failed` and never inserts a job row, so a scheduled daily sync appears nowhere on the Sync Status page. The bookmark state in `OC_TIME_SYNC_CONFIG` is not surfaced either. Fix is to have the loader write a job row — same table, so the existing page picks it up with no UI change. **Matters more now the sync runs unattended on a schedule:** until then, the only view of it is OIC monitoring or a direct query. |

---

## 2. Open — needs a decision

| # | Item | Why it matters |
|---|---|---|
| O1 | **ABSENCES is not synced** | Disabled by decision 09-Aug (read live per person). But `populate_month` reads `OC_TIME_ABSENCE` for leave rows, and only `90_test_seed` fills it. In production, leave prepopulation produces nothing. Enable the feed, or change how leave reaches the timesheet. |
| O15 | **Every calendar date is duplicated** | 42 working days counted for an August with 21: two `CORPORATE` rows per date, same values, one hand-seeded and one synced. Two rows at the same `LAYER` and `PRECEDENCE` make the precedence resolution ambiguous and nothing in the model forbids it. `93_remove_test_data.sql` deliberately does **not** delete on `SOURCE_METHOD` for this reason — a calendar that comes back short populates nothing and shows an empty timesheet rather than an error. Fix on its own terms: decide the natural key, dedupe, then constrain. |
| O2 | Deletions are undetectable | An incremental delta returns changed rows; a deleted row returns nothing. Accepted on the basis that allocations are end-dated, not deleted — worth confirming that is always the practice. |
| O3 | Adjustment generation rules | Capture is live and queues everything `Pending`. Nothing drains it until the flag/scenario workbook comes back. |
| O4 | A task that moves project in Fusion | Now errors instead of silently duplicating. Neither is correct handling. |
| O5 | `FUSION_ASSIGNMENT_ID` unpopulated | The extract collapses concurrent assignments on purpose, so there is no single id to store. Needed for the OTL push. |
| O6 | `alloc_pct` could exceed 100 | `SUM(billable_percent)` over concurrent assignments. Zero occurrences on this pod, so theoretical. |
| O7 | Duplicate keys on two feeds | WORK_PATTERNS 26, WORK_SCHEDULES 2. Both disabled with no target table — would hit ORA-30926 the day either is enabled. |
| O8 | No unique key on `OC_TS_SALARY_HOLD_DAY` | `(employee_id, work_date)` is not constrained. A `NOT EXISTS` in the job is the only thing preventing duplicates. |
| O9 | No "became non-billable" report | `OC_TS_AUDIT` records old/new billable type. Nothing surfaces it, and finance will ask the first month revenue comes in light. |
| O10 | Unbilled reason after a month is confirmed | Should route through `run_accrual_top_up`, not edit a confirmed line. Check `assert_editable` blocks it. |
| O11 | `approve_week` cross-project leak | Raised earlier, not fixed. |
| O12 | One Reversal per cell | `UK_OC_TSE_CELL` allows only one. A second correction to the same day/project/task cannot be recorded. |
| O13 | `SOURCE_PERIOD` / `POST_PERIOD` not on the accrual interface | The consumer cannot tell which month a correction belongs to. |
| O14 | RI9001 has no approver | Top of the hierarchy. Needs a project-level alternate approver policy. |

---

## 3. Integration — remaining build

| # | Item |
|---|---|
| I1 | ~~Monthly orchestrator~~ **BUILT AND PROVEN 12-Aug** — `O2C_TIME_SYNC_MONTHLY` reads `V_OC_TIME_SYNC_MONTHLY` via the DBaaS adapter, loops 6 feeds through the *same* INT 002, then calls `POPULATE_MONTH(21, NULL, 'OIC_MONTHLY')`. Run: 6 iterations, ~34s total (14.6s feeds + 18.4s populate), SEP-2026 built with 1,070 weeks for 214 people. The 4-minute timeout was never in play — measure before designing round it. |
| I1a | **Monthly: null guard on `targetPeriodId`.** Switch after the config read, fault if empty. Passes today (id 21) and fails the first month nobody creates the next period — surfacing as an adapter error on a null primary-key column rather than a readable message. |
| I1b | **Monthly: rename the `Daily…` nodes.** `Map`/`Invoke DailySyncStatusUpdate` are inherited names from the clone and now call `POPULATE_MONTH`. A node called `Daily…` in the monthly integration will mislead somebody. |
| I1c | **Monthly: set the schedule.** `FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=25;BYHOUR=2;BYMINUTE=0;BYSECOND=0;` — trailing semicolon required, timezone Calcutta. Must run *before* the month it builds. |
| I1d | **233 allocations have no chargeable WBS task** (`NO_WBS_TASK`, all 233 failures of the first monthly run). `populate_month` has nowhere to book hours, so it skips and logs. RULE-010: only a chargeable task reaches the LOV, and `NVL(chargeable_flag,'N')` turns a Fusion null into `N`. Almost certainly the PPM setup gap already on the plan — confirm against `oc_time_task.chargeable_flag`. |
| I1e | **TASKS pulled 523 rows where 5,478 are in force.** Unexplained. The TASKS extract has no effective-date filter (`{ED}` is declared for parameter parity only), so the as-of date does *not* account for it — an earlier claim of mine that was wrong. Not the cause of I1d, since MERGE never deletes and the cache still holds all 5,478. |
| I2 | BIP credentials into a Lookup. Currently literals in the mapper, so they are in every export. |
| I3 | Fault handling in INT 001. One failed feed aborts the run; it should log and continue to the next. |
| I4 | Tracing → Production once stable. |
| I5 | Schedule the daily run twice a day. Set the timezone explicitly — the instance is `us-ashburn`. |

**Done and proven:** daily orchestrator end to end — config → 6 feeds in run order → BIP with both parameters → base64 decode → loader → merge → before-image capture → bookmark → `populate_daily`. Tested on full volumes and on an empty delta.

**After any change to `integration/bip/extracts.py`:** run `python run_extract.py --deploy <NAMES>`. OIC executes whatever is in the catalog; it does not redeploy.

---

## 4. Test data preparation

### To reset a month for a walkthrough

```
db/90_demo_reset.sql        clears ONE period and repopulates it
```

Then set the week states:

```sql
DECLARE v_job NUMBER;
BEGIN
  v_job := oc_time_pkg.run_weekly_defaulting(
             oc_time_pkg.get_open_period_id, SYSDATE, 'DEMO_SETUP');
END;
/
```

Gives: current week editable, earlier weeks `Defaulted`, future weeks locked.

It refuses any period already confirmed to accrual. That is deliberate — a confirmed month has had its hours handed to finance, and production corrects **forward** through the Reversal/Adjustment chain, never by deleting.

### To close a month

```
db/92_month_end_close.sql
```

Defaulting → salary stopping → confirm per project → close. Read step **[5]** before going on: it must say `0 refused`. The close itself is commented out at the bottom and run by hand, because closing gates editing and a refused project cannot then be fixed by approving.

### Before production

```
db/91_production_readiness.sql     read-only survey
```

Three kinds of row, and only one of them should go:

- **FUSION** — workers, projects, tasks, allocations, calendar. Synced, carries a `FUSION_*` id.
- **DESIGN** — the COMMON tasks, status and flag dictionaries, `OC_TIME_CONFIG`, `OC_TIME_PERIOD` and its cut-offs. Fusion has no source for any of it. **Keep.**
- **TEST** — everything `90_test_seed.sql` created. **Remove**, and never run that file again.

They are told apart by the Fusion id: a hand-seeded row has none.

Also before go-live: `OC_TIME_PERIOD` covers only this month and next, the cut-offs carry demo dates, and RULE-017 is relaxed so two months are Open. Configuration, not cleanup.

`PRJ-ORG` is no longer seeded. Removing the existing row is a hand-run `DELETE` at the end of `23_unbilled_reason_per_line.sql`, once nothing points at it.

### Logins

`OC_TIME_USER` is the module's own store and stays local — this is the "everything except the login comes from Fusion" part. What must not survive is the demo password: `91` counts users still on `Rite@123`, and that number has to be zero.

---

## 5. Security

`Rite@123` appears in 6 tracked files and in git history. It is both the app's demo login **and** the Fusion pod password for `sampaul.jeevan@rite.digital`.

**Rotate it.** Removing it from the files does not clear the history, and the repo now has a second remote.

`.env` and `.mcp.json` are untracked and have never been committed. Keep it that way.
