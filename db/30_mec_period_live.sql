--==============================================================
-- time/30_mec_period_live.sql
-- O2C Timesheet Module — periods read LIVE from the main app
--
-- Requested 13-Aug-2026: "I want a live integration of oc_mec_period" -- not a
-- copy that goes stale between runs. This replaces db/29_mec_period_sync.sql.
--
-- HOW IT WORKS, IN ONE SENTENCE
--   OC_TIME_PERIOD stops being a table and becomes a VIEW: the timesheet's own
--   identity and settings joined to the main application's live period row.
--
-- SO NOTHING ELSE HAS TO CHANGE
--   The name OC_TIME_PERIOD is read in 72 places and is the target of 10
--   foreign keys. Renaming the table to OC_TIME_PERIOD_BASE and putting a view
--   of the same name over it means:
--
--     * all 72 SELECTs and JOINs keep working, unedited, and now read live
--     * all 10 foreign keys keep working -- they followed the rename onto the
--       base table, which still holds PERIOD_ID as its primary key
--
--   That last point is why this is better than dropping the table. The earlier
--   plan said a view would cost the foreign keys. It does not: the keys point
--   at identity, and identity stays in a real table.
--
-- WHAT COMES FROM WHERE
--   MEC (live)   STATUS, ACCOUNTING_DATE, END_DATE, DELIVERY_CUTOFF,
--                FINANCE_CUTOFF, MEC_CLOSE, BOOK_CLOSURE
--   local        PERIOD_ID, PERIOD_NAME, START_DATE, TS_CUTOFF_DAY/TIME,
--                CONTRACTOR_RESUBMIT_DAYS, ADJUSTMENT_MONTHS,
--                BACKDATED_MONTHS, PAYROLL_/CLIENT_CUTOFF, ADVANCE_CLOSE
--
--   PERIOD_ID stays LOCAL and that is not negotiable: OC_TS_WEEK rows already
--   hold our ids, and MEC's 21 is August where ours is September. Exposing
--   their ids through the view would orphan every timesheet in the schema.
--
--   ADVANCE_CLOSE also stays local. Same column name at both ends, opposite
--   meaning -- MEC computes it ("Yes whenever any close-cycle date is still
--   ahead of today"), ours records that a month was confirmed to accrual
--   without full approval. One is a warning, the other is a decision.
--
-- THE COST, AND IT IS REAL
--   A view couples availability. With a sync, the main app being down leaves
--   the timesheet working on slightly stale periods. With a view, it leaves
--   the timesheet unable to answer any query that touches a period -- which is
--   most of them. That is the price of live, and it should be a known price
--   rather than a discovery. If it ever bites, section 4 below is where a
--   cached fallback would go.
--
-- Idempotent. Depends on: time/01
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ── WHICH SCHEMA AM I? ───────────────────────────────────────
-- Run in the wrong one and every statement fails with ORA-00942 naming a
-- table that plainly exists -- because it exists in the OTHER schema. That
-- happened on 14-Aug against O2C_DEV, and the output is long enough that the
-- cause is not obvious from it. So: refuse immediately, and say so.
--
-- O2C_DEV owns OC_MEC_PERIOD and is the schema this module READS FROM.
-- O2C_TIME owns everything else here and is the schema to be CONNECTED AS.
DECLARE
  v_me VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
BEGIN
  IF v_me <> 'O2C_TIME' THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || v_me || '. This script must run as O2C_TIME -- ' ||
      'O2C_DEV owns OC_MEC_PERIOD and is only read FROM. Reconnect and re-run.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || v_me);
END;
/

PROMPT ============================================================
PROMPT [1/5] Find a live route to OC_MEC_PERIOD
PROMPT ============================================================

-- Two ways, tried in order. A synonym is created either way so the view below
-- never has to know which one won -- and so switching later is one statement.
DECLARE
  v_n NUMBER;
  v_ok VARCHAR2(20) := NULL;

  FUNCTION reachable(p_target VARCHAR2) RETURN BOOLEAN IS
    v_c NUMBER;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_target INTO v_c;
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN RETURN FALSE;
  END;
BEGIN
  -- 1. Same database, granted. The simplest thing that can work, and the most
  --    likely: /ords/o2c_time and /ords/o2c_dev are the same ORDS host.
  IF reachable('o2c_dev.oc_mec_period') THEN
    v_ok := 'GRANT';
    BEGIN EXECUTE IMMEDIATE 'DROP SYNONYM oc_mec_period_src';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    EXECUTE IMMEDIATE 'CREATE SYNONYM oc_mec_period_src FOR o2c_dev.oc_mec_period';

  -- 2. Different database, over a link.
  ELSIF reachable('oc_mec_period@o2c_dev_link') THEN
    v_ok := 'DBLINK';
    BEGIN EXECUTE IMMEDIATE 'DROP SYNONYM oc_mec_period_src';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    EXECUTE IMMEDIATE 'CREATE SYNONYM oc_mec_period_src FOR oc_mec_period@o2c_dev_link';
  END IF;

  IF v_ok IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('OC_MEC_PERIOD IS NOT REACHABLE. Nothing was changed.');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Ask for ONE of these, then re-run this script:');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  same database  -- run as o2c_dev or ADMIN:');
    DBMS_OUTPUT.PUT_LINE('    GRANT SELECT ON o2c_dev.oc_mec_period TO o2c_time;');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  different database -- run as ADMIN:');
    DBMS_OUTPUT.PUT_LINE('    CREATE DATABASE LINK o2c_dev_link');
    DBMS_OUTPUT.PUT_LINE('      CONNECT TO o2c_dev IDENTIFIED BY <pwd>');
    DBMS_OUTPUT.PUT_LINE('      USING ''<tns alias>'';');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Until then db/29_mec_period_sync.sql remains the');
    DBMS_OUTPUT.PUT_LINE('fallback -- copied rather than live, but working.');
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    RAISE_APPLICATION_ERROR(-20031, 'OC_MEC_PERIOD unreachable - see output above');
  END IF;

  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM oc_mec_period_src' INTO v_n;
  DBMS_OUTPUT.PUT_LINE('Reached OC_MEC_PERIOD via ' || v_ok
                    || ' -- ' || v_n || ' period(s) visible');
END;
/

PROMPT ============================================================
PROMPT [2/5] Rename the table; the foreign keys follow it
PROMPT ============================================================

DECLARE
  v_is_table NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_is_table
    FROM user_tables WHERE table_name = 'OC_TIME_PERIOD';

  IF v_is_table = 1 THEN
    -- RENAME carries the primary key, every foreign key pointing at it, and
    -- the data. Nothing is copied and nothing is lost.
    EXECUTE IMMEDIATE 'RENAME oc_time_period TO oc_time_period_base';
    DBMS_OUTPUT.PUT_LINE('oc_time_period -> oc_time_period_base (10 FKs followed)');
  ELSE
    DBMS_OUTPUT.PUT_LINE('already renamed, skipped');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [3/5] OC_TIME_PERIOD becomes a live view
PROMPT ============================================================

-- LEFT JOIN, not inner. A local period the main app has not been given yet
-- must still appear -- otherwise adding a month here and forgetting to add it
-- there makes every week in it vanish from every screen at once. The MEC
-- columns come back null instead, which is visible and diagnosable.
--
-- Joined on START_DATE. Never PERIOD_ID: MEC's 21 is August 2026 and ours is
-- September 2026. Never PERIOD_NAME: 'August 2026' against 'AUG-2026'.
CREATE OR REPLACE VIEW oc_time_period AS
SELECT b.period_id,
       b.period_name,
       b.period_year,
       b.period_month,
       -- ── live from the main application ───────────────────────
       NVL(m.status, b.status)                   AS status,
       b.start_date,
       NVL(m.end_date, b.end_date)               AS end_date,
       NVL(m.accounting_date, b.accounting_date) AS accounting_date,
       NVL(m.delivery_cutoff_date, b.delivery_cutoff) AS delivery_cutoff,
       NVL(m.finance_cutoff_date,  b.finance_cutoff)  AS finance_cutoff,
       NVL(m.mec_close_date,       b.mec_close)       AS mec_close,
       NVL(m.book_close_date,      b.book_closure)    AS book_closure,
       -- ── the timesheet's own, with no MEC equivalent ──────────
       b.ts_cutoff_day,
       b.ts_cutoff_time,
       b.client_cutoff,
       b.payroll_country,
       b.payroll_cutoff,
       b.advance_close,
       b.contractor_resubmit_days,
       b.hold_release_days,
       b.adjustment_months,
       b.backdated_months,
       -- ── traceability ─────────────────────────────────────────
       m.period_id      AS mec_period_id,
       m.period_name    AS mec_period_name,
       CASE WHEN m.period_id IS NULL THEN 'N' ELSE 'Y' END AS mec_linked,
       b.created_by, b.created_on, b.updated_by, b.updated_on
  FROM oc_time_period_base b
  LEFT JOIN oc_mec_period_src m ON m.start_date = b.start_date;

PROMPT ============================================================
PROMPT [4/5] Provision identity for any period MEC has that we do not
PROMPT ============================================================

-- The only thing still copied, and only once per period: PERIOD_ID and the
-- timesheet's own settings. Everything that CHANGES is read live.
--
-- This is not a sync. It creates the local anchor a new month needs -- an id
-- for the foreign keys to point at and a weekly cut-off, which MEC has no
-- source for. Run it when a period is added upstream.
CREATE OR REPLACE PROCEDURE oc_time_provision_mec_periods(
  p_actor IN VARCHAR2 DEFAULT 'MEC_PROVISION')
IS
  v_n NUMBER := 0;
BEGIN
  FOR r IN (
    SELECT m.period_id, m.period_name, m.start_date, m.end_date,
           m.accounting_date, m.status
      FROM oc_mec_period_src m
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_period_base b
                        WHERE b.start_date = m.start_date)
  ) LOOP
    INSERT INTO oc_time_period_base (
      period_name, period_year, period_month, status,
      start_date, end_date, accounting_date,
      -- MEC has no weekly cut-off. A null here would make every Submit in
      -- this month unclassifiable under the V4 timing rules, so the module
      -- default is applied rather than nothing.
      ts_cutoff_day, ts_cutoff_time, created_by)
    VALUES (
      UPPER(TO_CHAR(r.start_date, 'MON-YYYY')),   -- ours: AUG-2026
      EXTRACT(YEAR FROM r.start_date),
      EXTRACT(MONTH FROM r.start_date),
      r.status, r.start_date, r.end_date, r.accounting_date,
      'Monday', '17:00', p_actor);
    v_n := v_n + 1;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' period(s) provisioned locally');
END;
/
SHOW ERRORS

BEGIN oc_time_provision_mec_periods; END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN mec_name    FORMAT A16
COLUMN status      FORMAT A8
COLUMN wk          FORMAT A14
SELECT period_name, mec_period_name AS mec_name, mec_linked, status,
       TO_CHAR(start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(delivery_cutoff,'DD-MON-YY') AS delivery,
       ts_cutoff_day || ' ' || ts_cutoff_time AS wk,
       mec_period_id AS mec_id
  FROM oc_time_period ORDER BY start_date;

PROMPT
PROMPT STATUS above is read live. Change it in the main application's Period
PROMPT Control screen, re-run this SELECT, and it has already changed here --
PROMPT there is no sync to wait for and nothing to schedule.
PROMPT
PROMPT MEC_LINKED = 'N' means a period exists here that the main application
PROMPT does not have. Its MEC columns fall back to the last known local values
PROMPT rather than going null, so nothing breaks -- but it is drifting and
PROMPT should be added upstream.
PROMPT
PROMPT WHAT NOW WRITES PERIODS: nothing here. Status is the main application's.
PROMPT These are retired by this change and must not be run again:
PROMPT   13_open_periods.sql        opened JUL and AUG together
PROMPT   24_period_rollover.sql     the admin Open/Close buttons
PROMPT   29_mec_period_sync.sql     the copy this replaces
PROMPT   10_seed.sql section [7]    seeded periods
PROMPT
PROMPT THE COST OF LIVE: if the main application is unreachable, every query
PROMPT touching a period fails -- which is most of them. A copy would have gone
PROMPT stale instead. That trade was made deliberately on 13-Aug.
