--==============================================================
-- time/86_annexure_bills_what_moved.sql
-- O2C Timesheet Module — the same 8-for-2 error, on the invoice
--
-- Asked on reading db/85's verification: "here absence hours is coming as 8 but
-- for this project its only 2". The grid was fixed; the question is better than
-- the fix, because the number goes somewhere else too.
--
-- ── THE ANNEXURE BILLED THE WHOLE ABSENCE ────────────────────────────────
--
-- V_OC_TS_LLC_ANNEXURE (db/07) is REP-002, the appendix that travels WITH THE
-- INVOICE. It read:
--
--   l.absence_hours AS covered_billed_hours
--
-- So 555 was set to invoice 8 hours of recovered capacity for a day where its
-- loss was 2 -- the identical fourfold overstatement, on the one document that
-- reaches the client.
--
-- THERE ARE THREE NUMBERS HERE AND THEY ARE NOT INTERCHANGEABLE:
--
--   ABSENCE_HOURS       8   the person was away all day       (about the person)
--   LOSS_HOURS          2   what this project lost            (about the project)
--   COVER_HOURS_BILLED  2   what actually moved to billable   (about the recovery)
--
-- The annexure must bill the THIRD. Not the first, which is four times the
-- loss; and not the second either, because the loss is what was at stake and
-- not necessarily what was recovered -- a cover with only one spare hour
-- recovers one. Billing LOSS_HOURS would put a figure on the invoice that no
-- timesheet supports, and accrual would then report a different one from the
-- same event. Two documents, one event, two answers, which is the exact fault
-- db/84 was written to end.
--
-- The filter moves with it. It was BILLED_FLAG = 'Y', and llc 4 shows why that
-- is not the same question: approved through the old handler, flag set, zero
-- hours moved -- and therefore ON the annexure today, claiming 8. The annexure
-- now keys on the hours, so a row reaches the invoice when, and only when,
-- there are hours behind it.
--
-- BILLED_FLAG IS NOT CLEARED. The manager did approve the coverage; that is a
-- true fact and theirs. What did not happen is the billing. Two facts, kept
-- apart -- section [3/5] reports where they disagree instead of rewriting one
-- of them to match the other.
--
-- ── THE BILLING GUARD WAS THE EMPLOYEE'S, NOT THE MANAGER'S ──────────────
--
-- db/85 [5/6] could not complete llc 4:
--
--   ORA-20007: This week is locked. Only a manager can edit a defaulted
--              timesheet.
--
-- Read that message again. This IS a manager, doing the thing it says a manager
-- may do. db/84 reused oc_time_pkg.assert_editable, which is the gate the
-- EMPLOYEE's own screen passes through, and its LOCKED_FLAG branch exists to
-- stop the employee touching a week the weekly cut-off has defaulted.
--
-- Defaulting is the employee's failure to submit. It says nothing about whether
-- a colleague covered someone's leave, and it must not be what stops the
-- manager recording the commercial consequence of somebody else's absence.
--
-- So the guard becomes a manager's. What still refuses, and why:
--
--   week Approved / Overridden / Closed   a decision has been made, and moving
--                                         hours under it changes what was
--                                         approved without saying so
--   period not Open                       RULE-004 / RULE-007
--   month already confirmed               the hours reached accrual as
--                                         non-billable; moving them now makes
--                                         the timesheet disagree with what was
--                                         sent, and the fix for that is an
--                                         adjustment, not an edit
--
-- That keeps the decision taken on 20-Aug intact -- "manager should do this
-- before the weekly cutoff or monthly cutoff" -- while letting the one case
-- through whose refusal was an accident of which gate was reused.
--
-- SUPERSEDES db/85 [4/6], which is now a pointer to here. Re-running 85 after
-- this would otherwise restore the old guard silently, the same way re-running
-- 01 would have restored UK_OC_TP_SINGLE_OPEN.
--
-- Idempotent. Depends on: time/04, 05, 07, 08, 09, 84, 85.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views WHERE view_name = 'V_OC_TS_LLC';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'V_OC_TS_LLC' AND column_name = 'LOSS_HOURS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'db/85 has not been run here: V_OC_TS_LLC.LOSS_HOURS is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] V_OC_TS_LLC_ANNEXURE bills what actually moved
PROMPT ============================================================

-- Built over V_OC_TS_LLC rather than over the table, so LOSS_HOURS keeps its
-- one definition. CUSTOMER_NAME is the only thing the view does not carry.
CREATE OR REPLACE VIEW v_oc_ts_llc_annexure AS
SELECT l.llc_id,
       l.project_id,
       l.project_number,
       l.project_name,
       p.customer_name,
       l.revenue_model,
       l.period_id,
       l.period_name,
       l.absent_employee_id,
       l.absent_employee_name,
       l.absence_date,
       l.absence_type,
       -- WHAT IS BILLED: the hours oc_time_cover_billing actually moved onto a
       -- billable task. This was ABSENCE_HOURS, which is four times the figure
       -- for a 25% allocation and is not a claim any timesheet supports.
       l.cover_hours_billed AS covered_billed_hours,
       -- BOTH KEPT AS CONTEXT, because an appendix that says "2 hours billed"
       -- with nothing beside it cannot be checked. These let a reader see the
       -- whole absence, the share at stake, and the part recovered.
       l.absence_hours,
       l.loss_hours,
       l.cover_employee_id,
       l.cover_employee_name,
       l.llc_status,
       l.billed_flag,
       l.approved_by,
       l.approved_on
  FROM v_oc_ts_llc l
  JOIN oc_time_project p ON p.project_id = l.project_id
 WHERE l.llc_status = 'Approved'
   -- THE HOURS, NOT THE FLAG. BILLED_FLAG says the manager approved; this says
   -- hours moved. llc 4 has the first without the second and was on the invoice
   -- claiming 8.
   AND NVL(l.cover_hours_billed, 0) > 0;

PROMPT ============================================================
PROMPT [2/5] OC_TIME_COVER_BILLING gets a manager's guard
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
  v_nb_task   NUMBER;
  v_bill_task NUMBER;
  v_avail     NUMBER;
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

  -- ── THE MANAGER'S WINDOW ───────────────────────────────────
  -- NOT assert_editable. That is the EMPLOYEE's gate, and its LOCKED_FLAG
  -- branch refuses a defaulted week with the words "Only a manager can edit a
  -- defaulted timesheet" -- which is precisely who is calling. Defaulting means
  -- the employee did not submit; it says nothing about whether a colleague
  -- covered someone's leave.
  --
  -- What still refuses is what the 20-Aug decision actually protects: a
  -- decision already taken, and money already sent.
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
  IF UPPER(p_apply) <> 'Y' THEN
    IF v_already <= 0 THEN
      o_message := 'Nothing had been billed for this coverage.';
      RETURN;
    END IF;

    SELECT MIN(e.task_id) INTO v_bill_task
      FROM oc_ts_entry e JOIN oc_time_task t ON t.task_id = e.task_id
     WHERE e.ts_week_id = v_week AND e.entry_date = v_date
       AND e.project_id = v_project AND e.is_leave = 'N'
       AND t.billable_type = 'Billable' AND e.hours >= v_already;

    SELECT MIN(e.task_id) INTO v_nb_task
      FROM oc_ts_entry e JOIN oc_time_task t ON t.task_id = e.task_id
     WHERE e.ts_week_id = v_week AND e.entry_date = v_date
       AND e.project_id = v_project AND e.is_leave = 'N'
       AND t.billable_type = 'Non-billable';

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

  -- READ, DO NOT RECOMPUTE. The screen shows V_OC_TS_LLC.LOSS_HOURS and this
  -- moves V_OC_TS_LLC.LOSS_HOURS, so the manager cannot approve one number and
  -- get another.
  SELECT loss_hours INTO v_loss FROM v_oc_ts_llc WHERE llc_id = p_llc_id;

  IF NVL(v_loss,0) <= 0 THEN
    o_message := 'The absent colleague has no allocated hours on this project '
              || 'for that day, so there is no loss to recover.';
    RETURN;
  END IF;

  -- Where the hours come FROM: the cover's non-billable line on this project.
  SELECT MIN(e.task_id), NVL(MAX(e.hours),0) INTO v_nb_task, v_avail
    FROM oc_ts_entry e JOIN oc_time_task t ON t.task_id = e.task_id
   WHERE e.ts_week_id = v_week AND e.entry_date = v_date
     AND e.project_id = v_project AND e.is_leave = 'N'
     AND e.entry_type = 'Actual'
     AND t.billable_type = 'Non-billable';

  IF v_nb_task IS NULL THEN
    o_message := 'The covering colleague has no non-billable hours on this '
              || 'project that day, so there is nothing to convert.';
    RETURN;
  END IF;

  -- Never move more than they actually have. A cover with only 1 hour on the
  -- project cannot recover a 2-hour loss, and inventing the difference would
  -- put the day over its standard. This is also why the annexure bills
  -- COVER_HOURS_BILLED and not LOSS_HOURS -- they are allowed to differ.
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

  oc_time_ctx.set_reason('Leave-loss coverage approved: ' || v_loss
                         || 'h billed for covering ' || v_absent
                         || ' on ' || TO_CHAR(v_date,'DD-Mon-YY'));

  UPDATE oc_ts_entry SET hours = hours - v_loss, updated_by = p_actor
   WHERE ts_week_id = v_week AND entry_date = v_date
     AND project_id = v_project AND task_id = v_nb_task
     AND entry_type = 'Actual';

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
            || ' on ' || TO_CHAR(v_date,'DD-Mon-YY') || '.';
EXCEPTION WHEN OTHERS THEN
  -- A value left in the context would attach this reason to whatever the
  -- session writes next.
  oc_time_ctx.clear;
  RAISE;
END oc_time_cover_billing;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/5] Where the approval and the billing disagree
PROMPT ============================================================

COLUMN absent FORMAT A22
COLUMN cover  FORMAT A22
COLUMN verdict FORMAT A46
SELECT l.llc_id,
       TO_CHAR(l.absence_date,'DD-Mon') AS on_date,
       aw.employee_name AS absent,
       NVL(cw.employee_name,'(none)') AS cover,
       l.billed_flag,
       NVL(TO_CHAR(l.cover_hours_billed),'-') AS billed_hrs,
       CASE
         WHEN l.billed_flag = 'Y' AND l.cover_hours_billed IS NULL
           THEN 'flag says billed, no hours moved - off annexure'
         WHEN l.billed_flag = 'N' AND l.cover_hours_billed IS NOT NULL
           THEN 'hours moved without the flag - investigate'
         ELSE 'consistent'
       END AS verdict
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_worker aw ON aw.employee_id = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id
 WHERE l.llc_status = 'Approved'
 ORDER BY l.llc_id;

PROMPT
PROMPT BILLED_FLAG is not corrected to match. The manager did approve; the
PROMPT billing is what did not happen. Rewriting one to agree with the other
PROMPT would destroy the only evidence that they ever differed.

PROMPT ============================================================
PROMPT [4/5] Retry the rows the employee gate had refused
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
      oc_time_cover_billing(r.llc_id, 'Y', 'FIX_86', v_h, v_msg);
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
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN proj FORMAT A10
SELECT l.llc_id, l.project_number AS proj, l.absence_date AS on_date,
       l.absent_employee_name AS absent,
       l.absence_hours, l.loss_hours,
       NVL(l.cover_employee_name,'(none)') AS cover,
       l.llc_status,
       NVL(TO_CHAR(l.cover_hours_billed),'-') AS billed_hrs
  FROM v_oc_ts_llc l
 ORDER BY l.project_number, l.absence_date;

PROMPT
PROMPT And what the invoice would now carry. COVERED_BILLED_HOURS is the
PROMPT recovered figure; ABSENCE_HOURS and LOSS_HOURS sit beside it so the
PROMPT appendix can be checked rather than taken on trust.

SELECT project_number, absence_date, absent_employee_name,
       absence_hours, loss_hours, covered_billed_hours
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;

PROMPT
PROMPT A row that is Approved but recovered nothing is correctly ABSENT from
PROMPT that second result. Section [3/5] listed those, with the reason.
