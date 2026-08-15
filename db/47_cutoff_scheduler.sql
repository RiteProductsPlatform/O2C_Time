--==============================================================
-- time/47_cutoff_scheduler.sql
-- O2C Timesheet Module — the cut-off finally has teeth
--
-- Until now nothing ran run_weekly_defaulting. The rule is absolute: if the
-- cut-off is 17:00 the week is Defaulted at 17:00, no grace and no warning.
-- With no job, 17:00 passed and the week sat at Not yet submitted -- somebody
-- submitting on Wednesday got the same outcome as somebody submitting at
-- 17:01, and DEFAULTED_BY='EMPLOYEE' was never written, so no salary was ever
-- held. The engine, the rules and the flags were all correct; nothing pulled
-- the trigger.
--
-- WHY DAILY AND NOT "EVERY MONDAY AT 17:00"
--
--   1. A 17:00 job misses by a whole day. oc_time_week_timing returns
--      PastCutoff only when SYSDATE > due. At exactly 17:00:00 that is FALSE,
--      so a job firing on the stroke of the cut-off defaults nothing and the
--      week waits for the next run -- a week later, on a weekly schedule.
--      Hence 17:05.
--
--   2. The cut-off DAY is configuration. It is read from ts_cutoff_day, and
--      hard-coding BYDAY=MON means changing that config to Tuesday leaves the
--      job firing on Monday for ever. Same shape as the hour-versus-minutes
--      divergence between the job and the engine, fixed in time/39: two places
--      holding the same rule, one of them quietly wrong.
--
--   3. A failed run is picked up tomorrow rather than next week.
--
--   In practice this defaults every Monday just after 17:00, which is the
--   behaviour asked for. On other days it finds nothing due and does nothing.
--
-- TIMEZONE IS EXPLICIT AND HAS TO BE. DBMS_SCHEDULER resolves a repeat
-- interval against the job's timezone, falling back to the database's --
-- Autonomous Database runs UTC, where BYHOUR=17 fires at 22:30 IST. The same
-- trap as the OIC time-zone picker governing BYHOUR.
--
-- Idempotent. Depends on: time/46
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
PROMPT [1/4] What time does this database think it is?
PROMPT ============================================================

-- Printed rather than assumed. If DBTIMEZONE is UTC and the schedule below
-- had no explicit timezone, every cut-off would fire five and a half hours
-- late and the only visible symptom would be weeks defaulting on Tuesday.
SELECT DBTIMEZONE                                        AS db_tz,
       SESSIONTIMEZONE                                   AS session_tz,
       TO_CHAR(SYSTIMESTAMP,'DD-MON-YY HH24:MI:SS TZR')  AS systimestamp,
       TO_CHAR(SYSDATE,'DD-MON-YY HH24:MI:SS')           AS sysdate_is
  FROM dual;

PROMPT
PROMPT SYSDATE is what oc_time_week_timing compares against, so the job must
PROMPT fire when SYSDATE reads just past the cut-off -- not when the wall clock
PROMPT in Chennai does, if the two differ.

PROMPT ============================================================
PROMPT [2/4] OC_TIME_RUN_CUTOFFS — one pass over every open period
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_run_cutoffs(
  p_as_of IN DATE     DEFAULT SYSDATE,
  p_actor IN VARCHAR2 DEFAULT 'CUTOFF_JOB')
IS
  v_job   NUMBER;
  v_weeks NUMBER := 0;
  v_deliv NUMBER := 0;
BEGIN
  -- Every OPEN period, not just "the" open one. RULE-017 is relaxed and more
  -- than one month can be open at a time, so a single get_open_period_id would
  -- silently skip the others.
  --
  -- Closed periods are excluded deliberately: a week inside a closed month is
  -- corrected by a retro adjustment (RULE-019), never by defaulting it now.
  FOR p IN (SELECT period_id, period_name
              FROM oc_time_period
             WHERE status = 'Open'
             ORDER BY start_date)
  LOOP
    -- WEEKLY: the employee missed their own cut-off. Writes
    -- DEFAULTED_BY='EMPLOYEE', which is the default that holds pay (RULE-016).
    BEGIN
      v_job := oc_time_pkg.run_weekly_defaulting(p.period_id, p_as_of, p_actor);
      v_weeks := v_weeks + 1;
      DBMS_OUTPUT.PUT_LINE('  weekly   ' || RPAD(p.period_name, 10)
                        || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      -- One period failing must not stop the rest. A month whose cut-off is
      -- misconfigured should not hold up the months that are fine.
      DBMS_OUTPUT.PUT_LINE('  weekly   ' || RPAD(p.period_name, 10)
                        || ' FAILED ' || SUBSTR(SQLERRM, 1, 100));
    END;

    -- DELIVERY: the manager did not act. Writes ManagerDefaulted on the
    -- approval axis and leaves the submission axis alone, so an employee who
    -- submitted on time keeps that on their record and keeps their salary.
    BEGIN
      v_job := oc_time_pkg.run_delivery_defaulting(p.period_id, p_as_of, p_actor);
      v_deliv := v_deliv + 1;
      DBMS_OUTPUT.PUT_LINE('  delivery ' || RPAD(p.period_name, 10)
                        || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  delivery ' || RPAD(p.period_name, 10)
                        || ' FAILED ' || SUBSTR(SQLERRM, 1, 100));
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(v_weeks || ' weekly and ' || v_deliv
                    || ' delivery pass(es) over open periods');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] The schedule
PROMPT ============================================================

DECLARE
  v_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM user_scheduler_jobs
   WHERE job_name = 'OC_TIME_CUTOFF_JOB';
  IF v_exists > 0 THEN
    DBMS_SCHEDULER.DROP_JOB('OC_TIME_CUTOFF_JOB', force => TRUE);
    DBMS_OUTPUT.PUT_LINE('existing job dropped');
  END IF;

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'OC_TIME_CUTOFF_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN oc_time_run_cutoffs(SYSDATE, ''CUTOFF_JOB''); END;',
    -- 17:05, not 17:00. SYSDATE > due is false ON the cut-off minute, so a
    -- job at 17:00:00 defaults nothing and the week waits for tomorrow.
    repeat_interval => 'FREQ=DAILY;BYHOUR=17;BYMINUTE=5;BYSECOND=0',
    start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata',
    enabled         => TRUE,
    comments        => 'RULE-006/RULE-007 weekly and delivery defaulting. '
                    || 'Daily because the cut-off DAY is configuration; the '
                    || 'engine decides what is actually past its cut-off.');

  DBMS_OUTPUT.PUT_LINE('OC_TIME_CUTOFF_JOB created');
END;
/

-- START_DATE carries the timezone, and that is what the repeat interval is
-- resolved against. Without 'Asia/Kolkata' it inherits the database timezone
-- -- UTC on Autonomous -- and BYHOUR=17 becomes 22:30 IST. The job would run
-- perfectly and default everything five and a half hours late, every day,
-- with nothing in any log to say why.

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN job_name        FORMAT A22
COLUMN repeat_interval FORMAT A40
COLUMN next_run        FORMAT A34
SELECT job_name, enabled, state, repeat_interval,
       TO_CHAR(next_run_date, 'DY DD-MON-YY HH24:MI:SS TZR') AS next_run
  FROM user_scheduler_jobs
 WHERE job_name = 'OC_TIME_CUTOFF_JOB';

PROMPT
PROMPT READ NEXT_RUN CAREFULLY. It must say 17:05 with an offset of +05:30 (or
PROMPT a TZR of Asia/Kolkata). If it reads 17:05 +00:00 the timezone did not
PROMPT take and every cut-off will fire at 22:35 IST.
PROMPT
PROMPT This is the one thing worth checking by eye rather than trusting: the
PROMPT OIC schedule had exactly this problem and the readable panel rendered it
PROMPT correctly while the behaviour was wrong.

PROMPT
PROMPT --- what it would do if it ran right now
SET SERVEROUTPUT ON
DECLARE
  v_due NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_due
    FROM oc_ts_week w
    JOIN oc_time_period p ON p.period_id = w.period_id
   WHERE p.status = 'Open'
     AND w.submission_status = 'NotYetSubmitted'
     AND w.week_end < TRUNC(SYSDATE)
     AND oc_time_week_timing(w.ts_week_id) = 'PastCutoff';
  DBMS_OUTPUT.PUT_LINE(v_due || ' week(s) are past their cut-off and unsubmitted');
  IF v_due > 0 THEN
    DBMS_OUTPUT.PUT_LINE('The first run will default all of them at once, '
                      || 'write DEFAULTED_BY=EMPLOYEE, and lock them.');
    DBMS_OUTPUT.PUT_LINE('Each becomes a salary-hold candidate under RULE-016.');
  END IF;
END;
/

PROMPT
PROMPT ============================================================
PROMPT BEFORE THE FIRST RUN
PROMPT ============================================================
PROMPT
PROMPT The count above is a BACKLOG, not a day's work. Every unsubmitted week
PROMPT since population began is past its cut-off, and the first run defaults
PROMPT the lot in one pass -- locking them and marking every one an EMPLOYEE
PROMPT default, which is what holds salary.
PROMPT
PROMPT On test data that is the point. On anything resembling real people it is
PROMPT not, so decide deliberately: either accept it, or run
PROMPT oc_time_run_cutoffs by hand for a chosen period first and see the
PROMPT numbers before the schedule reaches them.
PROMPT
PROMPT To pause without dropping anything:
PROMPT   BEGIN DBMS_SCHEDULER.DISABLE('OC_TIME_CUTOFF_JOB'); END;
PROMPT   /
