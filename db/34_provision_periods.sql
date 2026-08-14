--==============================================================
-- time/34_provision_periods.sql
-- O2C Timesheet Module — give a new upstream period a local anchor
--
-- Restores OC_TIME_PROVISION_MEC_PERIODS, which db/32 dropped and db/33 did
-- not put back.
--
-- WHY IT IS NEEDED AT ALL, WHEN PERIODS ARE READ LIVE
--   OC_TIME_PERIOD is a view driven by the LOCAL base table:
--
--     FROM oc_time_period_base b
--     LEFT JOIN oc_mec_period_src m ON m.start_date = b.start_date
--
--   So a period that exists ONLY upstream is invisible here. That is not an
--   oversight in the join direction -- it is forced. The join could be driven
--   from the main application instead, but then a new month would arrive with
--   a NULL PERIOD_ID, and PERIOD_ID is what OC_TS_WEEK, OC_TS_MONTH_CONFIRM,
--   OC_TS_ENTRY and the accrual interface all point at. A month with no id
--   cannot hold a timesheet.
--
--   So one thing is still created locally, once per period: an identity for
--   the foreign keys, and the weekly cut-off, which the main application has
--   no column for. Everything that CHANGES -- status, the four downstream
--   cut-offs, the accounting date -- is read live and never copied.
--
-- WHEN TO RUN IT
--   Whenever a period is added upstream. Adding October there and not running
--   this means October simply does not exist here: no weeks, no entry, and
--   nothing on screen to say why. Step [2] wires it into the daily process so
--   that cannot happen quietly.
--
-- Idempotent -- it only inserts what is missing. Depends on: time/30 or 33
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') ||
      ', which does not own this module. Connect to the schema holding ' ||
      'OC_TIME_WORKER and re-run.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] OC_TIME_PROVISION_MEC_PERIODS
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_provision_mec_periods(
  p_actor IN VARCHAR2 DEFAULT 'MEC_PROVISION')
IS
  v_n NUMBER := 0;
BEGIN
  FOR r IN (
    SELECT m.period_name, m.start_date, m.end_date, m.accounting_date, m.status
      FROM oc_mec_period_src m
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_period_base b
                        WHERE b.start_date = m.start_date)
     ORDER BY m.start_date
  ) LOOP
    INSERT INTO oc_time_period_base (
      period_name, period_year, period_month, status,
      start_date, end_date, accounting_date,
      ts_cutoff_day, ts_cutoff_time, created_by)
    VALUES (
      -- Derived, not copied. Ours reads AUG-2026 on every screen and in every
      -- message; theirs reads 'August 2026'. The view carries their name
      -- alongside for traceability, so nothing is lost by not adopting it.
      UPPER(TO_CHAR(r.start_date, 'MON-YYYY')),
      EXTRACT(YEAR  FROM r.start_date),
      EXTRACT(MONTH FROM r.start_date),
      -- Seeded from theirs, then never read again: the view takes STATUS live
      -- from the main application. This value only shows if the upstream row
      -- later disappears, which is the NVL fallback doing its job.
      r.status, r.start_date, r.end_date, r.accounting_date,
      -- The weekly cut-off has no upstream source. A null here would leave
      -- every Submit in the month unclassifiable under the V4 timing rules,
      -- so the module default is applied rather than nothing.
      'Monday', '17:00', p_actor);
    v_n := v_n + 1;
    DBMS_OUTPUT.PUT_LINE('  provisioned ' || UPPER(TO_CHAR(r.start_date,'MON-YYYY'))
                      || '  (' || r.period_name || ')');
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' period(s) provisioned');
END;
/
SHOW ERRORS

BEGIN oc_time_provision_mec_periods; END;
/

PROMPT ============================================================
PROMPT [2/3] Run it from the daily process so nobody has to remember
PROMPT ============================================================

-- A period added upstream and never provisioned here is invisible: no weeks,
-- no entry, and nothing on any screen explaining the absence. That is too
-- quiet a failure to leave to a manual step, so the daily process does it.
--
-- Cheap: one query against three rows, and it inserts only what is missing.
CREATE OR REPLACE PROCEDURE oc_time_daily_provision
IS
BEGIN
  oc_time_provision_mec_periods('DAILY_SYNC');
EXCEPTION WHEN OTHERS THEN
  -- Never let this stop the sync. A missing period is a problem; a sync that
  -- refuses to run because of one is a bigger problem.
  DBMS_OUTPUT.PUT_LINE('provision skipped: ' || SUBSTR(SQLERRM, 1, 120));
END;
/
SHOW ERRORS

PROMPT
PROMPT Call oc_time_daily_provision at the start of the OIC daily run, or add
PROMPT it to whatever runs populate_daily. Until then, run [1] by hand after
PROMPT adding a period upstream.

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN mec_name    FORMAT A16
COLUMN status      FORMAT A8
COLUMN editable    FORMAT A8
SELECT p.period_name, p.status, p.mec_linked, p.mec_period_name AS mec_name,
       TO_CHAR(p.start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(p.delivery_cutoff,'DD-MON-YY') AS delivery,
       CASE WHEN p.status <> 'Open' THEN 'N'
            WHEN p.delivery_cutoff IS NOT NULL
             AND TRUNC(SYSDATE) > p.delivery_cutoff THEN 'N'
            ELSE 'Y' END AS editable
  FROM oc_time_period p ORDER BY p.start_date;

PROMPT
PROMPT EDITABLE is the column that actually decides whether anyone can type,
PROMPT and it is NOT the same as STATUS. A month is editable only when it is
PROMPT Open AND today is on or before its delivery cut-off -- so opening a past
PROMPT month upstream does NOT reopen it here unless its delivery cut-off is
PROMPT moved forward too.
PROMPT
PROMPT MEC_LINKED 'N' means the main application has no period starting on that
PROMPT date. Add it there, then run [1] again -- or wait for the daily process
PROMPT once oc_time_daily_provision is wired in.
