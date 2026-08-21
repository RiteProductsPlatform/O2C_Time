--==============================================================
-- time/102_close_july_and_confirm.sql
-- O2C Timesheet Module — default July's last week by hand, then confirm it
--
-- Asked 21-Aug: close July's straggler manually, confirm the month, and get
-- real rows into the accrual summaries so the queries can be tested.
--
-- ── WHY A STRAGGLER EXISTS AT ALL ────────────────────────────
--
-- Venkata's week 5 (27-31 Jul) still reads NotYetSubmitted while weeks 1-4 read
-- Defaulted at cut-off. The scheduler is healthy -- Weekly Defaulting ran at
-- 05:35 today and succeeded -- it simply never looks at July:
--
--   oc_time_run_cutoffs loops over periods WHERE status = 'Open'
--
-- with the reasoning written into it: "a week inside a closed month is
-- corrected by a retro adjustment (RULE-019), never by defaulting it now".
-- Weeks 1-4 had cut-offs while July was open. Week 5 ends on a Friday and its
-- cut-off is the Monday AFTER month end, by which time July had closed.
--
-- THAT IS EVERY MONTH, not an edge case: the last week of any month always has
-- its cut-off after the month ends. Left alone the week can never default, so
-- RULE-016 never holds pay for it and the month carries a status nobody can
-- resolve. Whether oc_time_run_cutoffs should reach back one period is a
-- decision that has not been taken -- so this script does that one week by
-- hand and does not change the job.
--
-- run_weekly_defaulting itself has no period-status test; only the scheduler's
-- loop does. So calling it directly for July is not a bypass of a rule, it is
-- the same rule applied to a period the loop declines to visit.
--
-- ── AND WHY db/09 HAD TO CHANGE FIRST ────────────────────────
--
-- Confirming July can only be an Advance closure: every employee is Pending and
-- the delivery cut-off went on 02-Aug, so nobody can approve now. The RULE-020
-- gate accepts that. The interface INSERT did not -- it filtered
-- day_status = 'Approved', and a defaulted day is Pending. The month would have
-- confirmed with ACCRUAL_ROWS = 0 and accrual would have received an empty
-- batch, reading as "no time in July" rather than "nobody approved it".
--
-- db/09 now mirrors the gate in the payload. Run it before this.
--
-- NOT IDEMPOTENT IN EFFECT, THOUGH SAFE TO RE-RUN. Defaulting is a state
-- change and confirming is a hand-off; both are guarded so a second run does
-- nothing, but the first run is real.
--
-- Depends on: time/09 (with the payload fix), 101.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'XX_O2C_TIMESHEET_ACCRUAL_IF'
     AND column_name = 'MAIN_PROJECT_NUMBER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'db/101 has not been run: XX_O2C_TIMESHEET_ACCRUAL_IF.MAIN_PROJECT_NUMBER '
      || 'is missing, so the summaries would carry no main-app project code.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] July before
PROMPT ============================================================

COLUMN nm FORMAT A24
SELECT w.employee_id, wk.employee_name AS nm, w.week_index,
       TO_CHAR(w.week_start,'DD-Mon') || ' to ' || TO_CHAR(w.week_end,'DD-Mon') AS wk,
       w.submission_status, w.approval_status
  FROM oc_ts_week w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
 WHERE w.period_id = (SELECT period_id FROM oc_time_period WHERE period_name = 'JUL-2026')
   AND w.submission_status = 'NotYetSubmitted'
 ORDER BY wk.employee_name, w.week_index;

PROMPT
PROMPT Every row above has a cut-off that passed while July was closed, so the
PROMPT scheduler never saw it.

PROMPT ============================================================
PROMPT [2/5] Default them, by the same rule the job uses
PROMPT ============================================================

DECLARE
  v_period NUMBER;
  v_job    NUMBER;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period WHERE period_name = 'JUL-2026';

  -- Same function the scheduler calls, same as-of date. It re-reads
  -- oc_time_week_timing per week, so a week still inside its cut-off is
  -- skipped here exactly as it would be there.
  v_job := oc_time_pkg.run_weekly_defaulting(v_period, SYSDATE, 'MANUAL_102');
  DBMS_OUTPUT.PUT_LINE('  weekly defaulting job ' || v_job);
  COMMIT;
END;
/

SELECT w.submission_status, COUNT(*) AS weeks
  FROM oc_ts_week w
 WHERE w.period_id = (SELECT period_id FROM oc_time_period WHERE period_name = 'JUL-2026')
 GROUP BY w.submission_status
 ORDER BY 1;

PROMPT
PROMPT NotYetSubmitted should be gone, or down to weeks whose cut-off has
PROMPT genuinely not passed.

PROMPT ============================================================
PROMPT [3/5] Confirm July for 555, as an Advance closure
PROMPT ============================================================

-- 555 ONLY. Confirming every project would be a hand-off nobody asked for;
-- this is the project the accrual queries are being tested against.
DECLARE
  v_period  NUMBER;
  v_project NUMBER;
  v_already NUMBER;
  v_confirm NUMBER;
  v_rows    NUMBER;
BEGIN
  SELECT period_id  INTO v_period  FROM oc_time_period  WHERE period_name   = 'JUL-2026';
  SELECT project_id INTO v_project FROM oc_time_project WHERE project_number = '555';

  SELECT COUNT(*) INTO v_already FROM oc_ts_month_confirm
   WHERE project_id = v_project AND period_id = v_period;

  IF v_already > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Already confirmed - left alone.');
  ELSE
    -- 'Advance closure', and it has to be: every employee is Pending and the
    -- delivery cut-off went on 02-Aug, so a Normal confirm cannot pass and
    -- nobody can approve now. CONFIRM_TYPE records that it went out this way.
    v_confirm := oc_time_pkg.confirm_month(
                   v_project, v_period, 'RI9001',
                   'Advance closure', 'MANUAL_102', NULL);
    DBMS_OUTPUT.PUT_LINE('  confirm_id ' || v_confirm);
  END IF;

  SELECT NVL(SUM(accrual_rows),0) INTO v_rows
    FROM oc_ts_month_confirm
   WHERE project_id = v_project AND period_id = v_period;
  DBMS_OUTPUT.PUT_LINE('  interface rows: ' || v_rows);

  IF v_rows = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  *** ZERO. db/09 has not been re-run with the '
      || 'payload fix, so the gate accepted the month and the INSERT refused '
      || 'every day in it. Run db/09 and re-run this.');
  END IF;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/5] What accrual will now see
PROMPT ============================================================

PROMPT
PROMPT 1. MONTHLY

COLUMN nm    FORMAT A24
COLUMN role_ FORMAT A22
SELECT main_project_number, project_number AS fusion_no,
       employee_id, employee_name AS nm, client_role AS role_,
       days_worked, billable_hours, non_billable_hours, leave_hours, total_hours
  FROM v_oc_ts_anx_month
 WHERE period_year = 2026 AND period_month = 7
 ORDER BY employee_name;

PROMPT
PROMPT 2. DAILY  (first 15 rows)

SELECT main_project_number, employee_id, work_date, day_name,
       billable_hours, non_billable_hours, leave_hours, total_hours
  FROM (SELECT d.*, ROW_NUMBER() OVER (ORDER BY employee_id, work_date) AS rn
          FROM v_oc_ts_anx_day d
         WHERE period_year = 2026 AND period_month = 7)
 WHERE rn <= 15;

PROMPT
PROMPT 3. DAILY TASK-WISE  (first 15 rows)

COLUMN wbs FORMAT A14
SELECT main_project_number, employee_id, work_date, wbs_task AS wbs,
       entry_type, billable_hours, non_billable_hours, leave_hours
  FROM (SELECT d.*, ROW_NUMBER() OVER (ORDER BY employee_id, work_date, wbs_task) AS rn
          FROM v_oc_ts_anx_day_task d
         WHERE period_year = 2026 AND period_month = 7)
 WHERE rn <= 15;

PROMPT ============================================================
PROMPT [5/5] The three totals must agree
PROMPT ============================================================

-- The levels roll up from one grain, so a difference between them is a bug in
-- the views and not a rounding artefact.
SELECT 'day_task' AS level_, COUNT(*) AS rows_, SUM(total_hours) AS hours
  FROM v_oc_ts_anx_day_task WHERE period_year = 2026 AND period_month = 7
UNION ALL
SELECT 'day',      COUNT(*), SUM(total_hours)
  FROM v_oc_ts_anx_day      WHERE period_year = 2026 AND period_month = 7
UNION ALL
SELECT 'month',    COUNT(*), SUM(total_hours)
  FROM v_oc_ts_anx_month    WHERE period_year = 2026 AND period_month = 7;

PROMPT
PROMPT ROWS falls as the grain coarsens; HOURS must be identical on all three.
