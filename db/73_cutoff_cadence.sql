--==============================================================
-- time/73_cutoff_cadence.sql
-- O2C Timesheet Module — each cut-off runs at its own cadence
--
-- Three cut-offs matter to time, and only one of them is a moving target:
--
--   WEEKLY    17:00 LOCAL to each worker's country. There is no single instant
--             to fire at, so it needs frequent passes -- every 15 minutes.
--   DELIVERY  a DATE on the period. One event, once.
--   PAYROLL   a DATE per country. One event, then a watch while corrections
--             come in.
--
-- OC_TIME_CUTOFF_JOB ran WEEKLY AND DELIVERY together every 15 minutes, which
-- is 96 delivery passes a day for an event that happens once a month. Each pass
-- writes an OC_TIME_SYNC_JOB row, so the job log fills with runs that found
-- nothing and the ones that did something are lost among them. That is the
-- visible cost; the conceptual one is that a monthly event was being polled.
--
-- SO THE CADENCES SPLIT:
--
--   OC_TIME_CUTOFF_JOB        every 15 min   weekly only
--   OC_TIME_DAILY_CUTOFF_JOB  daily 02:30    delivery when due, then salary
--
-- DELIVERY RUNS ONCE, and "once" is enforced against OC_TIME_SYNC_JOB rather
-- than a new flag: a period whose DeliveryDefaulting job already succeeded is
-- skipped. The job table already records exactly this and a second bookkeeping
-- column would be one more thing to keep true.
--
-- PAYROLL DOES NOT RUN ONCE, and that is deliberate rather than an oversight.
-- run_salary_stopping releases a hold when the weeks behind it are submitted,
-- and that release only happens on a run. Fire it once on the cut-off date and
-- somebody who fixes their timesheet the next morning stays held for ever.
-- V_OC_TIME_SALARY_DUE therefore keeps a period in scope while anything is
-- still held -- first run on the cut-off, then a daily watch that costs nothing
-- once everyone is released.
--
-- Idempotent. Depends on: time/47, 48, 72. Supersedes 72's scheduling; its
-- view and oc_time_run_salary_due are still used.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_RUN_SALARY_DUE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'OC_TIME_RUN_SALARY_DUE is missing. Run 72 first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] Which periods still owe a delivery pass
PROMPT ============================================================

-- Past its delivery cut-off and never successfully defaulted. A view so the
-- answer to "why has this month not been delivery-defaulted" is a query.
--
-- OPEN PERIODS ONLY, same as before: a week inside a closed month is corrected
-- by a retro adjustment (RULE-019), never defaulted now. A month that closes
-- before its delivery cut-off arrives is therefore never delivery-defaulted,
-- which is correct and worth knowing.
CREATE OR REPLACE VIEW v_oc_time_delivery_due AS
SELECT p.period_id,
       p.period_name,
       p.status,
       p.delivery_cutoff,
       TRUNC(SYSDATE) - p.delivery_cutoff AS days_since_cutoff
  FROM oc_time_period p
 WHERE p.status = 'Open'
   AND p.delivery_cutoff IS NOT NULL
   AND TRUNC(SYSDATE) > p.delivery_cutoff
   AND NOT EXISTS (SELECT 1 FROM oc_time_sync_job j
                    WHERE j.period_id = p.period_id
                      AND j.job_type  = 'DeliveryDefaulting'
                      AND j.job_status = 'Success');

COLUMN period_name FORMAT A11
SELECT period_name, status,
       TO_CHAR(delivery_cutoff,'DD-Mon-YY') AS delivery_cutoff,
       days_since_cutoff
  FROM v_oc_time_delivery_due
 ORDER BY delivery_cutoff;

PROMPT
PROMPT Empty is the normal state: every open period past its delivery cut-off
PROMPT has already had its one pass.

PROMPT ============================================================
PROMPT [2/5] OC_TIME_RUN_DELIVERY_DUE
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_run_delivery_due(
  p_actor IN VARCHAR2 DEFAULT 'DELIVERY_JOB')
IS
  v_job  NUMBER;
  v_runs NUMBER := 0;
BEGIN
  FOR p IN (SELECT period_id, period_name, delivery_cutoff
              FROM v_oc_time_delivery_due ORDER BY delivery_cutoff)
  LOOP
    BEGIN
      -- p_as_of is the CUT-OFF, not today. The engine computes lateness from
      -- it, and passing today would judge a week against a date days after the
      -- deadline it actually missed.
      v_job := oc_time_pkg.run_delivery_defaulting(p.period_id,
                                                   p.delivery_cutoff, p_actor);
      v_runs := v_runs + 1;
      DBMS_OUTPUT.PUT_LINE('  delivery ' || RPAD(p.period_name, 10)
                        || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  delivery ' || RPAD(p.period_name, 10)
                        || ' FAILED ' || SUBSTR(SQLERRM, 1, 120));
    END;
  END LOOP;

  IF v_runs = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No period owes a delivery pass.');
  END IF;
END oc_time_run_delivery_due;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/5] The 15-minute job drops delivery
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_run_cutoffs(
  p_as_of IN DATE     DEFAULT SYSDATE,
  p_actor IN VARCHAR2 DEFAULT 'CUTOFF_JOB')
IS
  v_job   NUMBER;
  v_weeks NUMBER := 0;
BEGIN
  -- WEEKLY ONLY as of 18-Aug-2026. Delivery moved to the daily job: it is a
  -- date on the period, and running it 96 times a day filled the job log with
  -- passes that found nothing.
  --
  -- Every OPEN period, not just "the" open one -- RULE-017 is relaxed and more
  -- than one month can be open, so a single get_open_period_id would silently
  -- skip the others. Closed periods are excluded: a week inside a closed month
  -- is corrected by a retro adjustment (RULE-019), never defaulted now.
  FOR p IN (SELECT period_id, period_name
              FROM oc_time_period
             WHERE status = 'Open'
             ORDER BY start_date)
  LOOP
    BEGIN
      v_job := oc_time_pkg.run_weekly_defaulting(p.period_id, p_as_of, p_actor);
      v_weeks := v_weeks + 1;
      DBMS_OUTPUT.PUT_LINE('  weekly   ' || RPAD(p.period_name, 10)
                        || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      -- One period failing must not stop the rest.
      DBMS_OUTPUT.PUT_LINE('  weekly   ' || RPAD(p.period_name, 10)
                        || ' FAILED ' || SUBSTR(SQLERRM, 1, 100));
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(v_weeks || ' weekly pass(es) over open periods');
END oc_time_run_cutoffs;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] The two schedules
PROMPT ============================================================

DECLARE
  PROCEDURE drop_if(p_name VARCHAR2) IS
    v_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_n FROM user_scheduler_jobs WHERE job_name = p_name;
    IF v_n > 0 THEN
      DBMS_SCHEDULER.DROP_JOB(p_name, force => TRUE);
      DBMS_OUTPUT.PUT_LINE('dropped ' || p_name);
    END IF;
  END drop_if;
BEGIN
  drop_if('OC_TIME_CUTOFF_JOB');
  -- 72's job is folded into the daily one below rather than left beside it:
  -- two daily jobs doing halves of one thing is a cadence nobody can read.
  drop_if('OC_TIME_SALARY_JOB');

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'OC_TIME_CUTOFF_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN oc_time_run_cutoffs(SYSDATE, ''CUTOFF_JOB''); END;',
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=15',
    start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata',
    enabled         => TRUE,
    comments        => 'RULE-006 weekly defaulting ONLY. Every 15 minutes '
                    || 'because the cut-off is 17:00 LOCAL to each worker and '
                    || 'that is a different instant per country.');
  DBMS_OUTPUT.PUT_LINE('OC_TIME_CUTOFF_JOB recreated - weekly only, 15 min');

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'OC_TIME_DAILY_CUTOFF_JOB',
    job_type        => 'PLSQL_BLOCK',
    -- Delivery first: a week it defaults is one salary stopping must NOT hold,
    -- because DEFAULTED_BY is 'MANAGER' there (RULE-016). Running salary first
    -- would reach the same answer -- it filters on 'EMPLOYEE' -- but the order
    -- states the dependency rather than relying on the filter.
    job_action      => 'BEGIN oc_time_run_delivery_due(''DAILY_CUTOFF''); '
                    || 'oc_time_run_salary_due(''DAILY_CUTOFF''); END;',
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=30;BYSECOND=0',
    -- START_DATE carries the timezone the interval resolves against and the
    -- database is UTC, so without this BYHOUR=2 means 07:30 IST. db/48 records
    -- the same trap.
    start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata',
    enabled         => TRUE,
    comments        => 'RULE-007 delivery defaulting (once per period, on its '
                    || 'cut-off) and PROC-007 salary stopping (from each '
                    || 'country''s payroll cut-off, while anything is held).');
  DBMS_OUTPUT.PUT_LINE('OC_TIME_DAILY_CUTOFF_JOB created - daily 02:30 IST');
END;
/

COLUMN job_name FORMAT A26
COLUMN next_run FORMAT A30
COLUMN repeat_interval FORMAT A34
SELECT job_name, enabled, state,
       TO_CHAR(next_run_date, 'DD-Mon-YY HH24:MI') AS next_run,
       repeat_interval
  FROM user_scheduler_jobs
 WHERE job_name LIKE 'OC_TIME%'
 ORDER BY job_name;

PROMPT ============================================================
PROMPT [5/5] Dry run
PROMPT ============================================================

BEGIN
  oc_time_run_delivery_due('SETUP_DRY_RUN');
  oc_time_run_salary_due('SETUP_DRY_RUN');
END;
/

PROMPT
PROMPT The cadences now match the events:
PROMPT
PROMPT   weekly    every 15 min   17:00 local, a different instant per country
PROMPT   delivery  once           on the period's delivery cut-off date
PROMPT   payroll   daily          from each country's payroll cut-off, and it
PROMPT             keeps looking only while somebody is still held
PROMPT
PROMPT Payroll is the one that is NOT once, on purpose: the release happens on a
PROMPT run, so a single pass would leave anybody who corrects their timesheet
PROMPT the next day held for ever.
