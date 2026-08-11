# O2C Timesheet — open items

As at 11-Aug-2026.

---

## 1. On hold — decided to defer

| # | Item | Note |
|---|---|---|
| H1 | VBCS unbilled-reason dropdown | DB side is done (`23_unbilled_reason_per_line.sql`). Needs the page, an LOV endpoint and the save chain. Blocked while the VB Studio workspace is down. |
| H2 | Orphan allocations | Employee leaves a project and joins nothing. The change stays `Pending` in `OC_TIME_SYNC_CHANGE` with a note. Hours are wrong but there is nowhere to move them. |
| H3 | Employee cut-off for adjustments | `oc_time_default_adjustments` reads `DELIVERY_CUTOFF`. If it should be `PAYROLL_CUTOFF`, one line. |
| H4 | Future prepopulated days | Retro reallocation adjusts up to today. Days already populated beyond it still carry the old project and want re-populating, not adjusting. |
| H5 | Period control from the O2C main app | Not started. |

---

## 2. Open — needs a decision

| # | Item | Why it matters |
|---|---|---|
| O1 | **ABSENCES is not synced** | Disabled by decision 09-Aug (read live per person). But `populate_month` reads `OC_TIME_ABSENCE` for leave rows, and only `90_test_seed` fills it. In production, leave prepopulation produces nothing. Enable the feed, or change how leave reaches the timesheet. |
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
| I1 | **Monthly orchestrator.** Same shape as the daily one: `v_oc_time_sync_monthly`, then `POPULATE_MONTH` with `targetPeriodId`. Watch OIC's 4-minute adapter timeout — a whole-month populate is the call most likely to exceed it. |
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
