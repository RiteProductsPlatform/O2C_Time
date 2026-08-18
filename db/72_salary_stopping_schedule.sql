--==============================================================
-- time/72_salary_stopping_schedule.sql
-- O2C Timesheet Module — salary stopping runs itself
--
-- The last manual link in the chain. It was left manual deliberately, until the
-- figures could be trusted: held amounts were computed from 16-hour days while
-- allocations were duplicated, and the cut-off was ours rather than the payroll
-- configuration's. Both are settled, and the 17-Aug run produced numbers that
-- reconcile -- JUN 119 held, JUL 124 held, AUG released because its cut-off is
-- the 30th -- so it can be trusted to run on its own.
--
-- IT CANNOT REUSE OC_TIME_CUTOFF_JOB'S PERIOD LOOP, and that is the whole
-- design question. That job iterates
--
--     WHERE status = 'Open'
--
-- which is right for defaulting: a week in a closed month is corrected by a
-- retro adjustment, never defaulted now. Salary stopping is the opposite case.
-- It runs at the PAYROLL cut-off, which lands after month end -- 28-Jun for
-- June, 26-Jul for July -- by which time the period is usually Closed. Reusing
-- that loop would mean the job could only ever act on months whose payroll
-- deadline had not yet arrived, which is exactly backwards.
--
-- SO THE SELECTION IS THE CUT-OFF ITSELF, per country, from
-- V_OC_TIME_PAYROLL_WINDOW -- the same view the job already judges each person
-- against. Two clauses:
--
--   * a cut-off passed in the last 90 days. Catches each month the day after
--     its deadline and keeps re-running while corrections come in.
--   * any period still holding somebody, however old. The procedure releases a
--     hold once the weeks are submitted, and that release only happens if the
--     period is still being visited. Dropping an old month the moment it left
--     the window would strand its holds Held for ever.
--
-- RE-RUNNING IS SAFE, which is what makes a daily schedule reasonable. The
-- MERGE updates only rows still 'Held', so a hold released by hand stays
-- released; and the auto-release at the end reopens nothing.
--
-- DAILY, NOT EVERY 15 MINUTES. The weekly cut-off is 17:00 LOCAL and needs
-- frequent passes to catch each timezone; a payroll cut-off is a DATE, so the
-- earliest meaningful moment is the start of the following day and anything
-- more often is repetition.
--
-- Idempotent. Depends on: time/09, 53, 66.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views
   WHERE view_name = 'V_OC_TIME_PAYROLL_WINDOW';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'V_OC_TIME_PAYROLL_WINDOW is missing. Run 66 first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] Which periods are due, and why
PROMPT ============================================================

-- A view so "why did this month get a salary run today" has an answer that can
-- be queried, rather than one that has to be reconstructed from the job log.
CREATE OR REPLACE VIEW v_oc_time_salary_due AS
SELECT p.period_id,
       p.period_name,
       p.status                                  AS period_status,
       MAX(w.payroll_cutoff)                     AS payroll_cutoff,
       COUNT(DISTINCT w.country)                 AS countries,
       (SELECT COUNT(*) FROM oc_ts_salary_hold h
         WHERE h.period_id = p.period_id
           AND h.salary_status = 'Held')         AS open_holds,
       CASE
         WHEN MAX(w.payroll_cutoff) >= TRUNC(SYSDATE) - 90 THEN 'cut-off recent'
         ELSE 'still holding somebody'
       END                                       AS due_because
  FROM oc_time_period p
  JOIN v_oc_time_payroll_window w ON w.period_id = p.period_id
 WHERE w.cutoff_passed = 'Y'
   AND (w.payroll_cutoff >= TRUNC(SYSDATE) - 90
     OR EXISTS (SELECT 1 FROM oc_ts_salary_hold h
                 WHERE h.period_id = p.period_id
                   AND h.salary_status = 'Held'))
 GROUP BY p.period_id, p.period_name, p.status, p.start_date;

COLUMN period_name FORMAT A11
COLUMN due_because FORMAT A24
SELECT period_name, period_status,
       TO_CHAR(payroll_cutoff,'DD-Mon-YY') AS cutoff,
       countries, open_holds, due_because
  FROM v_oc_time_salary_due
 ORDER BY payroll_cutoff;

PROMPT
PROMPT A period NOT listed here has either no passed cut-off or nothing left to
PROMPT do. AUG-2026 should be absent until the 31st -- its cut-off is the 30th.

PROMPT ============================================================
PROMPT [2/4] OC_TIME_RUN_SALARY_DUE
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_run_salary_due(
  p_actor IN VARCHAR2 DEFAULT 'SALARY_JOB')
IS
  v_job  NUMBER;
  v_runs NUMBER := 0;
BEGIN
  FOR p IN (SELECT period_id, period_name FROM v_oc_time_salary_due
             ORDER BY payroll_cutoff)
  LOOP
    BEGIN
      v_job := oc_time_pkg.run_salary_stopping(p.period_id, p_actor);
      v_runs := v_runs + 1;
      DBMS_OUTPUT.PUT_LINE('  salary  ' || RPAD(p.period_name, 10)
                        || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      -- One period must not stop the rest, exactly as oc_time_run_cutoffs
      -- does. A month with a misconfigured cut-off should not hold up the
      -- months that are fine, and holding nobody by accident is the failure
      -- that matters here.
      DBMS_OUTPUT.PUT_LINE('  salary  ' || RPAD(p.period_name, 10)
                        || ' FAILED ' || SUBSTR(SQLERRM, 1, 120));
    END;
  END LOOP;

  IF v_runs = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No period is due: no payroll cut-off has passed '
                      || 'recently and nothing is still held.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(v_runs || ' period(s) processed');
  END IF;
END oc_time_run_salary_due;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] The schedule
PROMPT ============================================================

DECLARE
  v_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM user_scheduler_jobs
   WHERE job_name = 'OC_TIME_SALARY_JOB';
  IF v_exists > 0 THEN
    DBMS_SCHEDULER.DROP_JOB('OC_TIME_SALARY_JOB', force => TRUE);
  END IF;

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'OC_TIME_SALARY_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN oc_time_run_salary_due(''SALARY_JOB''); END;',
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=30;BYSECOND=0',
    -- START_DATE CARRIES THE TIMEZONE THE INTERVAL RESOLVES AGAINST, and the
    -- database is UTC (DBTIMEZONE +00:00). Without the explicit zone, BYHOUR=2
    -- means 02:00 UTC -- 07:30 in India -- which is the same trap db/48 records
    -- for the cut-off job. Pinned to Kolkata so 02:30 means 02:30 there.
    start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata',
    enabled         => TRUE,
    comments        => 'PROC-007 salary stopping. Daily, because a payroll '
                    || 'cut-off is a DATE -- unlike the weekly cut-off, which '
                    || 'is 17:00 local and needs 15-minute passes.');
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SALARY_JOB created, daily at 02:30 IST');
END;
/

COLUMN job_name FORMAT A22
COLUMN next_run FORMAT A34
SELECT job_name, enabled, state,
       TO_CHAR(next_run_date, 'DD-Mon-YY HH24:MI TZR') AS next_run,
       repeat_interval
  FROM user_scheduler_jobs
 WHERE job_name IN ('OC_TIME_CUTOFF_JOB','OC_TIME_SALARY_JOB')
 ORDER BY job_name;

PROMPT ============================================================
PROMPT [4/4] Dry run against today
PROMPT ============================================================

BEGIN
  oc_time_run_salary_due('SETUP_DRY_RUN');
END;
/

COLUMN period_name FORMAT A11
SELECT p.period_name,
       SUM(CASE WHEN h.salary_status = 'Held'     THEN 1 ELSE 0 END) AS held,
       SUM(CASE WHEN h.salary_status = 'Released' THEN 1 ELSE 0 END) AS released,
       SUM(CASE WHEN h.salary_status = 'Held' THEN h.default_hours ELSE 0 END)
         AS hours_held
  FROM oc_ts_salary_hold h
  JOIN oc_time_period p ON p.period_id = h.period_id
 GROUP BY p.period_name, p.start_date
 ORDER BY p.start_date;

PROMPT
PROMPT The job now runs itself every morning. Nothing else in the chain is
PROMPT manual: the 15-minute job defaults weeks at each country's 17:00, this
PROMPT one holds pay the day after each country's payroll cut-off, and both
PROMPT release automatically when the work is submitted.
PROMPT
PROMPT STILL WORTH CONFIRMING WITH FINANCE, now that it runs unattended:
PROMPT   * contractors ARE held (RA-012 retired on instruction). CRI0398 and
PROMPT     CRI0406 appear in the June and July runs.
PROMPT   * the release window is 60 days, read from the payroll configuration.
