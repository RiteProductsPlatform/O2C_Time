--==============================================================
-- time/26_change_line_task.sql
-- O2C Timesheet Module — H8: move a line to a different task
--
-- Requested 12-Aug-2026. TASK (WBS) was static text, so an employee with more
-- than one task on a project could only move hours by deleting the line and
-- adding it again -- losing the hours already typed.
--
-- THE COLLISION, AND WHY THIS REFUSES
--   UK_OC_TSE_CELL is (ts_week_id, project_id, task_id, entry_date,
--   entry_type). Changing a line's task rewrites part of its own key, so
--   picking a task that already has a line on the same project collides.
--
--   Three answers were possible -- merge the two lines, refuse, or swap them.
--   REFUSE was chosen (12-Aug). Merging is friendlier and silently changes
--   numbers the employee is looking at; on a timesheet that later becomes
--   payroll and revenue, a surprise is worse than a refusal. Swapping is
--   clever and nobody would predict it.
--
--   So: the refusal names the task and says what to do instead. The employee
--   is never left guessing what the system did with their hours.
--
-- LEAVE IS NOT MOVABLE. RULE-008 makes it system-owned -- it arrives from
-- Absence Management, nobody types it, and its task is not the employee's to
-- change. Guarded here rather than only in the page, so a caller hitting ORDS
-- directly meets the same refusal.
--
-- SOURCE = 'Employee' on the update, deliberately. The employee is making this
-- change, and TRG_OC_TSE_AUDIT_CAPTURE returns early for that source: an
-- employee rearranging their own draft is normal editing, not an audited
-- override. Leaving SOURCE alone would have logged it as ManagerEdit -- the
-- same defect time/25 fixed for leave.
--
-- Idempotent. Depends on: time/03, time/08, time/09
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/2] OC_TIME_CHANGE_LINE_TASK
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_change_line_task(
  p_ts_week_id  IN NUMBER,
  p_project_id  IN NUMBER,
  p_old_task_id IN NUMBER,
  p_new_task_id IN NUMBER,
  p_actor       IN VARCHAR2 DEFAULT 'VBCS_USER')
IS
  v_leave NUMBER := 0;
  v_ok    NUMBER := 0;
  v_clash NUMBER := 0;
  v_name  oc_time_task.task_name%TYPE;
  v_rows  NUMBER := 0;
BEGIN
  -- Cut-offs, period state and week lock, all in one place (RULE-007).
  oc_time_pkg.assert_editable(p_ts_week_id);

  IF p_new_task_id = p_old_task_id THEN
    RETURN;                                   -- nothing asked for
  END IF;

  -- 1. Leave never moves.
  SELECT COUNT(*) INTO v_leave
    FROM oc_ts_entry
   WHERE ts_week_id = p_ts_week_id
     AND project_id = p_project_id
     AND task_id    = p_old_task_id
     AND is_leave   = 'Y';

  IF v_leave > 0 THEN
    RAISE_APPLICATION_ERROR(-20012,
      'Leave comes from Absence Management and its task cannot be changed '
      || 'here. Change the absence in HR instead.');
  END IF;

  -- 2. The target must be a task this project actually offers. Reading the LOV
  --    rather than OC_TIME_TASK means RULE-010 is applied once, in one place --
  --    chargeable AND billable, or a COMMON non-billable task, and never Leave
  --    (SELECTABLE_FLAG='N').
  SELECT COUNT(*) INTO v_ok
    FROM v_oc_ts_task_lov
   WHERE project_id = p_project_id
     AND task_id    = p_new_task_id;

  IF v_ok = 0 THEN
    RAISE_APPLICATION_ERROR(-20012,
      'That task is not available on this project.');
  END IF;

  -- 3. THE REFUSAL. Name the task -- "already exists" without saying which one
  --    sends the employee hunting up their own timesheet.
  SELECT COUNT(*) INTO v_clash
    FROM oc_ts_entry
   WHERE ts_week_id = p_ts_week_id
     AND project_id = p_project_id
     AND task_id    = p_new_task_id
     AND entry_type = 'Actual';

  IF v_clash > 0 THEN
    SELECT MAX(task_name) INTO v_name
      FROM oc_time_task WHERE task_id = p_new_task_id;

    RAISE_APPLICATION_ERROR(-20011,
      NVL(v_name, 'That task') || ' is already on this timesheet. Enter the '
      || 'hours on that line, or remove it first and try again.');
  END IF;

  -- 4. Move it. IS_LEAVE='N' is belt and braces after check 1 -- a project can
  --    carry both a worked line and a leave line for the same task, and only
  --    the worked one is the employee's to move.
  UPDATE oc_ts_entry
     SET task_id    = p_new_task_id,
         source     = 'Employee',
         updated_by = p_actor,
         updated_on = SYSTIMESTAMP
   WHERE ts_week_id = p_ts_week_id
     AND project_id = p_project_id
     AND task_id    = p_old_task_id
     AND entry_type = 'Actual'
     AND is_leave   = 'N';

  v_rows := SQL%ROWCOUNT;

  -- TRG_OC_TSE_DERIVE re-derives BILLABLE_TYPE from the new task on update, so
  -- moving a line to a non-billable task correctly makes those hours
  -- non-billable. That is the point, and it is why this cannot be a blind
  -- key rewrite.
  DBMS_OUTPUT.PUT_LINE(v_rows || ' day(s) moved to task ' || p_new_task_id);
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/2] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A30
SELECT object_name, object_type, status
  FROM user_objects WHERE object_name = 'OC_TIME_CHANGE_LINE_TASK';

PROMPT
PROMPT Refusals use -20011 (task already on the timesheet) and -20012 (leave, or
PROMPT a task the project does not offer). Both sit inside -20001..-20025, which
PROMPT the ORDS handlers map to HTTP 400 with the message passed through, so the
PROMPT page can toast the rule's own wording rather than inventing its own.
