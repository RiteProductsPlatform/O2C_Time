--==============================================================
-- time/84_cover_hours_become_billable.sql
-- O2C Timesheet Module — covering someone makes those hours billable
--
-- Asked 20-Aug: "for those unbilled employees who replace a billed employee as
-- leave loss coverage, then those hours need to go as billed for those
-- employee -- is this condition taken care?"
--
-- It was not, and the two halves of the system disagreed about it. approve_cover
-- sets BILLED_FLAG='Y' on the LLC row and V_OC_TS_LLC_ANNEXURE reads that, so
-- the LOSS was recorded as recovered -- while the covering employee's own
-- OC_TS_ENTRY rows were never touched. The accrual interface therefore received
-- those hours as NON_BILLABLE_HOURS and the invoice annexure never billed them.
-- Two documents generated from one event, saying different things.
--
-- WHY THIS IS NOT A FLAG ON THE ENTRY. TRG_OC_TSE_DERIVE is BEFORE INSERT OR
-- UPDATE and sets :NEW.billable_type from the TASK. Billability is derived
-- here, always -- setting it on a row is overwritten inside the same statement.
-- So the hours have to MOVE to a billable task, which is also how
-- oc_time_change_line_task makes a line billable. Consistent with the module
-- rather than an exception to it.
--
-- CAPPED AT THE ABSENTEE'S SHARE, per the decision. The loss is what the absent
-- person would have billed -- their allocation percentage of that day, not the
-- whole day. RI2824 at 25% on 555 loses 2 hours of an 8-hour day, so 2 hours of
-- the cover's day become billable and the remaining 6 stay non-billable. Moving
-- the whole day would bill 8 hours against a 2-hour loss and overstate the
-- recovery fourfold.
--
-- So this SPLITS rather than moves: the non-billable line loses N hours and a
-- billable line gains them. The day's total is unchanged, which is what keeps
-- validate_day and the submit-time day-total check satisfied.
--
-- THE WEEK MUST STILL BE EDITABLE, per the decision: "manager should do this
-- before the weekly cutoff or monthly cutoff -- this is the job of the
-- manager". So no adjustment path and no reversal posting. assert_editable
-- refuses a locked week, a closed period or a passed cut-off, and the manager
-- is told to act in time rather than the system quietly rewriting confirmed
-- history.
--
-- REVERSIBLE, per the decision. COVER_HOURS_BILLED records exactly how much
-- moved, so revoking puts back that number rather than recomputing it -- the
-- allocation may have changed in between, and recomputing would silently return
-- a different quantity from the one taken.
--
-- Idempotent. Depends on: time/05, 08, 09.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables
   WHERE table_name = 'OC_TS_LEAVE_LOSS_COVER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] COVER_HOURS_BILLED on the coverage row
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE
    'ALTER TABLE oc_ts_leave_loss_cover ADD (COVER_HOURS_BILLED NUMBER(5,2))';
  DBMS_OUTPUT.PUT_LINE('COVER_HOURS_BILLED added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN
    DBMS_OUTPUT.PUT_LINE('COVER_HOURS_BILLED already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

COMMENT ON COLUMN oc_ts_leave_loss_cover.cover_hours_billed IS
  'Hours actually moved from the cover employee''s non-billable line to a billable one when this coverage was approved. NULL means nothing has been moved. Revoking puts back this number, not a recomputed one.';

PROMPT ============================================================
PROMPT [2/4] OC_TIME_COVER_BILLING — move the hours, or put them back
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_cover_billing(
  p_llc_id  IN  NUMBER,
  p_apply   IN  VARCHAR2,          -- 'Y' bill the cover, 'N' put it back
  p_actor   IN  VARCHAR2 DEFAULT 'VBCS_USER',
  o_hours   OUT NUMBER,
  o_message OUT VARCHAR2)
IS
  v_project   NUMBER;
  v_date      DATE;
  v_absent    VARCHAR2(50);
  v_cover     VARCHAR2(50);
  v_already   NUMBER;
  v_std       NUMBER;
  v_pct       NUMBER;
  v_loss      NUMBER;
  v_week      NUMBER;
  v_nb_task   NUMBER;
  v_bill_task NUMBER;
  v_avail     NUMBER;
BEGIN
  o_hours := 0;

  SELECT project_id, absence_date, absent_employee_id, cover_employee_id,
         NVL(cover_hours_billed, 0)
    INTO v_project, v_date, v_absent, v_cover, v_already
    FROM oc_ts_leave_loss_cover WHERE llc_id = p_llc_id;

  IF v_cover IS NULL THEN
    o_message := 'No covering colleague assigned yet.';
    RETURN;
  END IF;

  v_week := oc_time_pkg.ensure_week(v_cover, v_date, p_actor);

  -- THE MANAGER'S WINDOW. Decided 20-Aug: coverage is settled before the
  -- cut-off, so there is no adjustment path here. A locked week, a closed
  -- period or a passed cut-off raises from assert_editable and the message
  -- reaches the screen unchanged.
  oc_time_pkg.assert_editable(v_week);

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

  -- THE LOSS IS THE ABSENTEE'S SHARE OF THE DAY, not the whole day. Their
  -- allocation percentage against their own standard hours, rounded to the
  -- quarter CHK_OC_TSE_QUARTER requires.
  SELECT NVL(MAX(al.alloc_pct), 0) INTO v_pct
    FROM oc_time_allocation al
   WHERE al.employee_id = v_absent AND al.project_id = v_project
     AND al.status = 'Active'
     AND v_date BETWEEN al.start_date AND NVL(al.end_date, v_date);

  SELECT NVL(MAX(e.standard_hours),
             (SELECT std_hours_per_day FROM oc_time_worker
               WHERE employee_id = v_absent))
    INTO v_std
    FROM oc_ts_entry e
    JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
   WHERE w.employee_id = v_absent AND e.entry_date = v_date;

  v_loss := ROUND(NVL(v_std,0) * NVL(v_pct,0) / 100 * 4) / 4;

  IF v_loss <= 0 THEN
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
  -- put the day over its standard.
  v_loss := LEAST(v_loss, v_avail);
  IF v_loss <= 0 THEN
    o_message := 'No non-billable hours available to convert.';
    RETURN;
  END IF;

  -- Where the hours go TO: the project's first billable task, read from the LOV
  -- so the employee can also see and change it -- the same rule populate now
  -- follows.
  SELECT MIN(task_id) INTO v_bill_task
    FROM (SELECT task_id FROM v_oc_ts_task_lov
           WHERE project_id = v_project AND billable_type = 'Billable'
           ORDER BY sort_order, task_code, task_id)
   WHERE ROWNUM = 1;

  IF v_bill_task IS NULL THEN
    o_message := 'This project has no billable task to move the hours onto.';
    RETURN;
  END IF;

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

  UPDATE oc_ts_leave_loss_cover
     SET cover_hours_billed = v_loss, updated_by = p_actor
   WHERE llc_id = p_llc_id;

  o_hours   := v_loss;
  o_message := v_loss || ' hour(s) moved to a billable task for ' || v_cover
            || ' on ' || TO_CHAR(v_date,'DD-Mon-YY') || '.';
END oc_time_cover_billing;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] approve_cover and revoke call it
PROMPT ============================================================

-- Wrapped rather than inlined into OC_TIME_PKG: the package is large, this is
-- one self-contained rule, and keeping it separate means the billing move can
-- be re-run or reversed on its own while diagnosing a day.
CREATE OR REPLACE PROCEDURE oc_time_approve_cover(
  p_llc_id       IN NUMBER,
  p_actor_emp_id IN VARCHAR2,
  p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
IS
  v_h NUMBER; v_msg VARCHAR2(400);
BEGIN
  oc_time_pkg.approve_cover(p_llc_id, p_actor_emp_id, p_actor);
  oc_time_cover_billing(p_llc_id, 'Y', p_actor, v_h, v_msg);
  DBMS_OUTPUT.PUT_LINE('  ' || v_msg);
END oc_time_approve_cover;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN absent FORMAT A22
COLUMN cover FORMAT A22
SELECT l.llc_id, TO_CHAR(l.absence_date,'DD-Mon') AS absence_date,
       aw.employee_name AS absent, l.absence_hours,
       NVL(cw.employee_name,'(none)') AS cover,
       l.llc_status, l.billed_flag,
       NVL(TO_CHAR(l.cover_hours_billed),'-') AS hours_billed
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_worker aw ON aw.employee_id = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id
 ORDER BY l.absence_date, aw.employee_name;

PROMPT
PROMPT HOURS_BILLED is what actually moved. It should equal the absentee's
PROMPT allocation share of their standard day - 25% of 8 is 2 - and NOT the
PROMPT cover's whole day.

PROMPT
PROMPT TO USE IT:
PROMPT   BEGIN oc_time_approve_cover(<llc_id>, '<manager_emp_id>', 'TESTER'); END;
PROMPT
PROMPT TO REVERSE:
PROMPT   DECLARE h NUMBER; m VARCHAR2(400); BEGIN
PROMPT     oc_time_cover_billing(<llc_id>, 'N', 'TESTER', h, m);
PROMPT     DBMS_OUTPUT.PUT_LINE(m); END;
