-- ============================================================
-- 13_open_periods.sql — hold JUL-2026 and AUG-2026 open together
-- ============================================================
-- RULE-017 ("only one period may be Open at a time") is RELAXED as of
-- 04-Aug-2026, by decision. This script carries that change:
--
--   1. drop UK_OC_TP_SINGLE_OPEN       the unique index that enforced the rule
--   2. open JUL-2026 and AUG-2026      both, together
--   3. extend July's delivery cut-off  or July is Open but still not editable
--   4. populate AUG-2026               it has no weeks at all yet
--
-- RUN db/09_pkg_oc_time.sql FIRST, or step 2 leaves the database in a state the
-- old package cannot read: get_open_period_id was a bare SELECT INTO and raises
-- TOO_MANY_ROWS the moment a second month is Open. The new version orders and
-- takes one row, and populate_daily now resolves the period from its action
-- date instead of asking which month is "the" open one.
--
-- What relaxing the rule costs, on the record:
--   * "the open period" is now a choice, not a fact. get_open_period_id picks
--     the month containing today, else the earliest open one.
--   * run_accrual_top_up posts a late adjustment into that chosen month. With
--     both open it picks August while August contains today — confirm that is
--     intended before running a top-up.
--   * the sign-in views resolve openPeriodId the same way, so the landing month
--     is stable rather than whichever row the optimiser happened to return.
--
-- Idempotent and re-runnable. Nothing is deleted; population skips entries that
-- already exist.
-- ============================================================

SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] Drop UK_OC_TP_SINGLE_OPEN — RULE-017 relaxed
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX uk_oc_tp_single_open';
  DBMS_OUTPUT.PUT_LINE('UK_OC_TP_SINGLE_OPEN dropped.');
EXCEPTION
  WHEN OTHERS THEN
    -- ORA-01418: index does not exist, so a re-run is a no-op.
    IF SQLCODE = -1418 THEN
      DBMS_OUTPUT.PUT_LINE('UK_OC_TP_SINGLE_OPEN already absent.');
    ELSE
      RAISE;
    END IF;
END;
/

PROMPT ============================================================
PROMPT [2/4] Open JUL-2026 and AUG-2026
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_period
     SET status = 'Open', updated_by = 'ADMIN'
   WHERE period_year = 2026
     AND period_month IN (7, 8)
     AND status <> 'Open';
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' period(s) moved to Open.');
END;
/

PROMPT ============================================================
PROMPT [3/4] Extend July's delivery cut-off so it is actually editable
PROMPT ============================================================

-- Status alone is not enough. V_OC_TS_MY_PERIODS returns editable_flag = 'N'
-- once TRUNC(SYSDATE) > delivery_cutoff (RULE-007), and July's was 03-Aug-2026
-- — yesterday. Opening July without this leaves it Open and still read-only,
-- which looks exactly like the change not having worked.
--
-- 30-Sep-2026 IS A TESTING DATE, NOT A BUSINESS ONE, and re-running this
-- script will impose it again.
--
-- The real shape (confirmed 10-Aug-2026) is different and matters, because the
-- two cut-offs sit either side of month end:
--
--     payroll cut-off   25-Jul   BEFORE the month has even finished
--     delivery cut-off  ~10-Aug  AFTER it, once managers have had a chance
--
-- So this UPDATE will overwrite a correctly-set July delivery cut-off with
-- 30-Sep. The guard below only skips rows already LATER than 30-Sep, which a
-- real 10-Aug value is not.
--
-- BEFORE RE-RUNNING THE INSTALLER ON AN ENVIRONMENT WITH REAL CUT-OFFS, either
-- change the date here or comment this statement out. Everything else in the
-- installer is idempotent; this one is opinionated.
-- DISABLED 10-Aug-2026. The delivery cut-off is not ours to invent: it comes
-- from the ACCRUAL close calendar, and July's real value is around 10-Aug, not
-- 30-Sep. Leaving this active meant every re-run of the installer silently
-- replaced a correct date with a testing one -- and the guard did not save it,
-- because it only skipped values already LATER than 30-Sep.
--
-- Re-enable only with the real date, or better, set the cut-offs from the
-- accrual calendar and delete this block.
--
-- UPDATE oc_time_period
--    SET delivery_cutoff = DATE '2026-09-30', updated_by = 'ADMIN'
--  WHERE period_year = 2026 AND period_month = 7
--    AND delivery_cutoff < DATE '2026-09-30';
-- COMMIT;

-- Report what the cut-offs actually are, so a July that is Open but read-only
-- is diagnosable rather than mysterious. Editability is delivery-cut-off
-- driven (RULE-007), and salary stopping is payroll-cut-off driven -- the two
-- are different dates and sit either side of month end.
DECLARE
  CURSOR c IS
    SELECT period_name, status,
           TO_CHAR(delivery_cutoff,'DD-Mon-YYYY') AS del,
           TO_CHAR(payroll_cutoff,'DD-Mon-YYYY')  AS pay
      FROM oc_time_period
     WHERE period_year = 2026 AND period_month IN (6, 7, 8)
     ORDER BY period_month;
BEGIN
  DBMS_OUTPUT.PUT_LINE('period    status  delivery      payroll');
  FOR r IN c LOOP
    DBMS_OUTPUT.PUT_LINE(RPAD(r.period_name,10) || RPAD(r.status,8)
      || RPAD(NVL(r.del,'(not set)'),14) || NVL(r.pay,'(not set)'));
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(
    'If delivery is in the past the month is Open and READ-ONLY (RULE-007).');
END;
/

PROMPT ============================================================
PROMPT [4/4] Populate AUG-2026
PROMPT ============================================================

-- ACT-031 / PROC-001. NULL employee = every active allocation. August has zero
-- weeks today, so without this it opens editable but completely empty.
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

  SELECT COUNT(*) INTO v_weeks FROM oc_ts_week WHERE period_id = v_period;
  SELECT COUNT(*) INTO v_rows
    FROM oc_ts_entry e
    JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
   WHERE w.period_id = v_period;

  DBMS_OUTPUT.PUT_LINE('job_run_id ' || v_job || ': ' || v_weeks
                       || ' weeks, ' || v_rows || ' entries.');
END;
/

PROMPT ============================================================
PROMPT Verification — BOTH July and August must read Open and editable Y
PROMPT ============================================================

-- V_OC_TS_MY_PERIODS, not V_OC_TIME_CUTOFFS. Two different views over the same
-- table and it is easy to reach for the wrong one: CUTOFFS (01_time_reference)
-- carries every cut-off DATE, while MY_PERIODS (08_views) is the one that
-- derives period_state, editable_flag and adjustment_allowed — the three
-- columns that say whether a month can be typed into. It is also what
-- getPeriods reads, so this shows exactly what the app will see.
COLUMN period_name  FORMAT A10
COLUMN status       FORMAT A7
COLUMN period_state FORMAT A7
SELECT period_name, status, period_state, editable_flag, adjustment_allowed,
       start_date, delivery_cutoff
  FROM v_oc_ts_my_periods
 ORDER BY period_year, period_month;

SELECT COUNT(*) AS open_periods FROM oc_time_period WHERE status = 'Open';

-- Which month the code will now call "the open period".
SELECT oc_time_pkg.get_open_period_id AS resolved_open_period FROM dual;

SELECT period_id, COUNT(DISTINCT employee_id) AS employees, COUNT(*) AS weeks
  FROM oc_ts_week
 GROUP BY period_id
 ORDER BY period_id;
