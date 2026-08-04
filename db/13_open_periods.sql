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

-- Status alone is not enough. V_OC_TIME_CUTOFFS returns editable_flag = 'N'
-- once TRUNC(SYSDATE) > delivery_cutoff (RULE-007), and July's was 03-Aug-2026
-- — yesterday. Opening July without this leaves it Open and still read-only,
-- which looks exactly like the change not having worked.
--
-- 30-Sep-2026 is a working date for testing, not a business decision. Set it to
-- whatever the real July delivery date should be.
UPDATE oc_time_period
   SET delivery_cutoff = DATE '2026-09-30', updated_by = 'ADMIN'
 WHERE period_year = 2026 AND period_month = 7
   AND delivery_cutoff < DATE '2026-09-30';
COMMIT;

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

COLUMN period_name  FORMAT A10
COLUMN status       FORMAT A7
COLUMN period_state FORMAT A7
SELECT period_name, status, period_state, editable_flag, adjustment_allowed,
       start_date, delivery_cutoff
  FROM v_oc_time_cutoffs
 ORDER BY period_year, period_month;

SELECT COUNT(*) AS open_periods FROM oc_time_period WHERE status = 'Open';

-- Which month the code will now call "the open period".
SELECT oc_time_pkg.get_open_period_id AS resolved_open_period FROM dual;

SELECT period_id, COUNT(DISTINCT employee_id) AS employees, COUNT(*) AS weeks
  FROM oc_ts_week
 GROUP BY period_id
 ORDER BY period_id;
