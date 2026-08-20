--==============================================================
-- time/87_cover_billing_on_a_defaulted_week.sql
-- O2C Timesheet Module — the hours were there; the query could not see them
--
-- db/86 gave the leave-loss billing a manager's guard, so a defaulted week
-- stopped being refused. It then refused for a second reason:
--
--   llc 4: The covering colleague has no non-billable hours on this project
--          that day, so there is nothing to convert.
--
-- Kishore Krovvidi has exactly that. Measured over ORDS:
--
--   entry 192346  07-Aug  555 / 01.01.111 Offshore
--                 entry_type = 'Default'   source = 'Job'
--                 billable_type = 'Non-billable'   hours = 8
--
-- oc_time_cover_billing filters e.entry_type = 'Actual' in all four places it
-- touches an entry. run_weekly_defaulting RETAGS the prepopulated row to
-- ENTRY_TYPE = 'Default' when it fills a week in on the employee's behalf --
-- which is what makes a still-Default cell a trustworthy "nobody touched this"
-- baseline (commit e2ec95e). So on a defaulted week the source lookup matches
-- nothing and the procedure honestly reports that it found nothing.
--
-- SAME SHAPE AS THE GUARD IT JUST REPLACED. db/84 was written against a normal
-- week in both cases: assert_editable assumed the caller was the employee, and
-- entry_type='Actual' assumed the week had been submitted. Unblocking the first
-- exposed the second, because the defaulted week was never reachable before.
--
-- ── AND THE THIRD PLACE IT WOULD HAVE GONE WRONG ─────────────────────────
--
-- Widening the filter alone is not enough, and getting this wrong is expensive.
-- UK_OC_TSE_CELL includes ENTRY_TYPE, so the database permits an 'Actual' row
-- BESIDE a 'Default' one on the same project/task/day. Had the source lookup
-- simply accepted Default, the decrement (WHERE entry_type='Actual') would have
-- matched nothing while the MERGE inserted a new Actual row -- Kishore's day
-- would have held 8 defaulted + 2 billable = 10 hours against a standard of 8,
-- and validate_day only refuses past 24.
--
-- That is precisely the double count e2ec95e found in save_entry on this same
-- table, and the fix is the one it used: PROMOTE the row to 'Actual' in a
-- SEPARATE UPDATE first, then split it. Separate because a column in a MERGE's
-- ON clause cannot be updated -- ORA-38104.
--
-- Promotion is not a workaround, it is the truth of what happened: the row
-- stops being what the job assumed and becomes what a person decided. The
-- remaining Default cells stay a trustworthy baseline precisely because this
-- one no longer is.
--
-- THE COLLISION CASE IS HANDLED RATHER THAN ASSUMED AWAY. If an 'Actual' row
-- already exists on that exact cell -- entirely possible at zero hours -- then
-- promoting would raise ORA-00001 on UK_OC_TSE_CELL. The defaulted hours are
-- folded into the Actual row instead and the Default row is left at zero. Not
-- deleted: OC_TS_AUDIT rows point at it, and db/78 is the record of how much
-- work removing an audited entry is.
--
-- WHAT THIS DOES NOT TOUCH. The week stays SUBMISSION_STATUS = 'Defaulted' with
-- its salary hold intact, because the employee still did not submit and that is
-- a separate fact from a manager recording who covered somebody's leave. No
-- event is fired, so DEFAULTED_BY is not cleared -- which also sidesteps the
-- open 'DailyChange on a Defaulted week clears DEFAULTED_BY' issue rather than
-- widening it.
--
-- ── AND A FOURTH THING, FOUND BY RUNNING IT ──────────────────────────────
--
-- Two billability columns disagree, and this procedure was reading the wrong
-- one. For entry 192346:
--
--   OC_TIME_TASK.BILLABLE_TYPE    Billable
--   OC_TS_ENTRY.BILLABLE_TYPE     Non-billable
--   OC_TS_ENTRY.UNBILLED_REASON   'Non-billable Assignment'
--
-- TRG_OC_TSE_DERIVE as db/23 rewrote it lets a LINE REASON beat the task: the
-- hours are on a billable WBS task and are non-billable purely because
-- Kishore's allocation to 555 is Unbilled. So MIN(billable task) picks
-- 01.01.111 -- the task the hours are ALREADY on -- and the MERGE would have
-- matched the source row: minus 2 then plus 2, day unchanged, reason still
-- there, nothing billable created, COVER_HOURS_BILLED stamped 2 anyway.
--
-- "Move the hours to a billable task" is therefore the wrong mechanism on this
-- project. It refuses with an explanation instead; picking a different WBS task
-- would misstate where the work happened, and clearing the reason on the whole
-- line would bill all 8 hours when 2 are owed. Which of those is right is a
-- decision, and it is recorded as open rather than guessed at.
--
-- Idempotent. Supersedes db/86 [2/5]. Depends on: time/05, 08, 09, 84, 85, 86.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views
   WHERE view_name = 'V_OC_TS_LLC_ANNEXURE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_CTX' AND object_type = 'PACKAGE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'db/85 has not been run here: OC_TIME_CTX is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] What the covers actually have on the day
PROMPT ============================================================

-- Printed BEFORE the change, so the retry in [3/4] can be read against it.
COLUMN cover FORMAT A22
COLUMN task  FORMAT A26
COLUMN line_reason FORMAT A24
SELECT l.llc_id,
       TO_CHAR(l.absence_date,'DD-Mon') AS on_date,
       cw.employee_name AS cover,
       NVL(t.task_code || ' ' || t.task_name, '(no line that day)') AS task,
       -- BOTH columns, because they disagree and the disagreement is the point.
       -- Showing only the task's answer is what made 01.01.111 read as Billable
       -- when the line on it is Non-billable.
       NVL(t.billable_type,'-')   AS task_bill,
       NVL(e.billable_type,'-')   AS line_bill,
       NVL(e.unbilled_reason,'-') AS line_reason,
       NVL(e.entry_type,'-')      AS entry_type,
       NVL(TO_CHAR(e.hours),'-')  AS hours
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id
  LEFT JOIN oc_ts_week w ON w.employee_id = l.cover_employee_id
                        AND l.absence_date BETWEEN w.week_start AND w.week_end
  LEFT JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
                         AND e.entry_date = l.absence_date
                         AND e.project_id = l.project_id
                         AND e.is_leave   = 'N'
  LEFT JOIN oc_time_task t ON t.task_id = e.task_id
 WHERE l.cover_employee_id IS NOT NULL
 ORDER BY l.llc_id, t.task_code;

PROMPT
PROMPT ENTRY_TYPE 'Default' is a row run_weekly_defaulting wrote on the
PROMPT employee's behalf. Those hours are real and spendable; only the query
PROMPT looking for them was too narrow.
PROMPT
PROMPT Where TASK_BILL and LINE_BILL differ, LINE_BILL is the answer and
PROMPT LINE_REASON says why. That is the column every total downstream uses.

PROMPT ============================================================
PROMPT [2/4] OC_TIME_COVER_BILLING - retired, see db/88
PROMPT ============================================================

-- THIS SECTION DELIBERATELY DOES NOTHING NOW.
--
-- Everything it fixed was real -- the entry_type='Default' blindness, the
-- promotion, the UK_OC_TSE_CELL collision, the same-task refusal -- and none of
-- it was a leave-loss problem. All four were consequences of db/84's premise
-- that covering somebody makes the COVER's hours billable, and on 20-Aug the
-- functional owner retracted it: "those hours need to go as billed for those
-- employee - this is wrong". A rule that touches no entries cannot hit any of
-- those four.
--
-- Running this after db/88 would restore an hour-moving procedure whose whole
-- premise has been withdrawn, and it would do so quietly.
--
-- The live definition is db/88_coverage_is_a_statement.sql [5/7], where
-- oc_time_cover_billing raises -20033 and oc_time_approve_cover records the
-- fact without moving anything.

BEGIN
  DBMS_OUTPUT.PUT_LINE('  Left alone. The live definition is db/88 [5/7].');
END;
/


PROMPT ============================================================
PROMPT [3-4/4] Superseded by db/88 - nothing to do
PROMPT ============================================================

-- The remaining sections of this file retried oc_time_cover_billing and then
-- reported COVER_HOURS_BILLED. Neither exists in that form any more: the
-- procedure raises -20033 and the annexure has no hours column, because
-- coverage moves no hours. Left inert so the file stays re-runnable, which is
-- the convention every script here follows.
--
-- What this file's earlier sections found is still true and still worth
-- reading; it is only the actions that were built on a retracted premise.

BEGIN
  DBMS_OUTPUT.PUT_LINE('  Superseded by db/88. Nothing to do.');
END;
/
