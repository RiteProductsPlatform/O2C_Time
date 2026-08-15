--==============================================================
-- time/48_cutoff_local_time.sql
-- O2C Timesheet Module — 17:00 means 17:00 where the person is
--
-- 47 schedules the cut-off at 17:05 Asia/Kolkata for everybody. That is right
-- only while everybody sits in India. For anyone else it is wrong twice over:
-- someone in London is defaulted at 11:35 their time, with five and a half
-- hours of their working day still ahead of them, and someone in California is
-- defaulted at 03:35 the same morning -- before the day the timesheet is for
-- has even started.
--
-- THE PIECES WERE ALREADY THERE AND WERE NEVER JOINED UP
--   OC_TIME_WORKER.BASE_COUNTRY is commented, in the DDL, "drives cut-off
--   local time". OC_TIME_CONFIG has SCOPE_KEY with UK (CONFIG_NAME,
--   SCOPE_KEY), so a per-country cut-off has always been storable. CFG-010 in
--   the metadata says the job runs per country. Only the GLOBAL row was ever
--   written and nothing ever read a country.
--
-- WHAT CHANGES
--   The cut-off moment stops being a DATE in database time and becomes an
--   instant in the employee's own zone. oc_time_week_timing resolves the
--   worker's country, looks up that country's cut-off day, time and zone --
--   falling back to GLOBAL where there is no country row -- and compares in
--   UTC so the answer does not depend on where the database happens to live.
--
--   The job then has to run more often than once a day, because 17:00 local
--   happens at a different instant in every zone. Every 15 minutes covers
--   offsets on the hour, the half hour and the quarter (Nepal +05:45, Chatham
--   +12:45), and bounds the lag at a quarter of an hour.
--
-- ASSUMPTION, worth confirming: BASE_COUNTRY decides, not DEPUTED_COUNTRY.
--   The DDL comment says base drives the cut-off and this follows it. The
--   argument the other way is real -- somebody deputed to New York is
--   physically working New York hours -- so if that is wanted it is one NVL in
--   oc_time_worker_zone below, and nothing else changes.
--
-- Idempotent. Depends on: time/47
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/6] What countries are actually in the worker data?
PROMPT ============================================================

-- Printed before anything is seeded, because BASE_COUNTRY arrives from Fusion
-- as free text and nothing here knows whether it says 'IN', 'India' or
-- 'IN - India'. The seed in [2] is a starting set; this list is what has to be
-- covered, and anything uncovered falls back to GLOBAL rather than breaking.
COLUMN base_country FORMAT A34
SELECT NVL(base_country, '(null)') AS base_country, COUNT(*) AS workers
  FROM oc_time_worker
 WHERE status = 'Active'
 GROUP BY base_country
 ORDER BY 2 DESC;

PROMPT
PROMPT Every value above needs a ts_cutoff_tz row in [2] keyed on EXACTLY that
PROMPT string. Anything missing quietly uses the GLOBAL zone, which is the safe
PROMPT failure but is still the wrong time for that person.

PROMPT ============================================================
PROMPT [2/6] Per-country cut-off zones
PROMPT ============================================================

DECLARE
  PROCEDURE cfg(p_name VARCHAR2, p_scope VARCHAR2, p_value VARCHAR2,
                p_desc VARCHAR2) IS
  BEGIN
    MERGE INTO oc_time_config c
    USING (SELECT p_name AS n, p_scope AS s FROM dual) x
       ON (c.config_name = x.n AND c.scope_key = x.s)
     WHEN MATCHED THEN UPDATE
          SET c.config_value = p_value, c.updated_by = 'CUTOFF_TZ',
              c.updated_on = SYSTIMESTAMP
     WHEN NOT MATCHED THEN
          INSERT (config_name, config_type, config_value, scope_key,
                  description, created_by)
          -- 'business', not 'STRING'. CHK_OC_TCFG_TYPE admits only
          -- business / feature_flag / timeout / endpoint.
          VALUES (p_name, 'business', p_value, p_scope, p_desc, 'CUTOFF_TZ');
  END cfg;
BEGIN
  -- GLOBAL is the fallback and must exist. It is what a worker with no
  -- country, or a country nobody has mapped, gets.
  cfg('ts_cutoff_tz', 'GLOBAL', 'Asia/Kolkata',
      'Fallback cut-off zone where the worker has no mapped country.');

  -- IANA names, not fixed offsets. 'Europe/London' knows about British Summer
  -- Time; '+00:00' does not, and would drift by an hour for half the year --
  -- silently, and only for the people it affects.
  cfg('ts_cutoff_tz', 'IN',             'Asia/Kolkata',      'India');
  cfg('ts_cutoff_tz', 'India',          'Asia/Kolkata',      'India (long form)');
  cfg('ts_cutoff_tz', 'GB',             'Europe/London',     'United Kingdom');
  cfg('ts_cutoff_tz', 'United Kingdom', 'Europe/London',     'United Kingdom (long form)');
  cfg('ts_cutoff_tz', 'US',             'America/New_York',  'United States (east coast default)');
  cfg('ts_cutoff_tz', 'United States',  'America/New_York',  'United States (long form)');
  cfg('ts_cutoff_tz', 'AE',             'Asia/Dubai',        'United Arab Emirates');
  cfg('ts_cutoff_tz', 'SG',             'Asia/Singapore',    'Singapore');
  cfg('ts_cutoff_tz', 'AU',             'Australia/Sydney',  'Australia (east)');
  cfg('ts_cutoff_tz', 'CA',             'America/Toronto',   'Canada (east)');
  cfg('ts_cutoff_tz', 'DE',             'Europe/Berlin',     'Germany');
  cfg('ts_cutoff_tz', 'PH',             'Asia/Manila',       'Philippines');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('cut-off zones seeded');
END;
/

PROMPT
PROMPT A COUNTRY MAY ALSO OVERRIDE THE DAY AND TIME, not just the zone. The
PROMPT unique key is (CONFIG_NAME, SCOPE_KEY), so this already works:
PROMPT
PROMPT   ts_cutoff_day  / scope_key 'GB' / 'Tuesday'
PROMPT   ts_cutoff_time / scope_key 'GB' / '18:00'
PROMPT
PROMPT Nothing is seeded that way -- every country uses the GLOBAL Monday 17:00
PROMPT until somebody says otherwise.

PROMPT ============================================================
PROMPT [3/6] OC_TIME_WORKER_ZONE — where is this person, for cut-off purposes
PROMPT ============================================================

CREATE OR REPLACE FUNCTION oc_time_worker_zone(p_employee_id IN VARCHAR2)
RETURN VARCHAR2
IS
  v_country oc_time_worker.base_country%TYPE;
  v_tz      VARCHAR2(64);
BEGIN
  -- BASE_COUNTRY, per the DDL comment. Change this to
  -- NVL(deputed_country, base_country) if a deputed worker should follow the
  -- cut-off of where they are sitting rather than where they are employed.
  SELECT base_country INTO v_country
    FROM oc_time_worker WHERE employee_id = p_employee_id;

  BEGIN
    SELECT config_value INTO v_tz
      FROM oc_time_config
     WHERE config_name = 'ts_cutoff_tz'
       AND scope_key   = v_country;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    SELECT config_value INTO v_tz
      FROM oc_time_config
     WHERE config_name = 'ts_cutoff_tz' AND scope_key = 'GLOBAL';
  END;

  RETURN v_tz;
EXCEPTION WHEN NO_DATA_FOUND THEN
  -- No worker, or not even a GLOBAL row. Asia/Kolkata rather than NULL: a null
  -- zone would make FROM_TZ raise and take the whole defaulting run down for
  -- one unmapped person.
  RETURN 'Asia/Kolkata';
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/6] OC_TIME_WEEK_TIMING — the cut-off as a local instant
PROMPT ============================================================

CREATE OR REPLACE FUNCTION oc_time_week_timing(
  p_ts_week_id IN NUMBER,
  p_as_of      IN DATE DEFAULT NULL) RETURN VARCHAR2
IS
  v_end     DATE;
  v_emp     VARCHAR2(50);
  v_country oc_time_worker.base_country%TYPE;
  v_day     VARCHAR2(10);
  v_time    VARCHAR2(5);
  v_tz      VARCHAR2(64);
  v_due     DATE;
  v_due_tz  TIMESTAMP WITH TIME ZONE;
  v_now_tz  TIMESTAMP WITH TIME ZONE;
BEGIN
  SELECT w.week_end, w.employee_id, wk.base_country
    INTO v_end, v_emp, v_country
    FROM oc_ts_week      w
    JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
   WHERE w.ts_week_id = p_ts_week_id;

  -- The country's own cut-off day and time if it has them, GLOBAL otherwise,
  -- resolved INDEPENDENTLY per setting.
  --
  -- This was one clever query using KEEP (DENSE_RANK FIRST ...) over both
  -- names at once. That ranks across the whole group, so a country overriding
  -- only the DAY would rank its single row first and the GLOBAL TIME would
  -- drop out as NULL -- a partial override silently losing the other half.
  SELECT NVL((SELECT config_value FROM oc_time_config
               WHERE config_name = 'ts_cutoff_day' AND scope_key = v_country),
             (SELECT config_value FROM oc_time_config
               WHERE config_name = 'ts_cutoff_day' AND scope_key = 'GLOBAL')),
         NVL((SELECT config_value FROM oc_time_config
               WHERE config_name = 'ts_cutoff_time' AND scope_key = v_country),
             (SELECT config_value FROM oc_time_config
               WHERE config_name = 'ts_cutoff_time' AND scope_key = 'GLOBAL'))
    INTO v_day, v_time
    FROM dual;

  v_tz := oc_time_worker_zone(v_emp);

  -- NEXT_DAY gives the first named day STRICTLY AFTER the week end, so a week
  -- ending Sunday is due the following Monday.
  v_due := NEXT_DAY(v_end, NVL(v_day, 'MONDAY'))
         + NVL(TO_NUMBER(SUBSTR(v_time, 1, 2)), 17) / 24
         + NVL(TO_NUMBER(SUBSTR(v_time, 4, 2)),  0) / 1440;

  -- THE POINT OF THIS SCRIPT. v_due is a wall-clock reading with no zone --
  -- "Monday 17:00" -- and FROM_TZ says whose Monday 17:00 it is. Compared in
  -- UTC so the answer does not depend on where the database sits, which
  -- matters because ATP runs UTC while everybody using it does not.
  v_due_tz := FROM_TZ(CAST(v_due AS TIMESTAMP), v_tz);
  v_now_tz := CASE
                WHEN p_as_of IS NULL THEN SYSTIMESTAMP
                -- A passed as-of is database time, which is what the
                -- defaulting job hands over when it replays a date.
                ELSE FROM_TZ(CAST(p_as_of AS TIMESTAMP), DBTIMEZONE)
              END;

  RETURN CASE WHEN SYS_EXTRACT_UTC(v_now_tz) > SYS_EXTRACT_UTC(v_due_tz)
              THEN 'PastCutoff' ELSE 'WithinCutoff' END;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    -- A week that has not started, or a worker row that is gone. A submission
    -- cannot be late before its deadline exists.
    RETURN 'WithinCutoff';
  WHEN OTHERS THEN
    -- An unrecognised zone name raises ORA-01882. Returning WithinCutoff means
    -- a misconfigured country delays a default; the alternative is defaulting
    -- somebody early on bad configuration, and that holds their salary.
    RETURN 'WithinCutoff';
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [5/6] The job runs every 15 minutes, not once a day
PROMPT ============================================================

-- 17:00 local is a different instant in every zone, so a single daily firing
-- can only ever be right for one of them. Every 15 minutes covers offsets on
-- the hour, the half hour and the quarter, and bounds how late a default is by
-- a quarter of an hour.
--
-- The run is cheap when there is nothing to do: it looks for unsubmitted weeks
-- whose end date has passed, and asks the timing function about those only.
DECLARE
  v_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM user_scheduler_jobs
   WHERE job_name = 'OC_TIME_CUTOFF_JOB';
  IF v_exists > 0 THEN
    DBMS_SCHEDULER.DROP_JOB('OC_TIME_CUTOFF_JOB', force => TRUE);
  END IF;

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'OC_TIME_CUTOFF_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN oc_time_run_cutoffs(SYSDATE, ''CUTOFF_JOB''); END;',
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=15',
    start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata',
    enabled         => TRUE,
    comments        => 'RULE-006/RULE-007 defaulting. Every 15 minutes because '
                    || 'the cut-off is 17:00 LOCAL to each worker and that is a '
                    || 'different instant per country.');
  DBMS_OUTPUT.PUT_LINE('OC_TIME_CUTOFF_JOB recreated at 15-minute intervals');
END;
/

PROMPT ============================================================
PROMPT [6/6] Verification
PROMPT ============================================================

COLUMN employee_id FORMAT A12
COLUMN country     FORMAT A16
COLUMN zone        FORMAT A20
COLUMN due_local   FORMAT A28
PROMPT --- when is each worker's most recent unsubmitted week actually due
SELECT * FROM (
  SELECT w.employee_id,
         NVL(wk.base_country,'(none)')          AS country,
         oc_time_worker_zone(w.employee_id)     AS zone,
         TO_CHAR(w.week_end,'DD-MON')           AS week_ends,
         oc_time_week_timing(w.ts_week_id)      AS timing
    FROM oc_ts_week      w
    JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
    JOIN oc_time_period  p  ON p.period_id    = w.period_id
   WHERE p.status = 'Open' AND w.submission_status = 'NotYetSubmitted'
   ORDER BY w.week_end DESC, w.employee_id)
 WHERE ROWNUM <= 12;

PROMPT
PROMPT --- the schedule
COLUMN repeat_interval FORMAT A28
COLUMN next_run        FORMAT A34
SELECT enabled, state, repeat_interval,
       TO_CHAR(next_run_date,'DY DD-MON HH24:MI:SS TZR') AS next_run
  FROM user_scheduler_jobs WHERE job_name = 'OC_TIME_CUTOFF_JOB';

PROMPT
PROMPT --- prove the zone actually changes the answer
DECLARE
  v_due  DATE := NEXT_DAY(TRUNC(SYSDATE) - 7, 'MONDAY') + 17/24;
BEGIN
  DBMS_OUTPUT.PUT_LINE('A cut-off of "Monday 17:00" is these instants in UTC:');
  FOR z IN (SELECT scope_key, config_value AS tz FROM oc_time_config
             WHERE config_name = 'ts_cutoff_tz' AND scope_key <> 'GLOBAL'
             ORDER BY scope_key) LOOP
    BEGIN
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(z.scope_key,16) || RPAD(z.tz,20)
        || TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(CAST(v_due AS TIMESTAMP), z.tz)),
                   'DD-MON HH24:MI') || ' UTC');
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(z.scope_key,16) || z.tz
        || '  *** not a valid zone name ***');
    END;
  END LOOP;
END;
/

PROMPT
PROMPT Those instants are up to a day apart. That spread is exactly why the job
PROMPT cannot fire once a day, and why any row marked "not a valid zone name"
PROMPT must be fixed -- that country silently falls back to WithinCutoff and
PROMPT never defaults at all.
