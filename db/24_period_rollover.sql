--==============================================================
-- time/24_period_rollover.sql
-- O2C Timesheet Module — opening and closing a period from the admin screen
--
-- Added 11-Aug-2026, on request.
--
-- WHY THIS EXISTS
--   The monthly OIC run populates next month automatically. Nothing OPENS it.
--   RA-009 recorded "no nightly period auto-close job" as an assumption and
--   left the month turn as a manual act with no home:
--
--     25-Aug 02:00   monthly run populates SEP-2026        OIC, automatic
--     ~1-Sep         flip SEP -> Open, AUG -> Closed       nobody
--
--   The first month that is forgotten, everyone sees a populated September
--   they cannot type into, and it reads as a broken sync rather than a missed
--   step. This gives the step a button and an audit trail.
--
-- WHAT THIS IS NOT
--   PAGE-008 (Period Control) was removed by decision on 29-Jul: periods are
--   reference data, no screen creates or edits them, and RULE-018 is
--   deliberately DB-only for that reason. Nothing here reopens that. These two
--   calls change STATUS on a period that already exists -- an operational act,
--   the same kind as running defaulting -- and there is still no way to author
--   a period from a screen.
--
-- WHY CLOSING REFUSES AND OPENING DOES NOT
--   Closing gates editing. 92_month_end_close.sql says it plainly: do not close
--   while any project is refused, because a refusal cannot afterwards be fixed
--   by approving -- the weeks are locked by then. So close_period counts the
--   unconfirmed projects and refuses, and p_force exists for the case where
--   somebody has looked and decided anyway.
--
--   Opening has no such trap. It only widens what can be edited, and RULE-017
--   is relaxed (13_open_periods.sql) so several months may be Open at once.
--
-- STATUS HAS ONLY TWO VALUES. chk_oc_tp_status allows 'Open' and 'Closed'.
-- There is no 'Future' -- a month that has not started is stored Closed, and
-- the Open/Closed/Future chip in the picker is derived from the DATES. The view
-- below exposes that derivation as PHASE so the screen does not re-invent it.
--
-- Idempotent. Depends on: time/01, time/04, time/06
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] V_OC_TIME_PERIOD_ADMIN — what the screen renders
PROMPT ============================================================

-- One row per period, carrying everything the admin page needs to draw a row
-- and decide whether each button is enabled. The page must not compute any of
-- this itself: CAN_OPEN and CAN_CLOSE are the same conditions the procedures
-- below enforce, so a disabled button and a refused call always agree.
CREATE OR REPLACE VIEW v_oc_time_period_admin AS
SELECT p.period_id,
       p.period_name,
       p.status,
       TO_CHAR(p.start_date,      'YYYY-MM-DD') AS start_date,
       TO_CHAR(p.end_date,        'YYYY-MM-DD') AS end_date,
       TO_CHAR(p.delivery_cutoff, 'YYYY-MM-DD') AS delivery_cutoff,
       TO_CHAR(p.finance_cutoff,  'YYYY-MM-DD') AS finance_cutoff,
       -- Past / Current / Future, from the dates. This is the chip the picker
       -- shows; STATUS is a different question and both are displayed.
       CASE WHEN TRUNC(SYSDATE) BETWEEN p.start_date AND p.end_date
              THEN 'Current'
            WHEN p.start_date > TRUNC(SYSDATE) THEN 'Future'
            ELSE 'Past'
       END AS phase,
       (SELECT COUNT(*) FROM oc_ts_week w
         WHERE w.period_id = p.period_id)                    AS weeks,
       (SELECT COUNT(DISTINCT w.employee_id) FROM oc_ts_week w
         WHERE w.period_id = p.period_id)                    AS people,
       -- Projects with hours in this period that have NOT been confirmed to
       -- accrual. This is the number that decides whether closing is safe, and
       -- it is what the refusal message quotes back.
       (SELECT COUNT(*) FROM (
          SELECT DISTINCT m.project_id
            FROM v_oc_ts_month_summary m
           WHERE m.period_id = p.period_id
             AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm c
                              WHERE c.project_id = m.project_id
                                AND c.period_id  = m.period_id)))
                                                             AS unconfirmed_projects,
       CASE WHEN p.status = 'Open' THEN 'N' ELSE 'Y' END     AS can_open,
       CASE WHEN p.status = 'Closed' THEN 'N'
            WHEN (SELECT COUNT(*) FROM (
                    SELECT DISTINCT m.project_id
                      FROM v_oc_ts_month_summary m
                     WHERE m.period_id = p.period_id
                       AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm c
                                        WHERE c.project_id = m.project_id
                                          AND c.period_id  = m.period_id))) > 0
              THEN 'N'
            ELSE 'Y'
       END                                                   AS can_close
  FROM oc_time_period p;

PROMPT ============================================================
PROMPT [2/4] OC_TIME_OPEN_PERIOD
PROMPT ============================================================

CREATE OR REPLACE FUNCTION oc_time_open_period(
  p_period_id IN NUMBER,
  p_actor     IN VARCHAR2 DEFAULT 'ADMIN') RETURN NUMBER
IS
  v_job    NUMBER;
  v_name   oc_time_period.period_name%TYPE;
  v_status oc_time_period.status%TYPE;
  v_rows   NUMBER := 0;
BEGIN
  BEGIN
    SELECT period_name, status INTO v_name, v_status
      FROM oc_time_period WHERE period_id = p_period_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    -- In the -20001..-20025 band on purpose: ORDS maps that band to 400 with
    -- the message passed through, so the page can toast it verbatim.
    RAISE_APPLICATION_ERROR(-20008,
      'Period ' || p_period_id || ' does not exist.');
  END;

  INSERT INTO oc_time_sync_job
         (job_name, job_type, period_id, job_status, triggered_by)
  VALUES ('Open Period', 'PeriodRollover', p_period_id, 'Running', p_actor)
  RETURNING job_run_id INTO v_job;

  IF v_status = 'Open' THEN
    -- Not an error. Re-running a rollover step must be safe, because the whole
    -- point is that somebody may not remember whether it was done.
    UPDATE oc_time_sync_job
       SET job_status = 'Success', finished_on = SYSTIMESTAMP, duration_ms = 0,
           message = v_name || ' was already Open. No change.'
     WHERE job_run_id = v_job;
    RETURN v_job;
  END IF;

  UPDATE oc_time_period
     SET status = 'Open', updated_by = p_actor, updated_on = SYSTIMESTAMP
   WHERE period_id = p_period_id;
  v_rows := SQL%ROWCOUNT;

  UPDATE oc_time_sync_job
     SET job_status = 'Success', finished_on = SYSTIMESTAMP,
         duration_ms = 0, records_upserted = v_rows,
         message = v_name || ' opened by ' || p_actor || '.'
   WHERE job_run_id = v_job;

  RETURN v_job;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] OC_TIME_CLOSE_PERIOD
PROMPT ============================================================

CREATE OR REPLACE FUNCTION oc_time_close_period(
  p_period_id IN NUMBER,
  p_actor     IN VARCHAR2 DEFAULT 'ADMIN',
  p_force     IN VARCHAR2 DEFAULT 'N') RETURN NUMBER
IS
  v_job    NUMBER;
  v_name   oc_time_period.period_name%TYPE;
  v_status oc_time_period.status%TYPE;
  v_open   NUMBER := 0;
  v_rows   NUMBER := 0;
BEGIN
  BEGIN
    SELECT period_name, status INTO v_name, v_status
      FROM oc_time_period WHERE period_id = p_period_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20008,
      'Period ' || p_period_id || ' does not exist.');
  END;

  -- The count is read from the same view the screen renders, so the number in
  -- the refusal is the number the admin was looking at when they pressed it.
  SELECT unconfirmed_projects INTO v_open
    FROM v_oc_time_period_admin WHERE period_id = p_period_id;

  IF v_open > 0 AND NVL(p_force,'N') <> 'Y' THEN
    RAISE_APPLICATION_ERROR(-20009,
      v_name || ' has ' || v_open || ' project(s) not yet confirmed to '
      || 'accrual. Closing locks the weeks, and a project refused after '
      || 'closing cannot then be fixed by approving it. Confirm them first, '
      || 'or close with force if this is a deliberate advance closure.');
  END IF;

  INSERT INTO oc_time_sync_job
         (job_name, job_type, period_id, job_status, triggered_by)
  VALUES ('Close Period', 'PeriodRollover', p_period_id, 'Running', p_actor)
  RETURNING job_run_id INTO v_job;

  IF v_status = 'Closed' THEN
    UPDATE oc_time_sync_job
       SET job_status = 'Success', finished_on = SYSTIMESTAMP, duration_ms = 0,
           message = v_name || ' was already Closed. No change.'
     WHERE job_run_id = v_job;
    RETURN v_job;
  END IF;

  UPDATE oc_time_period
     SET status = 'Closed', updated_by = p_actor, updated_on = SYSTIMESTAMP
   WHERE period_id = p_period_id;
  v_rows := SQL%ROWCOUNT;

  UPDATE oc_time_sync_job
     SET job_status = 'Success', finished_on = SYSTIMESTAMP,
         duration_ms = 0, records_upserted = v_rows,
         message = v_name || ' closed by ' || p_actor
                || CASE WHEN v_open > 0
                        THEN ' with ' || v_open || ' project(s) unconfirmed '
                          || '(forced).'
                        ELSE '.' END
   WHERE job_run_id = v_job;

  RETURN v_job;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A28
COLUMN object_type FORMAT A10
COLUMN status      FORMAT A8
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('V_OC_TIME_PERIOD_ADMIN',
                       'OC_TIME_OPEN_PERIOD', 'OC_TIME_CLOSE_PERIOD')
 ORDER BY object_type, object_name;

COLUMN period_name FORMAT A12
COLUMN status      FORMAT A8
COLUMN phase       FORMAT A8
SELECT period_id, period_name, status, phase, weeks, people,
       unconfirmed_projects AS unconfirmed, can_open, can_close
  FROM v_oc_time_period_admin
 ORDER BY start_date;

PROMPT
PROMPT PHASE is derived from the dates; STATUS is the stored value. A future
PROMPT month reading Closed is correct -- chk_oc_tp_status has no 'Future'.
PROMPT
PROMPT CAN_CLOSE is N while any project is unconfirmed. That is the same
PROMPT condition OC_TIME_CLOSE_PERIOD refuses on, so a greyed button and a
PROMPT refused call can never disagree.
