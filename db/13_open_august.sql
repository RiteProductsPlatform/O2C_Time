-- ============================================================
-- 13_open_august.sql — roll the open month to AUG-2026
-- ============================================================
-- PAGE-008 (Period Control) was descoped, so opening a month is a data change
-- rather than a screen. This does the three things that make a month usable:
--
--   1. close whatever is Open now      JUL-2026 has passed its delivery cut-off
--   2. open AUG-2026                   status drives period_state and editable
--   3. populate it                     weeks + prepopulated hours per allocation
--
-- ONLY ONE PERIOD MAY BE OPEN. get_open_period_id is a bare SELECT INTO:
--
--   SELECT period_id INTO v_id FROM oc_time_period WHERE status = 'Open';
--
-- so two Open rows raise TOO_MANY_ROWS and every caller of it fails. Step 1 is
-- not tidiness, it is required.
--
-- Nothing here is destructive. Closing July does not touch its hours: a closed
-- month stays visible and read-only (V_OC_TIME_CUTOFFS), and stays correctable
-- through a backdated adjustment while it is inside the window (RULE-019).
-- July was already read-only in practice — its delivery cut-off was 03-Aug.
--
-- Idempotent and re-runnable: population skips entries that already exist.
-- ============================================================

SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] Close the current open month, open AUG-2026
PROMPT ============================================================

DECLARE
  v_target NUMBER;
  v_closed NUMBER := 0;
BEGIN
  SELECT period_id INTO v_target
    FROM oc_time_period
   WHERE period_year = 2026 AND period_month = 8;

  -- Every other Open month closes. Written as "not the target" rather than
  -- "July" so re-running after a further roll cannot leave two Open.
  UPDATE oc_time_period
     SET status = 'Closed', updated_by = 'ADMIN'
   WHERE status = 'Open' AND period_id <> v_target;
  v_closed := SQL%ROWCOUNT;

  UPDATE oc_time_period
     SET status = 'Open', updated_by = 'ADMIN'
   WHERE period_id = v_target AND status <> 'Open';

  DBMS_OUTPUT.PUT_LINE('AUG-2026 (period_id ' || v_target || ') is Open; '
                       || v_closed || ' other period(s) closed.');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [2/3] Populate AUG-2026 — weeks and prepopulated hours
PROMPT ============================================================

-- ACT-031 / PROC-001. NULL employee = every active allocation. The same thing
-- the Sync Status page's "Run population" button does, and the same thing the
-- scheduler would do on the 1st of the month.
DECLARE
  v_period NUMBER;
  v_job    NUMBER;
  v_weeks  NUMBER;
  v_rows   NUMBER;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period
   WHERE period_year = 2026 AND period_month = 8;

  v_job := oc_time_pkg.populate_month(v_period, NULL, 'ADMIN');
  COMMIT;

  SELECT COUNT(*) INTO v_weeks FROM oc_ts_week  WHERE period_id = v_period;
  SELECT COUNT(*) INTO v_rows  FROM oc_ts_entry e
    JOIN oc_ts_week w ON w.ts_week_id = e.ts_week_id
   WHERE w.period_id = v_period;

  DBMS_OUTPUT.PUT_LINE('job_run_id ' || v_job || ': ' || v_weeks
                       || ' weeks, ' || v_rows || ' entries.');
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

-- editable_flag must be Y for AUG: status Open, start date passed, and the
-- delivery cut-off (03-Sep-2026) still ahead. If it reads N, check which of
-- those three is false rather than assuming the UI is broken.
COLUMN period_name  FORMAT A10
COLUMN status       FORMAT A7
COLUMN period_state FORMAT A7
SELECT period_name, status, period_state, editable_flag, adjustment_allowed,
       start_date, delivery_cutoff
  FROM v_oc_time_cutoffs
 ORDER BY period_year, period_month;

SELECT COUNT(*) AS open_periods FROM oc_time_period WHERE status = 'Open';

SELECT w.period_id, COUNT(DISTINCT w.employee_id) AS employees,
       COUNT(*) AS weeks
  FROM oc_ts_week w
 GROUP BY w.period_id
 ORDER BY w.period_id;
