--==============================================================
-- time/83_llc_test_setup.sql
-- O2C Timesheet Module — making leave-loss coverage reachable, and running it
--
-- PROC-006 has never executed once. Not "untested" -- unreachable:
-- generate_llc_lines refuses with -20014 unless the project is FCP with
-- LEAVE_LOSS_FLAG = 'Y', and REVENUE_MODEL has been NULL on every project since
-- the module was built. V_OC_TS_LLC joins on the same pair, so the screen has
-- always been empty for the same reason.
--
-- 555 IS THE PROJECT. The main application has it as 'Capacity', which is what
-- this module calls FCP -- visible on the Project Master screen today. db/81
-- exists to carry that across, and it currently cannot: the rate card is not
-- reachable by PROJECT_ID, which the schema warns is "set only in the
-- accrual-bundled mode". That is a join to fix, not a fact in doubt.
--
-- SO THIS SETS THE FLAG BY HAND, and is honest about what that is. It records
-- something the main application already says, so it is not invented data --
-- but it IS a stand-in, and it must not outlive the join fix:
--
--   * stamped UPDATED_BY = 'LLC_TEST_83' so it can be found and reversed
--   * db/81 overwrites it the moment the rate card resolves, with no conflict:
--     it sets the same column to the same value from the real source
--   * if the main app ever says 555 is NOT Capacity, db/81 corrects it and this
--     script's effect disappears -- which is the right outcome
--
-- Reversal, exactly and only this:
--     UPDATE oc_time_project SET revenue_model = NULL, leave_loss_flag = 'N'
--      WHERE updated_by = 'LLC_TEST_83';
--
-- WHAT THE TEST NEEDS, and all three already hold on this pod:
--   an FCP project                555, once section 1 runs
--   somebody allocated to it      RI2824 at 25%
--   an approved, non-LOP absence  RI2824 on 07, 19 and 20-Aug
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
PROMPT [1/5] 555 becomes FCP with leave loss on
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_project
     SET revenue_model   = 'FCP',
         leave_loss_flag = 'Y',
         updated_by      = 'LLC_TEST_83',
         updated_on      = SYSTIMESTAMP
   WHERE project_number = '555'
     AND status = 'Active'
     AND (NVL(revenue_model,'x') <> 'FCP' OR leave_loss_flag <> 'Y');
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' project set to FCP + leave loss.');
  DBMS_OUTPUT.PUT_LINE('  Provisional: db/81 replaces this from the rate card '
                    || 'once the join is fixed.');
END;
/

PROMPT ============================================================
PROMPT [2/5] Who on 555 was absent, and is any of it eligible
PROMPT ============================================================

-- RULE-014 excludes LOP and maternity, so an absence being present is not the
-- same as it counting. Both flags are shown rather than filtered, because
-- "nothing came through" and "it was excluded on purpose" look identical in a
-- result set that has already applied the rule.
COLUMN employee_name FORMAT A26
COLUMN absence_type FORMAT A16
SELECT wk.employee_name, TO_CHAR(ab.absence_date,'DD-Mon-YY') AS absence_date,
       ab.absence_type, ab.absence_hours,
       ab.approval_status, ab.is_lop, ab.is_maternity,
       CASE WHEN ab.approval_status <> 'Approved' THEN 'not approved'
            WHEN ab.is_lop = 'Y'                  THEN 'excluded: LOP'
            WHEN ab.is_maternity = 'Y'            THEN 'excluded: maternity'
            ELSE 'eligible' END AS verdict
  FROM oc_time_absence    ab
  JOIN oc_time_worker     wk ON wk.employee_id = ab.employee_id
  JOIN oc_time_allocation al ON al.employee_id = ab.employee_id
                            AND al.status      = 'Active'
  JOIN oc_time_project    p  ON p.project_id   = al.project_id
                            AND p.project_number = '555'
 ORDER BY wk.employee_name, ab.absence_date;

PROMPT
PROMPT Nothing here means the test has no subject: apply and approve a leave in
PROMPT Fusion for somebody allocated to 555, reload PAGE-001 to sync it, then
PROMPT re-run this script.

PROMPT ============================================================
PROMPT [3/5] Generate the absentee list — PROC-006, first run ever
PROMPT ============================================================

-- One call per period that has absence. Driven off the absences themselves
-- rather than a hard-coded month, so this keeps working as the data moves.
DECLARE
  v_proj NUMBER;
  v_made NUMBER;
  v_tot  NUMBER := 0;
BEGIN
  SELECT project_id INTO v_proj
    FROM oc_time_project WHERE project_number = '555' AND status = 'Active';

  FOR pe IN (SELECT DISTINCT p.period_id, p.period_name
               FROM oc_time_absence    ab
               JOIN oc_time_allocation al ON al.employee_id = ab.employee_id
                                         AND al.project_id  = v_proj
                                         AND al.status      = 'Active'
               JOIN oc_time_period     p  ON ab.absence_date
                                             BETWEEN p.start_date AND p.end_date
              WHERE ab.approval_status = 'Approved'
                AND ab.is_lop = 'N' AND ab.is_maternity = 'N'
              ORDER BY p.period_id)
  LOOP
    v_made := oc_time_pkg.generate_llc_lines(v_proj, pe.period_id, 'LLC_TEST_83');
    v_tot  := v_tot + v_made;
    DBMS_OUTPUT.PUT_LINE('  ' || pe.period_name || ': ' || v_made || ' line(s)');
  END LOOP;

  COMMIT;
  IF v_tot = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Nothing generated. Either section 2 was empty, or '
                      || 'the lines already exist -- the insert skips a '
                      || 'person/date already on the list, so re-running adds '
                      || 'nothing rather than duplicating.');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('  Project 555 not found or not Active.');
END;
/

PROMPT ============================================================
PROMPT [4/5] The absentee list, as PAGE-006 will show it
PROMPT ============================================================

COLUMN absent_employee_name FORMAT A26
COLUMN cover_employee_name FORMAT A26
SELECT l.llc_id, l.absence_date, l.absent_employee_name,
       l.absence_type, l.absence_hours,
       l.llc_status, NVL(l.cover_employee_name,'(none yet)') AS cover
  FROM v_oc_ts_llc l
 ORDER BY l.absence_date, l.absent_employee_name;

PROMPT
PROMPT This view has returned nothing since the module was built - it joins on
PROMPT revenue_model = 'FCP' AND leave_loss_flag = 'Y'. Rows here are PROC-006
PROMPT reaching the screen for the first time.

PROMPT ============================================================
PROMPT [5/5] Who could cover, per absent day
PROMPT ============================================================

-- The cover pool is UNBILLED people on the same project who are not themselves
-- absent that day (RA-013). Unbilled because covering with a billable resource
-- moves the loss rather than closing it.
COLUMN employee_name FORMAT A26
COLUMN client_role FORMAT A22
SELECT TO_CHAR(c.absence_date,'DD-Mon-YY') AS absence_date,
       c.cover_employee_id, c.employee_name, c.client_role, c.billing_status
  FROM v_oc_ts_llc_eligible_cover c
  JOIN oc_time_project p ON p.project_id = c.project_id
                        AND p.project_number = '555'
 ORDER BY c.absence_date, c.employee_name;

PROMPT
PROMPT No candidates is a real answer, not a failure: RA-013 says "no eligible
PROMPT cover" is surfaced and the absence stays unbilled. On 555 the Unbilled
PROMPT people are Kishore, Venkata and User Rite - if none appears, check they
PROMPT are not absent on the same day.
PROMPT
PROMPT NEXT, on PAGE-006 or by hand:
PROMPT   BEGIN oc_time_pkg.assign_cover(<llc_id>, '<cover_employee_id>', 'TESTER'); END;
PROMPT That is ACT-024, and it is what closes the loss.
