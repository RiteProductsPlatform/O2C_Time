--==============================================================
-- time/53_payroll_cutoff.sql
-- O2C Timesheet Module — the payroll cut-off, read live from the main app
--
-- The Salary Stopping page has always been empty, and there were three
-- reasons. This fixes the third and hardest: there was no payroll cut-off to
-- gate on. OC_TIME_PERIOD carried PAYROLL_CUTOFF as CAST(NULL AS DATE) from
-- the moment 35 made periods a direct select, because o2c_dev.OC_MEC_PERIOD
-- has no payroll column -- it holds DELIVERY, FINANCE, MEC_CLOSE and
-- BOOK_CLOSURE and stops there.
--
-- IT IS A DIFFERENT TABLE, AND IT IS KEYED BY COUNTRY.
--   o2c_dev.OC_PAYROLL_CONFIG holds COUNTRY, PERIOD_TYPE, PAYROLL_CUTOFF,
--   HOLD_RELEASE_DAYS. Not one row per period -- one row per cut-off DATE,
--   and the period definition is explicit that "one country can have more
--   than one cut off date for a period".
--
--   So the payroll cut-off can never be a column on OC_TIME_PERIOD. Two people
--   in the same month have different cut-offs if they sit in different
--   countries, exactly as they now have different weekly cut-offs.
--
-- WHAT THIS DOES NOT DO
--   It does not decide to hold anybody's pay. It answers one question --
--   "what is this person's payroll cut-off for this period, if any" -- and
--   time/09 uses the answer. Where no cut-off is configured the answer is
--   NULL and salary stopping does NOTHING for that country. Holding pay on a
--   guessed date is worse than not holding it, and a missing configuration is
--   reported rather than defaulted.
--
-- Idempotent. Depends on: time/36
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
PROMPT [1/4] OC_PAYROLL_CONFIG_SRC — reach the main app's table
PROMPT ============================================================

-- Same pattern as OC_MEC_PERIOD_SRC in time/33: a synonym, so the table is
-- read LIVE and never copied. A copy would need a sync, and a payroll cut-off
-- that is one sync stale is a cut-off that holds the wrong people's pay.
--
-- CREATE SYNONYM succeeds against a target that does not exist or cannot be
-- reached -- it only fails later, with ORA-00980, at the first SELECT. So the
-- synonym is created AND then read, and the read is what decides whether this
-- worked.
DECLARE
  v_target VARCHAR2(128) := 'o2c_dev.oc_payroll_config';
  v_n      NUMBER;
BEGIN
  BEGIN EXECUTE IMMEDIATE 'DROP SYNONYM oc_payroll_config_src';
  EXCEPTION WHEN OTHERS THEN NULL; END;

  EXECUTE IMMEDIATE 'CREATE SYNONYM oc_payroll_config_src FOR ' || v_target;
  DBMS_OUTPUT.PUT_LINE('synonym -> ' || v_target);

  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM oc_payroll_config_src' INTO v_n;
  DBMS_OUTPUT.PUT_LINE(v_n || ' payroll configuration row(s) visible');

EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('CANNOT READ ' || v_target || ' -- ' || SUBSTR(SQLERRM,1,120));
  DBMS_OUTPUT.PUT_LINE('Ask for:  GRANT SELECT ON ' || v_target
                    || ' TO ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ';');
  DBMS_OUTPUT.PUT_LINE('Everything below still installs; it will simply find '
                    || 'no cut-offs and hold nobody.');
END;
/

PROMPT ============================================================
PROMPT [2/4] V_OC_TIME_PAYROLL_CUTOFF — country x period
PROMPT ============================================================

-- One row per country per period, carrying the cut-off that governs it.
--
-- WHICH ONE, when a country has several. The definition says a country may
-- have more than one cut-off date for a period, and offers no rule for
-- choosing. The LAST cut-off inside the period is taken: it is the moment
-- after which nothing more can reach that pay cycle, which is what a hold is
-- deciding. An earlier one would hold pay while a later run could still have
-- collected the time.
--
-- 'Date Range' rows are included where they carry a cut-off. The definition
-- makes PAYROLL_CUTOFF mandatory only for 'Cut off' and optional for
-- 'Date Range', so a Date Range row without one simply has nothing to say
-- here and is skipped by the WHERE.
CREATE OR REPLACE VIEW v_oc_time_payroll_cutoff AS
SELECT p.period_id,
       p.period_name,
       c.country,
       MAX(c.payroll_cutoff)                                   AS payroll_cutoff,
       MAX(c.hold_release_days) KEEP (DENSE_RANK LAST
             ORDER BY c.payroll_cutoff)                        AS hold_release_days,
       COUNT(*)                                                AS cutoffs_in_period,
       MAX(c.period_type) KEEP (DENSE_RANK LAST
             ORDER BY c.payroll_cutoff)                        AS period_type
  FROM oc_time_period      p
  JOIN oc_payroll_config_src c
    ON c.payroll_cutoff BETWEEN p.start_date AND p.end_date
 WHERE c.payroll_cutoff IS NOT NULL
 GROUP BY p.period_id, p.period_name, c.country;

PROMPT ============================================================
PROMPT [3/4] OC_TIME_PAYROLL_CUTOFF — the cut-off for one worker
PROMPT ============================================================

CREATE OR REPLACE FUNCTION oc_time_payroll_cutoff(
  p_employee_id IN VARCHAR2,
  p_period_id   IN NUMBER) RETURN DATE
IS
  v_country oc_time_worker.base_country%TYPE;
  v_cut     DATE;
BEGIN
  -- BASE_COUNTRY, matching oc_time_worker_zone and the weekly cut-off. Payroll
  -- follows the legal employer rather than where somebody is sitting this
  -- month, which is the one place deputation should NOT win.
  SELECT base_country INTO v_country
    FROM oc_time_worker WHERE employee_id = p_employee_id;

  SELECT MAX(payroll_cutoff) INTO v_cut
    FROM v_oc_time_payroll_cutoff
   WHERE period_id = p_period_id
     AND country   = v_country;

  RETURN v_cut;      -- NULL means "no cut-off configured": hold nobody
EXCEPTION WHEN OTHERS THEN
  -- No worker, no country, or the synonym cannot be read. NULL, deliberately:
  -- every caller treats NULL as "do not hold", and an error here must not be
  -- able to hold somebody's pay by accident.
  RETURN NULL;
END;
/
SHOW ERRORS

CREATE OR REPLACE FUNCTION oc_time_hold_release_days(
  p_employee_id IN VARCHAR2,
  p_period_id   IN NUMBER) RETURN NUMBER
IS
  v_country oc_time_worker.base_country%TYPE;
  v_days    NUMBER;
BEGIN
  SELECT base_country INTO v_country
    FROM oc_time_worker WHERE employee_id = p_employee_id;

  SELECT MAX(hold_release_days) INTO v_days
    FROM v_oc_time_payroll_cutoff
   WHERE period_id = p_period_id AND country = v_country;

  -- The main application's value wins. Ours (CFG-012, 60) is the fallback for
  -- a country it has no row for -- note their column DEFAULTs to 0, which
  -- would mean "no resubmission window at all", so a real 0 and a missing row
  -- must not be confused. NVL only covers the missing row.
  IF v_days IS NULL THEN
    SELECT TO_NUMBER(MAX(config_value)) INTO v_days
      FROM oc_time_config
     WHERE config_name = 'hold_release_days' AND scope_key = 'GLOBAL';
  END IF;

  RETURN NVL(v_days, 60);
EXCEPTION WHEN OTHERS THEN
  RETURN 60;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Coverage — who has a payroll cut-off and who does not
PROMPT ============================================================

COLUMN country FORMAT A18
COLUMN period_name FORMAT A12
SELECT period_name, country, period_type, cutoffs_in_period,
       TO_CHAR(payroll_cutoff,'DD-Mon-YY') AS cutoff,
       hold_release_days AS release_days
  FROM v_oc_time_payroll_cutoff
 ORDER BY period_name, country;

PROMPT
PROMPT --- active workers whose country has NO cut-off in the open period
COLUMN base_country FORMAT A20
SELECT NVL(w.base_country,'(null)') AS base_country, COUNT(*) AS workers
  FROM oc_time_worker w
 WHERE w.status = 'Active'
   AND NOT EXISTS (SELECT 1 FROM v_oc_time_payroll_cutoff x
                    JOIN oc_time_period p ON p.period_id = x.period_id
                   WHERE x.country = w.base_country
                     AND p.status  = 'Open')
 GROUP BY w.base_country
 ORDER BY 2 DESC FETCH FIRST 15 ROWS ONLY;

PROMPT
PROMPT Every country listed there holds NOBODY, because there is no cut-off to
PROMPT pass. That is the safe answer, not a working one -- salary stopping is
PROMPT only live for countries the main application has configured.
PROMPT
PROMPT NEXT: re-run 09_pkg_oc_time.sql. run_salary_stopping still decides who
PROMPT defaulted by SUBMITTED_ON IS NULL, which the cut-off job always fills
PROMPT in, so it can never produce a row whatever cut-off it is given.
