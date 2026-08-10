--==============================================================
-- time/20_retro_reallocation.sql
-- O2C Timesheet Module — a retro allocation change becomes Reversal/Adjustment
--
-- THE SCENARIO, stated by the business owner 10-Aug-2026:
--
--   Person A is allocated to PRJ 444, task Onshore, to 31-Jul. July time is
--   logged, approved, and already sent to Project Costing and revenue accrual.
--   On 5-Aug it is decided that 444 actually ended on 15-Jul and the person
--   moved to a different project from 16-Jul.
--
--   July is closed. The clocked hours cannot be changed. So the hours booked to
--   444 from 16-Jul onward must be REMOVED from 444 and MOVED to the new
--   project -- as an adjustment, in the next open period.
--
-- Everything that does the moving already existed and is untouched here:
--
--   apply_adjustment    writes OC_TS_ADJUSTMENT with SOURCE_PERIOD = the month
--                       the work happened in and POST_PERIOD = the open one
--   approve_adjustment  on approval materialises -ABS(old_hours) as 'Reversal'
--                       against the old project/task and +ABS(new_hours) as
--                       'Adjustment' against the new one, in the OPEN period,
--                       carrying the original work date. The closed book is
--                       never touched.
--   run_accrual_top_up  carries those entries to the accrual interface, which
--                       confirm_month could not because it had already run
--
-- WHAT WAS MISSING is only the two ends: nothing expanded a DATE RANGE into
-- per-day adjustments, and nothing noticed the allocation had changed at all.
-- This file is those two ends and no new rules.
--
-- Deliberately NOT in OC_TIME_PKG. Every rule these touch -- the backdating
-- window, the dual approval, the period resolution, the sign convention --
-- stays in the package and is reached by calling it. These two are
-- orchestration: a loop and a queue reader. Putting them here keeps 09 (already
-- compiled, ~3000 lines) untouched.
--
-- Idempotent. Depends on: time/03, time/05, time/09, time/19
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] OC_TIME_RETRO_REALLOC — a date range, one day at a time
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_retro_realloc(
  p_employee_id    IN  VARCHAR2,
  p_old_project_id IN  NUMBER,
  p_old_task_id    IN  NUMBER DEFAULT NULL,   -- null = every task on the project
  p_new_project_id IN  NUMBER,
  p_new_task_id    IN  NUMBER DEFAULT NULL,   -- null = the default task rule
  p_from_date      IN  DATE,
  p_to_date        IN  DATE,
  p_reason         IN  VARCHAR2,
  p_actor          IN  VARCHAR2 DEFAULT 'SYNC',
  o_raised         OUT NUMBER,
  o_hours          OUT NUMBER,
  o_message        OUT VARCHAR2)
AS
  v_task   NUMBER := p_new_task_id;
  v_id     NUMBER;
  v_err    VARCHAR2(400);
BEGIN
  o_raised := 0;
  o_hours  := 0;

  -- The task on the new project. Resolved with the SAME rule populate_month
  -- uses, deliberately: the adjustment must land on the task the prepopulation
  -- would have chosen, or the moved hours sit on a different task from every
  -- subsequent day's hours on the same project and the project's own breakdown
  -- disagrees with itself.
  --
  -- First chargeable billable WBS task, ordered by TASK_CODE. Not by TASK_ID --
  -- that is the local identity column, so "the first task" would mean
  -- "whichever row the sync happened to insert first", which on project 444 was
  -- Leave. SORT_ORDER is never populated, so it cannot be the order either.
  IF v_task IS NULL THEN
    BEGIN
      SELECT task_id INTO v_task
        FROM (SELECT task_id FROM oc_time_task
               WHERE project_id      = p_new_project_id
                 AND task_type       = 'WBS'
                 AND status          = 'Active'
                 AND chargeable_flag = 'Y'
                 AND billable_type   = 'Billable'
               ORDER BY task_code)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      o_message := 'Project ' || p_new_project_id || ' has no chargeable '
                || 'billable WBS task, so there is nothing to move the hours '
                || 'to. Load its tasks before re-running.';
      RETURN;
    END;
  END IF;

  -- One adjustment PER DAY PER LINE, not one for the range.
  --
  -- OC_TS_ADJUSTMENT.WORK_DATE is a single day and that is right: Project
  -- Costing books to the day the work happened, so a range collapsed into one
  -- row would lose which days the hours belonged to and cost them all to
  -- whatever date was chosen. The 16-Jul..5-Aug example is ~15 rows, and that
  -- is the correct number.
  --
  -- Only 'Actual' rows with hours. A day already carrying a Reversal has been
  -- adjusted before; re-reversing it would double-count, and the guard is the
  -- entry_type filter rather than a flag on the adjustment.
  FOR e IN (SELECT e.entry_date, e.project_id, e.task_id, e.hours
              FROM oc_ts_entry e
              JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
             WHERE w.employee_id = p_employee_id
               AND e.project_id  = p_old_project_id
               AND (p_old_task_id IS NULL OR e.task_id = p_old_task_id)
               AND e.entry_date BETWEEN TRUNC(p_from_date) AND TRUNC(p_to_date)
               AND e.entry_type  = 'Actual'
               AND NVL(e.hours, 0) > 0
             ORDER BY e.entry_date, e.project_id, e.task_id)
  LOOP
    BEGIN
      v_id := oc_time_pkg.apply_adjustment(
                p_employee_id    => p_employee_id,
                p_work_date      => e.entry_date,
                p_old_project_id => e.project_id,
                p_old_task_id    => e.task_id,
                p_old_hours      => e.hours,
                p_new_project_id => p_new_project_id,
                p_new_task_id    => v_task,
                p_new_hours      => e.hours,   -- moved, not changed
                p_reason         => p_reason,
                p_adj_kind       => 'RetroWBS',
                p_actor          => p_actor);
      -- 'Not yet submitted', not the table's 'Awaiting Approval' default.
      --
      -- The employee owns it first. An adjustment raised by the SYNC concerns
      -- hours THEY logged, being moved to a project they may not know about
      -- yet; dropping it straight into a manager's queue approves a change the
      -- person it belongs to has never seen. 21_adjustment_lifecycle.sql
      -- carries it on from here -- employee submits, or the delivery cut-off
      -- submits for them, then the managers approve or the finance cut-off
      -- approves for them.
      --
      -- Set here rather than by changing apply_adjustment, so 09 stays
      -- untouched and a hand-raised adjustment from a screen keeps its
      -- existing behaviour.
      UPDATE oc_ts_adjustment
         SET status = 'Not yet submitted'
       WHERE adjustment_id = v_id;

      o_raised := o_raised + 1;
      o_hours  := o_hours + e.hours;
    EXCEPTION WHEN OTHERS THEN
      -- One day outside the RULE-019 window must not abandon the rest. The
      -- caller gets the count that DID succeed plus the first refusal, because
      -- a partial move that reports total success is the worst outcome here.
      v_err := NVL(v_err, SUBSTR(SQLERRM, 1, 300));
    END;
  END LOOP;

  o_message := o_raised || ' adjustment(s) raised for ' || o_hours || ' hour(s)'
            || CASE WHEN v_err IS NULL THEN
                 ', awaiting the employee''s submission.'
               ELSE '. AT LEAST ONE DAY WAS REFUSED: ' || v_err END;
END oc_time_retro_realloc;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/3] OC_TIME_RAISE_ALLOC_ADJ — drive it from the sync
PROMPT ============================================================

-- Reads what OC_TIME_LOAD_XML captured and turns an allocation whose END DATE
-- MOVED EARLIER into the adjustments above. Automatic and unconfirmed, by
-- instruction 10-Aug-2026: Fusion is authoritative about who was allocated
-- where, so a human re-confirming it would only be re-typing what the sync
-- already knows.
--
-- The adjustments are still raised 'Awaiting Approval', which is a DIFFERENT
-- question and deliberately unchanged. RA-014 requires the old and new project
-- managers to agree before hours actually move, and nothing in "raise it
-- automatically" says "and move the hours without either manager seeing it".
-- Auto-approving is the irreversible direction; raising is not.
--
-- Only the end date moving EARLIER matters. Later means more days are covered,
-- not fewer, so nothing already booked becomes wrong.
CREATE OR REPLACE PROCEDURE oc_time_raise_alloc_adj(
  p_actor    IN  VARCHAR2 DEFAULT 'SYNC',
  o_examined OUT NUMBER,
  o_raised   OUT NUMBER,
  o_message  OUT VARCHAR2)
AS
  v_old_end  DATE;
  v_new_end  DATE;
  v_emp      VARCHAR2(50);
  v_proj     NUMBER;
  v_newproj  NUMBER;
  v_cnt      NUMBER;
  v_hrs      NUMBER;
  v_msg      VARCHAR2(2000);
  v_total    NUMBER := 0;

  FUNCTION jval(p_doc CLOB, p_name VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(4000);
  BEGIN
    -- The capture stores an ARRAY of {name,value}; pull one by name.
    SELECT MAX(x.val) INTO v
      FROM JSON_TABLE(p_doc, '$[*]'
             COLUMNS (nm  VARCHAR2(128)  PATH '$.name',
                      val VARCHAR2(4000) PATH '$.value')) x
     WHERE x.nm = p_name;
    RETURN v;
  END;
BEGIN
  o_examined := 0; o_raised := 0;

  FOR c IN (SELECT change_id, old_row, new_row
              FROM oc_time_sync_change
             WHERE target_table      = 'OC_TIME_ALLOCATION'
               AND change_type       = 'UPDATE'
               AND adjustment_status = 'Pending'
             ORDER BY created_on, change_id)
  LOOP
    o_examined := o_examined + 1;

    v_old_end := TO_DATE(jval(c.old_row, 'END_DATE'), 'YYYY-MM-DD');
    v_new_end := TO_DATE(jval(c.new_row, 'END_DATE'), 'YYYY-MM-DD');
    v_emp     := jval(c.new_row, 'EMPLOYEE_ID');
    v_proj    := TO_NUMBER(jval(c.new_row, 'PROJECT_ID'));

    -- NVL to the far future: an allocation with no end date was open-ended, and
    -- giving it one for the first time is the commonest form of this change.
    IF NVL(v_new_end, DATE '4712-12-31') >= NVL(v_old_end, DATE '4712-12-31')
       OR v_emp IS NULL OR v_proj IS NULL THEN
      UPDATE oc_time_sync_change
         SET adjustment_status = 'NotRequired',
             decision_note     = 'End date did not move earlier.',
             decided_by = p_actor, decided_on = SYSTIMESTAMP
       WHERE change_id = c.change_id;
      CONTINUE;
    END IF;

    -- Where the hours go. The person's allocation that covers the day AFTER the
    -- new end date -- which is precisely the "allocate the resource to a
    -- different project from 16th July" half of the change.
    BEGIN
      SELECT project_id INTO v_newproj
        FROM (SELECT a.project_id
                FROM oc_time_allocation a
               WHERE a.employee_id = v_emp
                 AND a.project_id <> v_proj
                 AND a.start_date <= v_new_end + 1
                 AND (a.end_date IS NULL OR a.end_date >= v_new_end + 1)
               ORDER BY a.start_date DESC)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      -- Left the project and joined nothing. The hours are still wrong on the
      -- old project, but there is nowhere to move them, and inventing a
      -- destination would be worse than saying so.
      UPDATE oc_time_sync_change
         SET adjustment_status = 'Pending',
             decision_note     = 'End date moved to '
                              || TO_CHAR(v_new_end,'DD-MON-YYYY')
                              || ' but the employee has no other allocation '
                              || 'covering the following day. Hours after that '
                              || 'date need a destination project.',
             decided_on = SYSTIMESTAMP
       WHERE change_id = c.change_id;
      CONTINUE;
    END;

    oc_time_retro_realloc(
      p_employee_id    => v_emp,
      p_old_project_id => v_proj,
      p_old_task_id    => NULL,               -- every task on the old project
      p_new_project_id => v_newproj,
      p_new_task_id    => NULL,               -- the default task rule
      p_from_date      => v_new_end + 1,      -- the day after the new end date
      p_to_date        => SYSDATE,            -- through today
      p_reason         => 'Allocation on project ' || v_proj || ' end-dated to '
                       || TO_CHAR(v_new_end,'DD-MON-YYYY') || ' in Fusion.',
      p_actor          => p_actor,
      o_raised         => v_cnt,
      o_hours          => v_hrs,
      o_message        => v_msg);

    UPDATE oc_time_sync_change
       SET adjustment_status = CASE WHEN NVL(v_cnt,0) > 0 THEN 'Raised'
                                    ELSE 'NotRequired' END,
           decision_note     = v_msg,
           decided_by = p_actor, decided_on = SYSTIMESTAMP
     WHERE change_id = c.change_id;

    o_raised := o_raised + NVL(v_cnt, 0);
    v_total  := v_total + NVL(v_hrs, 0);
  END LOOP;

  COMMIT;
  o_message := o_examined || ' allocation change(s) examined, ' || o_raised
            || ' adjustment(s) raised covering ' || v_total || ' hour(s).';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    o_message := SUBSTR('Raising allocation adjustments failed: ' || SQLERRM, 1, 2000);
END oc_time_raise_alloc_adj;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A30
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_RETRO_REALLOC','OC_TIME_RAISE_ALLOC_ADJ')
 ORDER BY object_name;

PROMPT
PROMPT Both must be VALID. Then, after each sync:
PROMPT
PROMPT   DECLARE n NUMBER; r NUMBER; m VARCHAR2(2000);
PROMPT   BEGIN oc_time_raise_alloc_adj('SYNC', n, r, m);
PROMPT         DBMS_OUTPUT.PUT_LINE(m); END;
PROMPT
PROMPT Raised adjustments sit 'Awaiting Approval' for the OLD and NEW project
PROMPT managers (RA-014). On approval they materialise as Reversal(-) on the old
PROMPT project and Adjustment(+) on the new, in the OPEN period, carrying the
PROMPT original work date -- and run_accrual_top_up carries them to accrual.
