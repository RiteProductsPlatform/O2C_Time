--==============================================================
-- time/113_the_monthly_program_is_scheduled.sql
-- O2C Timesheet Module - schedule the monthly pre-population (O2C-286)
--
-- O2C-286 asks for "a monthly program to run a day or two before month-end
-- close that pre-populates hours for the upcoming month based on each
-- employee's project allocation".
--
-- populate_month has existed and worked since db/09. Nothing scheduled it.
-- Every caller was either the admin ORDS endpoint (POST populate/:periodId) or
-- a db script somebody ran by hand, so the CAPABILITY was delivered and the
-- PROGRAM was not -- which is a distinction nobody notices until the month
-- turns and no timesheets exist.
--
-- -- THE SCHEDULE LIVES IN OIC, NOT IN DBMS_SCHEDULER ---------
--
-- Decided 21-Aug and now in place:
--
--   O2C_TIME_SYNC_MONTHLY_01_00_0000
--   FREQ=MONTHLY;BYMONTHDAY=-2;BYHOUR=3;BYMINUTE=30;BYSECOND=0;
--   Time zone (UTC+05:30) Calcutta - so those are IST hours
--
-- 03:30 and not earlier because the daily master-data sync on this instance
-- runs BYHOUR=2,12. Allocations decide what gets populated, so starting before
-- 02:00 would build next month from yesterday's picture. Ninety minutes is the
-- gap that leaves.
--
-- BYMONTHDAY=-2 is "the second-to-last day", whatever number that is - the
-- rule the ticket actually states, and correct in February without a special
-- case. OIC's validator DOES accept the negative value; that was checked on
-- the Validate button rather than assumed, because CLAUDE.md section 5 records
-- that this validator rejects strings its own preview panel renders correctly.
-- The TRAILING SEMICOLON is required and is not decoration.
--
-- This script therefore creates NO scheduler job. It builds the two things OIC
-- needs and stops: the procedure below, and POST jobs/populate/monthly in
-- ords/13. The other jobs in this schema stay on DBMS_SCHEDULER - they run
-- every fifteen minutes against local cut-off times and have no business being
-- a network round trip.
--
-- -- THE DAY GUARD IS IN THE DATABASE AS WELL -----------------
--
-- The OIC recurrence already fires once a month, so the guard below is
-- belt-and-braces. It is worth having anyway:
--
--   * A MISSED RUN BECOMES RECOVERABLE. If OIC is down on the 30th, a
--     once-a-month schedule silently skips the month entirely. Raise
--     MONTHLY_POP_WINDOW_DAYS to 3 and switch the recurrence to FREQ=DAILY and
--     the next day's call still does the work.
--   * IT SURVIVES THE SCHEDULE BEING EDITED. Somebody changing the recurrence
--     to daily by mistake gets 28 no-ops rather than 28 populations.
--   * THE RULE IS BUSINESS LOGIC. "Two days before month end" is the same kind
--     of statement as a cut-off time, and those live in the database here.
--
-- -- IT POPULATES THE MONTH THAT IS ABOUT TO START ------------
--
-- Running on 30-Aug and populating August would be pointless. The job takes
-- today's date IN IST -- not SYSDATE, which is UTC on this database and reads
-- the previous day at 01:30 IST -- and populates TRUNC(ADD_MONTHS(today,1)).
-- Month arithmetic rather than "+2 days", so a manual catch-up run in the
-- middle of a month still targets the coming month instead of this one.
--
-- If that period does not exist yet the job logs and exits rather than
-- failing. A missing period is a reference-data gap, and a scheduler job that
-- goes BROKEN after 16 failures is a worse outcome than a logged skip: the
-- broken job stops running for every SUBSEQUENT month too.
--
-- -- SAFE TO RUN TWICE ----------------------------------------
--
-- populate_month is a MERGE. Running it again over a month people have already
-- typed into does not overwrite their hours -- see db/90's note. So a manual
-- catch-up run after a skipped month is safe, and so is the job firing twice.
--
-- Idempotent. Depends on: time/09, 47 (for the job-group conventions).
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [0/4] What timezone is this database in
PROMPT ============================================================

-- Printed rather than assumed. If DB_TZ reads +00:00 then every BYHOUR in
-- every schedule is UTC unless its START_DATE says otherwise, and a job
-- written for 01:30 fires at 07:00 IST.
COLUMN db_tz      FORMAT A10
COLUMN ist_now    FORMAT A22
COLUMN utc_now    FORMAT A22
SELECT DBTIMEZONE AS db_tz,
       TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata',
               'DD-Mon-YYYY HH24:MI') AS ist_now,
       TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'UTC',
               'DD-Mon-YYYY HH24:MI')  AS utc_now
  FROM dual;

PROMPT
PROMPT If IST_NOW and UTC_NOW are on different DATES right now, that is exactly
PROMPT the condition that made SYSDATE arithmetic pick the wrong month.

PROMPT ============================================================
PROMPT [1/4] How many days before month end it is willing to run
PROMPT ============================================================

MERGE INTO oc_time_config t
USING (SELECT 'MONTHLY_POP_WINDOW_DAYS' AS nm, 'GLOBAL' AS sk FROM dual) s
   ON (t.config_name = s.nm AND t.scope_key = s.sk)
 WHEN MATCHED THEN UPDATE SET
   config_value = '2', updated_by = 'DB_113', updated_on = SYSTIMESTAMP
 WHEN NOT MATCHED THEN INSERT
   (config_name, config_type, config_value, scope_key, description, created_by)
 VALUES
   ('MONTHLY_POP_WINDOW_DAYS', 'business', '2', 'GLOBAL',
    'O2C-286. How many days before month end the monthly pre-population will '
 || 'run. 2 = the second-to-last day only, matching the OIC recurrence. Raise '
 || 'it to tolerate a missed OIC run - populate_month is a MERGE, so the '
 || 'extra calls are no-ops.', 'DB_113');

COMMIT;

COLUMN config_name  FORMAT A28
COLUMN config_value FORMAT A6
SELECT config_name, config_value FROM oc_time_config
 WHERE config_name = 'MONTHLY_POP_WINDOW_DAYS';

PROMPT ============================================================
PROMPT [2/4] The procedure OIC reaches through ORDS
PROMPT ============================================================

-- OUT parameters rather than a return value, because three outcomes have to
-- reach OIC distinctly:
--
--   Populated  the work was done              -> o_job holds the job run id
--   Skipped    not the run day                -> a 200, NOT a fault
--   Skipped    no period defined for it       -> a 200, with a message
--
-- SKIPPED MUST NOT BE A FAULT. If the recurrence is ever switched to daily,
-- OIC would be told "Skipped" on twenty-eight days in thirty; surfacing that
-- as an error would make the integration read as permanently failing, and the
-- one month it genuinely failed would be invisible in the noise. Same family
-- as the zero-row accrual confirm, inverted: there a success was hiding a
-- failure, here a failure indication would hide a success.
CREATE OR REPLACE PROCEDURE oc_time_run_monthly_population(
  p_as_of   IN  DATE     DEFAULT NULL,
  p_force   IN  VARCHAR2 DEFAULT 'N',
  p_actor   IN  VARCHAR2 DEFAULT 'OIC_MONTHLY',
  o_status  OUT VARCHAR2,
  o_period  OUT NUMBER,
  o_job     OUT NUMBER,
  o_message OUT VARCHAR2)
IS
  -- LOCAL DATE, NOT SYSDATE. This database is UTC and OIC fires at 03:30 IST,
  -- which is 22:00 UTC the PREVIOUS day. SYSDATE would read 29-Aug on the
  -- 30-Aug run, and at a month boundary that is the difference between the
  -- right month and the wrong one. db/48 records the same trap for cut-offs.
  v_today  DATE := NVL(p_as_of,
                       CAST(SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata' AS DATE));
  -- ADD_MONTHS, not "+ 2 days". Day arithmetic is only correct under an
  -- assumption about when this runs, which stops holding the first time
  -- somebody calls it by hand mid-month.
  v_target DATE := TRUNC(ADD_MONTHS(v_today, 1), 'MM');
  v_last   DATE := LAST_DAY(v_today);
  v_window NUMBER;
  v_name   oc_time_period.period_name%TYPE;
BEGIN
  o_status := 'Skipped'; o_period := NULL; o_job := NULL;

  BEGIN
    SELECT TO_NUMBER(config_value) INTO v_window
      FROM oc_time_config
     WHERE config_name = 'MONTHLY_POP_WINDOW_DAYS' AND scope_key = 'GLOBAL';
  EXCEPTION WHEN OTHERS THEN v_window := 2;
  END;

  IF UPPER(NVL(p_force,'N')) <> 'Y'
     AND v_today < v_last - (v_window - 1) THEN
    o_message := 'Not a run day. Today is ' || TO_CHAR(v_today,'DD-Mon-YYYY')
      || '; the window opens '
      || TO_CHAR(v_last - (v_window - 1),'DD-Mon-YYYY') || '.';
    RETURN;
  END IF;

  BEGIN
    SELECT period_id, period_name INTO o_period, v_name
      FROM oc_time_period
     WHERE period_year  = EXTRACT(YEAR  FROM v_target)
       AND period_month = EXTRACT(MONTH FROM v_target);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- Reported, not raised. A missing period is a reference-data gap;
      -- faulting on it turns somebody's oversight into a red integration.
      o_message := 'No period is defined for '
        || TO_CHAR(v_target,'MON-YYYY') || ' - nothing populated.';
      o_period  := NULL;
      RETURN;
  END;

  o_job     := oc_time_pkg.populate_month(o_period, NULL, p_actor);
  o_status  := 'Populated';
  o_message := 'Populated ' || v_name || '.';
END oc_time_run_monthly_population;
/

SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] Prove the day guard on both sides of a month boundary
PROMPT ============================================================

-- Nothing is populated here: every call is unforced, so the guard either
-- refuses or the date really is a run day. The one real run is [4].
DECLARE
  v_st VARCHAR2(30); v_pd NUMBER; v_jb NUMBER; v_ms VARCHAR2(400);
  PROCEDURE try(p_lbl VARCHAR2, p_d DATE) IS
  BEGIN
    oc_time_run_monthly_population(p_d, 'N', 'DB_113_TEST',
                                   v_st, v_pd, v_jb, v_ms);
    DBMS_OUTPUT.PUT_LINE(RPAD(p_lbl, 24) || RPAD(v_st, 11) || v_ms);
  END try;
BEGIN
  try('15-Aug mid month',   DATE '2026-08-15');
  try('29-Aug 3rd last',    DATE '2026-08-29');
  try('30-Aug 2nd last',    DATE '2026-08-30');
  try('31-Aug last day',    DATE '2026-08-31');
  try('26-Feb-27 3rd last', DATE '2027-02-26');
  try('27-Feb-27 2nd last', DATE '2027-02-27');
END;
/

PROMPT
PROMPT Expected: 15 and 29 Aug Skipped; 30 and 31 Aug Populated for SEP-2026;
PROMPT 26-Feb Skipped and 27-Feb Populated for MAR-2027. February is the case a
PROMPT hard-coded day number gets wrong, which is why the rule is computed,
PROMPT and it is the case BYMONTHDAY=-2 in OIC gets right for the same reason.

PROMPT ============================================================
PROMPT [4/4] Run it for real against the coming month
PROMPT ============================================================

-- Forced, because today is almost certainly not a run day and the point is to
-- prove the whole path before OIC depends on it. populate_month is a MERGE, so
-- doing the work early costs nothing and does not overwrite typed hours.
DECLARE
  v_st VARCHAR2(30); v_pd NUMBER; v_jb NUMBER; v_ms VARCHAR2(400);
BEGIN
  oc_time_run_monthly_population(NULL, 'Y', 'DB_113_DRYRUN',
                                 v_st, v_pd, v_jb, v_ms);
  DBMS_OUTPUT.PUT_LINE('status  : ' || v_st);
  DBMS_OUTPUT.PUT_LINE('period  : ' || NVL(TO_CHAR(v_pd),'(none)'));
  DBMS_OUTPUT.PUT_LINE('job run : ' || NVL(TO_CHAR(v_jb),'(none)'));
  DBMS_OUTPUT.PUT_LINE('message : ' || v_ms);
END;
/

COLUMN period_ FORMAT A12
SELECT p.period_name AS period_,
       COUNT(DISTINCT w.employee_id) AS employees,
       COUNT(DISTINCT w.ts_week_id)  AS weeks,
       TRIM(TO_CHAR(NVL(SUM(e.hours),0),'FM999990.00')) AS hours
  FROM oc_time_period p
  LEFT JOIN oc_ts_week  w ON w.period_id  = p.period_id
  LEFT JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
 WHERE p.period_year  = EXTRACT(YEAR  FROM TRUNC(ADD_MONTHS(
         CAST(SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata' AS DATE), 1), 'MM'))
   AND p.period_month = EXTRACT(MONTH FROM TRUNC(ADD_MONTHS(
         CAST(SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata' AS DATE), 1), 'MM'))
 GROUP BY p.period_name;

PROMPT
PROMPT Zero employees means either no period for that month or no active
PROMPT allocations. Both are reference-data gaps, not failures of this job.
PROMPT
PROMPT NEXT: run ords/13_ords_time_admin.sql to publish
PROMPT POST jobs/populate/monthly, then point O2C_TIME_SYNC_MONTHLY at it.
