--==============================================================
-- time/74_late_submit_adjustment.sql
-- O2C Timesheet Module — a late resubmission is an adjustment only if it changes
--
-- The rule, from the functional owner 18-Aug-2026:
--
--   "if the employee submits data without any changes to it then we don't send
--    it as adjustment, but he has reduced the hours or adding one more line for
--    a new project and adding some hours to it then it goes as adjustment"
--
-- Which is exactly right, and the reason is money. Defaulting already wrote the
-- prepopulated hours into the timesheet and those hours already reached accrual
-- when the month was confirmed. An employee who resubmits them unchanged has
-- restated nothing -- there is no delta to post, and raising an adjustment
-- would send a Reversal and an equal Adjustment that cancel, cluttering the
-- trail and the accrual with a correction nobody made.
--
-- THE BASELINE IS THE 'Default' ROW ITSELF. run_weekly_defaulting retags the
-- prepopulated row to ENTRY_TYPE = 'Default', and save_entry now PROMOTES that
-- row to 'Actual' when somebody edits it (db/09, same commit). So after a
-- resubmission:
--
--     still 'Default'  -> untouched, the job's figure stands
--     now  'Actual'    -> the person changed it, or added it
--
-- That is a cell-grain baseline -- project, task, date -- which matters for the
-- case the owner's wording does not reach: moving four hours from project A to
-- project B leaves the DAY total identical while changing which project is
-- billed. A day-total comparison would call that unchanged. This does not.
--
-- WHY submit_week AND NOT save_entry. The question "did this week change" can
-- only be answered once, when the week is submitted -- an employee editing
-- three cells makes one adjustment decision, not three. save_entry stays
-- ignorant of adjustments, which also keeps the ordinary in-period edit path
-- untouched.
--
-- ONLY INSIDE A SALARY HOLD. An ordinary resubmission before the cut-off is
-- just a submission, and a closed period is unreachable without the keyhole.
-- So this fires exactly where the keyhole let somebody in: a week with a Held
-- or Rejected hold day, in a period whose accrual was already confirmed.
--
-- Idempotent. Depends on: time/05, 09, 15.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TS_ADJUSTMENT';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'OC_TS_ADJUSTMENT is missing. Run 05.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] What a late resubmission changed
PROMPT ============================================================

-- One row per cell that a person altered on a week under salary hold. A view,
-- so "why did my correction raise an adjustment" is answerable afterwards and
-- the rule can be read without opening the package.
--
-- Three kinds of change, and all three are real:
--   * hours differ from what the hold recorded  -- reduced or increased
--   * a cell exists that the default never had  -- a new project line
--   * a defaulted cell is now zero              -- a line taken back off
CREATE OR REPLACE VIEW v_oc_ts_late_change AS
SELECT e.ts_entry_id,
       w.ts_week_id,
       w.employee_id,
       w.period_id,
       e.entry_date,
       e.project_id,
       e.task_id,
       e.hours                              AS new_hours,
       -- What the hold was opened against for this DAY. The hold day is the
       -- only per-date record of the figure payroll was told about.
       d.expected_hours                     AS held_expected_hours,
       -- Still Default on the same day means the job's figure for that cell was
       -- never touched; anything else on the day is the person's doing.
       (SELECT NVL(SUM(o.hours),0) FROM oc_ts_entry o
         WHERE o.ts_week_id = e.ts_week_id
           AND o.entry_date = e.entry_date
           AND o.entry_type = 'Default')    AS still_defaulted_hours,
       (SELECT NVL(SUM(o.hours),0) FROM oc_ts_entry o
         WHERE o.ts_week_id = e.ts_week_id
           AND o.entry_date = e.entry_date
           AND o.entry_type IN ('Actual','Default'))
                                            AS day_total_now
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_ts_salary_hold_day d
    ON d.ts_week_id = e.ts_week_id
   AND d.work_date  = e.entry_date
  JOIN oc_ts_salary_hold h
    ON h.hold_id = d.hold_id
   AND h.salary_status = 'Held'
 WHERE e.is_leave   = 'N'
   AND e.entry_type = 'Actual'
   AND e.source    <> 'Prepopulated';

PROMPT
PROMPT Rows here are cells a person touched on a held week. Empty is the normal
PROMPT state until somebody uses their correction window.

PROMPT ============================================================
PROMPT [2/4] OC_TIME_RAISE_LATE_ADJUSTMENTS
PROMPT ============================================================

-- Called from submit_week when the week is under a salary hold. Writes one
-- OC_TS_ADJUSTMENT per changed cell and returns how many, so the caller can
-- tell the employee what happened rather than leaving them to discover it.
CREATE OR REPLACE PROCEDURE oc_time_raise_late_adjustments(
  p_ts_week_id IN  NUMBER,
  p_reason     IN  VARCHAR2,
  p_actor      IN  VARCHAR2,
  o_raised     OUT NUMBER)
IS
  v_post NUMBER;
BEGIN
  o_raised := 0;

  -- WHERE THE CORRECTION POSTS. A closed month cannot take it, so it lands in
  -- the open period the same way run_accrual_top_up posts a late top-up. The
  -- source period stays on the row, so the trail still says which month the
  -- work belongs to.
  BEGIN
    v_post := oc_time_pkg.get_open_period_id;
  EXCEPTION WHEN OTHERS THEN
    v_post := NULL;
  END;

  FOR c IN (SELECT e.ts_entry_id, w.employee_id, w.period_id,
                   e.entry_date, e.project_id, e.task_id, e.hours,
                   d.expected_hours
              FROM oc_ts_entry e
              JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
              JOIN oc_ts_salary_hold_day d
                ON d.ts_week_id = e.ts_week_id
               AND d.work_date  = e.entry_date
              JOIN oc_ts_salary_hold h
                ON h.hold_id = d.hold_id AND h.salary_status = 'Held'
             WHERE e.ts_week_id = p_ts_week_id
               AND e.is_leave   = 'N'
               AND e.entry_type = 'Actual'
               -- PROMOTED, therefore TOUCHED. A cell the person left alone is
               -- still 'Default' and never reaches this loop -- which is the
               -- whole rule: unchanged data raises nothing.
               AND e.source    <> 'Prepopulated'
               -- Nothing already raised for this cell. Re-submitting twice
               -- must not post the same delta twice.
               AND NOT EXISTS (SELECT 1 FROM oc_ts_adjustment a
                                WHERE a.employee_id = w.employee_id
                                  AND a.work_date   = e.entry_date
                                  AND a.new_project_id = e.project_id
                                  AND a.new_task_id    = e.task_id
                                  AND a.status <> 'Rejected'))
  LOOP
    INSERT INTO oc_ts_adjustment (
      employee_id, work_date, source_period_id, post_period_id, adj_kind,
      old_project_id, old_task_id, old_hours,
      new_project_id, new_task_id, new_hours,
      status, reason, applied_by)
    VALUES (
      c.employee_id, c.entry_date, c.period_id, NVL(v_post, c.period_id),
      'RetroWBS',
      -- OLD is what the default said for this cell. Same project and task:
      -- the reversal has to name the line being corrected, and for a line that
      -- did not exist before, the old hours are simply zero.
      c.project_id, c.task_id, NVL(c.expected_hours, 0),
      c.project_id, c.task_id, c.hours,
      'Awaiting Approval',
      SUBSTR('Late submission after the payroll cut-off. ' || p_reason, 1, 1000),
      p_actor);
    o_raised := o_raised + 1;
  END LOOP;
END oc_time_raise_late_adjustments;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] Verification
PROMPT ============================================================

COLUMN employee_id FORMAT A12
SELECT w.employee_id,
       COUNT(DISTINCT w.ts_week_id) AS held_weeks,
       SUM(CASE WHEN e.entry_type = 'Default'  THEN 1 ELSE 0 END) AS untouched_cells,
       SUM(CASE WHEN e.entry_type = 'Actual'
                 AND e.source <> 'Prepopulated' THEN 1 ELSE 0 END) AS changed_cells
  FROM oc_ts_week w
  JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
  JOIN oc_ts_salary_hold h ON h.employee_id = w.employee_id
                          AND h.period_id   = w.period_id
                          AND h.salary_status = 'Held'
 WHERE e.is_leave = 'N'
 GROUP BY w.employee_id
HAVING SUM(CASE WHEN e.entry_type = 'Actual'
                 AND e.source <> 'Prepopulated' THEN 1 ELSE 0 END) > 0
 ORDER BY w.employee_id;

PROMPT
PROMPT No rows means nobody has used their correction window yet, which is the
PROMPT expected state. CHANGED_CELLS is what would raise adjustments.

SELECT COUNT(*) AS adjustments_awaiting
  FROM oc_ts_adjustment WHERE status = 'Awaiting Approval';

PROMPT ============================================================
PROMPT [4/4] Wiring it into submit_week
PROMPT ============================================================
PROMPT
PROMPT NOT DONE HERE, and deliberately. submit_week lives in the package and
PROMPT this file must not hold a second copy of it -- the two would drift and
PROMPT the one that runs would be whichever was applied last.
PROMPT
PROMPT Add to db/09_pkg_oc_time.sql, in submit_week, after the event fires:
PROMPT
PROMPT     DECLARE v_adj NUMBER; BEGIN
PROMPT       IF <this week has a Held salary hold> THEN
PROMPT         oc_time_raise_late_adjustments(p_ts_week_id, p_reason, p_actor,
PROMPT                                        v_adj);
PROMPT       END IF;
PROMPT     END;
PROMPT
PROMPT submit_week also needs a p_reason parameter and does not have one.
PROMPT RULE-002's reason lives on the hold DAY today, not on the week. That is
PROMPT the one piece of the owner's rule the schema cannot yet express, and it
PROMPT is a signature change touching ords/11 and the VBCS submit chain.
