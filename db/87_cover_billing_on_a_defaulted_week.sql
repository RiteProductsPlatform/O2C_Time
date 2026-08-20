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
PROMPT [2/4] OC_TIME_COVER_BILLING sees a defaulted week's hours
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_cover_billing(
  p_llc_id  IN  NUMBER,
  p_apply   IN  VARCHAR2,          -- 'Y' bill the cover, 'N' put it back
  p_actor   IN  VARCHAR2 DEFAULT 'VBCS_USER',
  o_hours   OUT NUMBER,
  o_message OUT VARCHAR2)
IS
  v_project   NUMBER;
  v_period    NUMBER;
  v_date      DATE;
  v_absent    VARCHAR2(50);
  v_cover     VARCHAR2(50);
  v_already   NUMBER;
  v_loss      NUMBER;
  v_week      NUMBER;
  v_wstatus   VARCHAR2(40);
  v_pstatus   VARCHAR2(20);
  v_confirmed NUMBER;
  v_src_entry NUMBER;
  v_src_type  VARCHAR2(20);
  v_nb_task   NUMBER;
  v_bill_task NUMBER;
  v_avail     NUMBER;
  v_dup       NUMBER;
BEGIN
  o_hours := 0;

  SELECT project_id, period_id, absence_date, absent_employee_id,
         cover_employee_id, NVL(cover_hours_billed, 0)
    INTO v_project, v_period, v_date, v_absent, v_cover, v_already
    FROM oc_ts_leave_loss_cover WHERE llc_id = p_llc_id;

  IF v_cover IS NULL THEN
    o_message := 'No covering colleague assigned yet.';
    RETURN;
  END IF;

  v_week := oc_time_pkg.ensure_week(v_cover, v_date, p_actor);

  -- ── THE MANAGER'S WINDOW (db/86) ───────────────────────────
  -- NOT assert_editable: that is the EMPLOYEE's gate and its LOCKED_FLAG branch
  -- refuses a defaulted week with the words "Only a manager can edit a
  -- defaulted timesheet" -- which is precisely who is calling.
  SELECT week_status INTO v_wstatus FROM oc_ts_week WHERE ts_week_id = v_week;

  IF v_wstatus IN ('Approved','Overridden and approved','Closed') THEN
    RAISE_APPLICATION_ERROR(-20007,
      'The covering colleague''s week has already been approved, so their '
      || 'hours cannot be moved. Revoke the approval first, or raise this as '
      || 'an adjustment.');
  END IF;

  SELECT status INTO v_pstatus FROM oc_time_period WHERE period_id = v_period;

  IF v_pstatus <> 'Open' THEN
    RAISE_APPLICATION_ERROR(-20007,
      'This month is ' || v_pstatus || ' and its hours can no longer be moved.');
  END IF;

  SELECT COUNT(*) INTO v_confirmed FROM oc_ts_month_confirm
   WHERE project_id = v_project AND period_id = v_period;

  IF v_confirmed > 0 THEN
    RAISE_APPLICATION_ERROR(-20007,
      'This month has already been confirmed to accrual for this project. '
      || 'These hours were sent as non-billable and changing them now would '
      || 'put the timesheet out of step with what was sent -- raise an '
      || 'adjustment instead.');
  END IF;

  -- ── PUT IT BACK ────────────────────────────────────────────
  -- Both rows are 'Actual' by the time anything has been billed: the source was
  -- promoted on the way in. So this path needs no Default handling.
  IF UPPER(p_apply) <> 'Y' THEN
    IF v_already <= 0 THEN
      o_message := 'Nothing had been billed for this coverage.';
      RETURN;
    END IF;

    -- e.billable_type on both, for the reason given at the source lookup below.
    SELECT MIN(e.task_id) INTO v_bill_task
      FROM oc_ts_entry e
     WHERE e.ts_week_id = v_week AND e.entry_date = v_date
       AND e.project_id = v_project AND e.is_leave = 'N'
       AND e.entry_type = 'Actual'
       AND e.billable_type = 'Billable' AND e.hours >= v_already;

    SELECT MIN(e.task_id) INTO v_nb_task
      FROM oc_ts_entry e
     WHERE e.ts_week_id = v_week AND e.entry_date = v_date
       AND e.project_id = v_project AND e.is_leave = 'N'
       AND e.entry_type = 'Actual'
       AND e.billable_type = 'Non-billable';

    IF v_bill_task IS NULL OR v_nb_task IS NULL THEN
      o_message := 'The billed hours are no longer where they were put; '
                || 'nothing moved back. Check the day by hand.';
      RETURN;
    END IF;

    UPDATE oc_ts_entry SET hours = hours - v_already, updated_by = p_actor
     WHERE ts_week_id = v_week AND entry_date = v_date
       AND project_id = v_project AND task_id = v_bill_task
       AND entry_type = 'Actual';

    UPDATE oc_ts_entry SET hours = hours + v_already, updated_by = p_actor
     WHERE ts_week_id = v_week AND entry_date = v_date
       AND project_id = v_project AND task_id = v_nb_task
       AND entry_type = 'Actual';

    UPDATE oc_ts_leave_loss_cover
       SET cover_hours_billed = NULL, updated_by = p_actor
     WHERE llc_id = p_llc_id;

    o_hours   := v_already;
    o_message := v_already || ' hour(s) returned to non-billable.';
    RETURN;
  END IF;

  -- ── BILL IT ────────────────────────────────────────────────
  IF v_already > 0 THEN
    o_message := 'Already billed ' || v_already || ' hour(s) for this coverage.';
    RETURN;
  END IF;

  -- READ, DO NOT RECOMPUTE (db/85). The screen shows LOSS_HOURS and this moves
  -- LOSS_HOURS, so the manager cannot approve one number and get another.
  SELECT loss_hours INTO v_loss FROM v_oc_ts_llc WHERE llc_id = p_llc_id;

  IF NVL(v_loss,0) <= 0 THEN
    o_message := 'The absent colleague has no allocated hours on this project '
              || 'for that day, so there is no loss to recover.';
    RETURN;
  END IF;

  -- ── WHERE THE HOURS COME FROM ──────────────────────────────
  -- 'Default' AS WELL AS 'Actual'. run_weekly_defaulting retags a prepopulated
  -- row to Default when it fills the week in for the employee, and those hours
  -- are just as real -- llc 4 refused for want of 8 non-billable hours that
  -- were sitting right there under the other tag.
  --
  -- One row picked explicitly rather than MIN(task_id) over a set, because the
  -- promotion below has to name the row it is promoting. Actual first: if the
  -- person has typed something, that is the row to spend.
  BEGIN
    -- e.billable_type, NOT t.billable_type. TRG_OC_TSE_DERIVE (db/23) lets a
    -- LINE REASON beat the task, so the two disagree whenever the person's
    -- assignment is non-billable on a billable WBS task -- which is Kishore on
    -- 555 exactly. Reading the task's answer made this find nothing and report
    -- "no non-billable hours" about 8 hours that are non-billable.
    --
    -- The entry's column is the authority everywhere else too: it is what
    -- V_OC_TS_MONTH_SUMMARY totals and what confirm_month sends to accrual. A
    -- rule that reads the task instead is reading an input, not the answer.
    SELECT ts_entry_id, task_id, entry_type, hours
      INTO v_src_entry, v_nb_task, v_src_type, v_avail
      FROM (SELECT e.ts_entry_id, e.task_id, e.entry_type, e.hours
              FROM oc_ts_entry e
             WHERE e.ts_week_id = v_week AND e.entry_date = v_date
               AND e.project_id = v_project AND e.is_leave = 'N'
               AND e.entry_type IN ('Actual','Default')
               AND e.billable_type = 'Non-billable'
               AND e.hours > 0
             ORDER BY CASE e.entry_type WHEN 'Actual' THEN 0 ELSE 1 END,
                      e.hours DESC, e.task_id)
     WHERE ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    o_message := 'The covering colleague has no non-billable hours on this '
              || 'project that day, so there is nothing to convert.';
    RETURN;
  END;

  -- Never move more than they actually have, which is also why the annexure
  -- bills COVER_HOURS_BILLED and not LOSS_HOURS -- they are allowed to differ.
  v_loss := LEAST(v_loss, v_avail);
  IF v_loss <= 0 THEN
    o_message := 'No non-billable hours available to convert.';
    RETURN;
  END IF;

  SELECT MIN(task_id) INTO v_bill_task
    FROM (SELECT task_id FROM v_oc_ts_task_lov
           WHERE project_id = v_project AND billable_type = 'Billable'
           ORDER BY sort_order, task_code, task_id)
   WHERE ROWNUM = 1;

  IF v_bill_task IS NULL THEN
    o_message := 'This project has no billable task to move the hours onto.';
    RETURN;
  END IF;

  -- ── REFUSE RATHER THAN QUIETLY ACHIEVE NOTHING ─────────────
  -- Measured on 555, 20-Aug: the source line and the chosen billable task are
  -- THE SAME TASK. 01.01.111 Offshore is Billable at TASK level and the entry
  -- is Non-billable only because UNBILLED_REASON = 'Non-billable Assignment'
  -- sits on the line -- TRG_OC_TSE_DERIVE (db/23) lets a line reason beat the
  -- task, so OC_TS_ENTRY.BILLABLE_TYPE and OC_TIME_TASK.BILLABLE_TYPE disagree
  -- and this procedure was reading the task's.
  --
  -- Left unguarded the MERGE matches the source row itself: minus v_loss then
  -- plus v_loss, day unchanged, reason still on the line, nothing billable
  -- created -- and COVER_HOURS_BILLED stamped anyway. The annexure would then
  -- invoice hours that never became billable, which is worse than any refusal.
  --
  -- Moving the hours cannot fix this, because what makes them non-billable is
  -- the reason and not the task. The mechanism has to change, and that is a
  -- decision about the WBS and the accrual, not something to infer here.
  IF v_bill_task = v_nb_task THEN
    o_message := 'These hours are already on a billable task ('
      || (SELECT task_code FROM oc_time_task WHERE task_id = v_nb_task)
      || '). They are non-billable because the line carries the reason "'
      || NVL((SELECT unbilled_reason FROM oc_ts_entry
               WHERE ts_entry_id = v_src_entry), '(none)')
      || '", which comes from the assignment and not from the task, so moving '
      || 'them elsewhere would not make them billable. Nothing was changed.';
    RETURN;
  END IF;

  oc_time_ctx.set_reason('Leave-loss coverage approved: ' || v_loss
                         || 'h billed for covering ' || v_absent
                         || ' on ' || TO_CHAR(v_date,'DD-Mon-YY'));

  -- ── PROMOTE BEFORE SPLITTING ───────────────────────────────
  -- A SEPARATE STATEMENT, not a wider MERGE. UK_OC_TSE_CELL includes
  -- ENTRY_TYPE, so a Default row and an Actual row can coexist on one cell:
  -- decrementing 'Actual' while MERGEing a new 'Actual' would leave the
  -- defaulted 8 untouched and add 2 beside it, giving a 10-hour day against a
  -- standard of 8. Exactly the double count e2ec95e found in save_entry.
  IF v_src_type = 'Default' THEN
    SELECT MAX(ts_entry_id) INTO v_dup
      FROM oc_ts_entry
     WHERE ts_week_id = v_week AND project_id = v_project
       AND task_id = v_nb_task AND entry_date = v_date
       AND entry_type = 'Actual';

    IF v_dup IS NULL THEN
      -- SOURCE = 'Manager' as well, so the audit row the decrement writes says
      -- Override rather than accusing the defaulting job of an edit.
      UPDATE oc_ts_entry
         SET entry_type = 'Actual', source = 'Manager', updated_by = p_actor
       WHERE ts_entry_id = v_src_entry;
    ELSE
      -- An Actual row already holds this cell, so promotion would raise
      -- ORA-00001. Fold the defaulted hours into it and leave the Default row
      -- at zero. NOT deleted -- OC_TS_AUDIT rows point at it, and db/78 is the
      -- record of what removing an audited entry costs.
      UPDATE oc_ts_entry SET hours = hours + v_avail, updated_by = p_actor
       WHERE ts_entry_id = v_dup;
      UPDATE oc_ts_entry SET hours = 0, updated_by = p_actor
       WHERE ts_entry_id = v_src_entry;
      v_src_entry := v_dup;
    END IF;
  END IF;

  UPDATE oc_ts_entry SET hours = hours - v_loss, updated_by = p_actor
   WHERE ts_entry_id = v_src_entry;

  -- MERGE, not INSERT: the cover may already have billable hours on this
  -- project that day from their own work, and a second row would break
  -- UK_OC_TSE_CELL.
  MERGE INTO oc_ts_entry e
  USING (SELECT v_week AS wk, v_project AS pid, v_bill_task AS tid,
                v_date AS d FROM dual) s
     ON (e.ts_week_id = s.wk AND e.project_id = s.pid
     AND e.task_id = s.tid AND e.entry_date = s.d AND e.entry_type = 'Actual')
   WHEN MATCHED THEN UPDATE
        SET e.hours = e.hours + v_loss, e.updated_by = p_actor
   WHEN NOT MATCHED THEN
        INSERT (ts_week_id, project_id, task_id, entry_date, hours,
                entry_type, is_leave, source, created_by)
        VALUES (s.wk, s.pid, s.tid, s.d, v_loss, 'Actual', 'N',
                'Manager', p_actor);

  oc_time_ctx.clear;

  UPDATE oc_ts_leave_loss_cover
     SET cover_hours_billed = v_loss, updated_by = p_actor
   WHERE llc_id = p_llc_id;

  o_hours   := v_loss;
  o_message := v_loss || ' hour(s) moved to a billable task for ' || v_cover
            || ' on ' || TO_CHAR(v_date,'DD-Mon-YY')
            || CASE WHEN v_src_type = 'Default'
                    THEN ' (defaulted hours promoted to Actual).' ELSE '.' END;
EXCEPTION WHEN OTHERS THEN
  oc_time_ctx.clear;
  RAISE;
END oc_time_cover_billing;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] Retry the rows both earlier guards had refused
PROMPT ============================================================

DECLARE
  v_h   NUMBER;
  v_msg VARCHAR2(400);
  v_n   NUMBER := 0;
BEGIN
  FOR r IN (SELECT llc_id
              FROM oc_ts_leave_loss_cover
             WHERE llc_status = 'Approved'
               AND billed_flag = 'Y'
               AND cover_hours_billed IS NULL
             ORDER BY llc_id)
  LOOP
    BEGIN
      oc_time_cover_billing(r.llc_id, 'Y', 'FIX_87', v_h, v_msg);
      DBMS_OUTPUT.PUT_LINE('  llc ' || r.llc_id || ': ' || v_msg);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  llc ' || r.llc_id || ': NOT COMPLETED - '
                           || SUBSTR(SQLERRM,1,200));
    END;
  END LOOP;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Nothing outstanding.');
  END IF;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

PROMPT
PROMPT The day that was split. Non-billable and billable must still add up to
PROMPT the standard day, because this splits and does not move.

COLUMN task FORMAT A26
SELECT cw.employee_name AS cover,
       TO_CHAR(e.entry_date,'DD-Mon') AS on_date,
       t.task_code || ' ' || t.task_name AS task,
       t.billable_type AS task_bill, e.billable_type AS line_bill,
       e.entry_type, e.source, e.hours
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id
  JOIN oc_ts_week  w ON w.employee_id = l.cover_employee_id
                    AND l.absence_date BETWEEN w.week_start AND w.week_end
  JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
                    AND e.entry_date = l.absence_date
                    AND e.project_id = l.project_id
                    AND e.is_leave   = 'N'
  JOIN oc_time_task t ON t.task_id = e.task_id
 WHERE l.cover_hours_billed IS NOT NULL
 ORDER BY cw.employee_name, e.entry_date, e.billable_type DESC;

PROMPT
PROMPT And the invoice appendix, which was empty until the hours existed.

SELECT project_number, absence_date, absent_employee_name,
       absence_hours, loss_hours, covered_billed_hours
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;

PROMPT
PROMPT The covering colleague's week is still Defaulted with its salary hold
PROMPT intact. The employee did not submit, and that stays true whatever a
PROMPT manager records about who covered somebody else's leave.
