--==============================================================
-- time/29_mec_period_sync.sql
-- O2C Timesheet Module — periods come from the main app, not from here
--
-- Decided 13-Aug-2026: OC_MEC_PERIOD in the O2C main application is
-- AUTHORITATIVE for period identity, status and the downstream cut-offs.
--   GET https://ords-sit.rite.digital/ords/o2c_dev/oc/period/mec-periods
--
-- This closes H5. Period control moves to the main app, which is where the
-- requirement always put it.
--
-- WHY OC_TIME_PERIOD SURVIVES AS A MIRROR RATHER THAN BEING DROPPED
--   PERIOD_ID is a foreign key on OC_TS_WEEK, OC_TS_MONTH_CONFIRM,
--   OC_TS_ENTRY and the accrual interface. Dropping the table means
--   re-pointing every one of those at a foreign id, which is a data migration
--   rather than a period-control change. So the table stays, stops being
--   AUTHORED, and becomes a synced mirror. Nothing writes to it but this.
--
-- MATCHED ON START_DATE. Never on PERIOD_ID -- measured 13-Aug, MEC's id 21 is
-- August 2026 and ours is September 2026. Syncing on the id would have
-- overwritten one month with another. Never on PERIOD_NAME either: theirs
-- reads 'August 2026', ours 'AUG-2026'.
--
-- FOUR COLUMNS MEC DOES NOT HAVE, and they are not oversights -- they are
-- the timesheet's own concerns and stay local:
--
--   TS_CUTOFF_DAY / TS_CUTOFF_TIME   the WEEKLY cut-off, Monday 17:00. The
--                                    employee deadline. Everything V4 does
--                                    with TIMING compares against this.
--   CONTRACTOR_RESUBMIT_DAYS         the 60-day contractor window
--   ADJUSTMENT_MONTHS / BACKDATED_MONTHS
--   PAYROLL_CUTOFF / CLIENT_CUTOFF
--
-- ADVANCE_CLOSE IS DELIBERATELY NOT TAKEN. Same name, opposite meaning: MEC
-- computes it ("Yes whenever any close-cycle date is still ahead of today"),
-- ours records a decision -- that a month was confirmed to accrual without
-- full approval. Copying theirs over ours would erase the record of a
-- deliberate act with a derived warning.
--
-- Idempotent. Depends on: time/01
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ── AM I IN THE SCHEMA THAT OWNS THIS MODULE? ────────────────
-- Checks for the module itself rather than for a schema NAME. The first
-- version of this guard hardcoded 'O2C_TIME' and was wrong: o2c_time in the
-- ORDS url is a URL MAPPING, and the module actually lives in O2C_DEV
-- alongside OC_MEC_PERIOD. A guard that asserts the wrong name blocks the
-- right schema, which is worse than no guard at all.
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') ||
      ', which does not own this module -- OC_TIME_WORKER is not here. ' ||
      'Connect as the schema holding the timesheet tables and re-run.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] Traceability columns
PROMPT ============================================================

DECLARE
  PROCEDURE addcol(p_col VARCHAR2, p_spec VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE oc_time_period ADD (' || p_col || ' ' || p_spec || ')';
    DBMS_OUTPUT.PUT_LINE(RPAD(p_col, 26) || 'added');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN DBMS_OUTPUT.PUT_LINE(RPAD(p_col, 26) || 'exists, skipped');
    ELSE RAISE; END IF;
  END;
BEGIN
  -- Their id and their name are kept for traceability and for nothing else.
  -- Ours stay the keys everything joins on.
  addcol('MEC_PERIOD_ID',   'NUMBER');
  addcol('MEC_PERIOD_NAME', 'VARCHAR2(60 CHAR)');
  addcol('MEC_SYNCED_ON',   'TIMESTAMP');
END;
/

PROMPT ============================================================
PROMPT [2/4] OC_TIME_MERGE_MEC_PERIODS — the merge
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_merge_mec_periods(
  p_json    IN  CLOB,
  p_actor   IN  VARCHAR2 DEFAULT 'MEC_SYNC',
  o_seen    OUT NUMBER,
  o_updated OUT NUMBER,
  o_created OUT NUMBER)
IS
  v_local NUMBER;
BEGIN
  o_seen := 0; o_updated := 0; o_created := 0;

  FOR r IN (
    -- The endpoint ignores ?status=, so the whole table is taken and filtered
    -- here. Confirmed 13-Aug: ?status=Closed returns the Open rows too, which
    -- is the dangerous kind of ignored -- it answers 200 rather than erroring.
    SELECT *
      FROM JSON_TABLE(p_json, '$.items[*]'
             COLUMNS (
               mec_id        NUMBER        PATH '$.period_id',
               mec_name      VARCHAR2(60)  PATH '$.period_name',
               status        VARCHAR2(20)  PATH '$.status',
               start_date    VARCHAR2(30)  PATH '$.start_date',
               end_date      VARCHAR2(30)  PATH '$.end_date',
               acct_date     VARCHAR2(30)  PATH '$.accounting_date',
               delivery_cut  VARCHAR2(30)  PATH '$.delivery_cutoff_date',
               finance_cut   VARCHAR2(30)  PATH '$.finance_cutoff_date',
               mec_close     VARCHAR2(30)  PATH '$.mec_close_date',
               book_close    VARCHAR2(30)  PATH '$.book_close_date'))
  ) LOOP
    o_seen := o_seen + 1;

    -- START_DATE is the join. It is the one field that cannot mean two things.
    BEGIN
      SELECT period_id INTO v_local
        FROM oc_time_period
       WHERE start_date = TO_DATE(SUBSTR(r.start_date,1,10), 'YYYY-MM-DD');
    EXCEPTION WHEN NO_DATA_FOUND THEN v_local := NULL;
    END;

    IF v_local IS NOT NULL THEN
      UPDATE oc_time_period SET
        status          = r.status,
        end_date        = TO_DATE(SUBSTR(r.end_date,1,10),'YYYY-MM-DD'),
        accounting_date = TO_DATE(SUBSTR(r.acct_date,1,10),'YYYY-MM-DD'),
        delivery_cutoff = TO_DATE(SUBSTR(r.delivery_cut,1,10),'YYYY-MM-DD'),
        finance_cutoff  = TO_DATE(SUBSTR(r.finance_cut,1,10),'YYYY-MM-DD'),
        mec_close       = TO_DATE(SUBSTR(r.mec_close,1,10),'YYYY-MM-DD'),
        book_closure    = TO_DATE(SUBSTR(r.book_close,1,10),'YYYY-MM-DD'),
        mec_period_id   = r.mec_id,
        mec_period_name = r.mec_name,
        mec_synced_on   = SYSTIMESTAMP,
        updated_by      = p_actor,
        updated_on      = SYSTIMESTAMP
        -- TS_CUTOFF_*, CONTRACTOR_RESUBMIT_DAYS, ADJUSTMENT_MONTHS,
        -- BACKDATED_MONTHS, PAYROLL_CUTOFF, CLIENT_CUTOFF and ADVANCE_CLOSE
        -- are absent on purpose. See the header.
       WHERE period_id = v_local;
      o_updated := o_updated + 1;

    ELSE
      -- PERIOD_NAME is derived from the date, not copied. Ours is 'AUG-2026'
      -- and appears on every screen and in every message; theirs is
      -- 'August 2026'. Copying it would leak the other application's format
      -- into this one's UI for no gain, and their name is kept beside it.
      INSERT INTO oc_time_period (
        period_name, period_year, period_month, status,
        start_date, end_date, accounting_date,
        ts_cutoff_day, ts_cutoff_time,
        delivery_cutoff, finance_cutoff, mec_close, book_closure,
        mec_period_id, mec_period_name, mec_synced_on, created_by)
      VALUES (
        UPPER(TO_CHAR(TO_DATE(SUBSTR(r.start_date,1,10),'YYYY-MM-DD'),'MON-YYYY')),
        EXTRACT(YEAR  FROM TO_DATE(SUBSTR(r.start_date,1,10),'YYYY-MM-DD')),
        EXTRACT(MONTH FROM TO_DATE(SUBSTR(r.start_date,1,10),'YYYY-MM-DD')),
        r.status,
        TO_DATE(SUBSTR(r.start_date,1,10),'YYYY-MM-DD'),
        TO_DATE(SUBSTR(r.end_date,1,10),'YYYY-MM-DD'),
        TO_DATE(SUBSTR(r.acct_date,1,10),'YYYY-MM-DD'),
        -- The weekly cut-off has no source in MEC, so a new period gets the
        -- module default rather than nothing. A null here would make every
        -- Submit in that month unclassifiable (V4 TIMING).
        'Monday', '17:00',
        TO_DATE(SUBSTR(r.delivery_cut,1,10),'YYYY-MM-DD'),
        TO_DATE(SUBSTR(r.finance_cut,1,10),'YYYY-MM-DD'),
        TO_DATE(SUBSTR(r.mec_close,1,10),'YYYY-MM-DD'),
        TO_DATE(SUBSTR(r.book_close,1,10),'YYYY-MM-DD'),
        r.mec_id, r.mec_name, SYSTIMESTAMP, p_actor);
      o_created := o_created + 1;
    END IF;
  END LOOP;

  -- Nothing is deleted. A local period MEC has never heard of is reported by
  -- the verification block below, not removed -- OC_TS_WEEK hangs off it and
  -- a cascade here would take real timesheets with it.
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] OC_TIME_FETCH_MEC_PERIODS — call it directly, if we can
PROMPT ============================================================

-- TWO WAYS IN, and the simpler one is worth trying first.
--
-- Both ORDS bases sit on the same host -- /ords/o2c_time and /ords/o2c_dev --
-- which usually means one database and two schemas. If so, no HTTP is needed
-- at all:
--
--     GRANT SELECT ON o2c_dev.oc_mec_period TO o2c_time;   -- as o2c_dev/ADMIN
--
-- and this whole procedure can be replaced by a SELECT. That removes the ACL,
-- the wallet, the network round trip and every failure mode that comes with
-- them. Ask for the grant before accepting the HTTP path.
--
-- Failing that, DBMS_CLOUD.SEND_REQUEST is the Autonomous way to reach https
-- without hand-building a wallet. It needs EXECUTE on DBMS_CLOUD and the host
-- in the ACL, so it may raise -- which is why the merge above takes a payload
-- and can be driven from ORDS or a script regardless.
CREATE OR REPLACE PROCEDURE oc_time_fetch_mec_periods(
  p_url   IN  VARCHAR2 DEFAULT
    'https://ords-sit.rite.digital/ords/o2c_dev/oc/period/mec-periods',
  p_actor IN  VARCHAR2 DEFAULT 'MEC_SYNC')
IS
  v_body CLOB;
  v_seen NUMBER; v_upd NUMBER; v_new NUMBER;
  v_sql  VARCHAR2(400);
BEGIN
  -- Called dynamically so this script still compiles where DBMS_CLOUD is not
  -- granted. A hard reference would make the whole procedure INVALID and take
  -- the payload path down with it.
  v_sql := 'BEGIN :b := DBMS_CLOUD.SEND_REQUEST(credential_name => NULL, '
        || 'uri => :u, method => ''GET'').response_body; END;';
  BEGIN
    EXECUTE IMMEDIATE v_sql USING OUT v_body, IN p_url;
  EXCEPTION WHEN OTHERS THEN
    RAISE_APPLICATION_ERROR(-20030,
      'Could not reach MEC over https (' || SUBSTR(SQLERRM,1,120) || '). '
      || 'Either grant SELECT on o2c_dev.oc_mec_period and read it directly, '
      || 'or POST the payload to admin/periods/mec-sync instead.');
  END;

  oc_time_merge_mec_periods(v_body, p_actor, v_seen, v_upd, v_new);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('MEC periods: ' || v_seen || ' seen, '
                    || v_upd || ' updated, ' || v_new || ' created');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN mec_name    FORMAT A16
COLUMN status      FORMAT A8
COLUMN wk_cutoff   FORMAT A16
SELECT p.period_name, p.mec_period_name AS mec_name, p.status,
       TO_CHAR(p.start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(p.delivery_cutoff,'DD-MON-YY') AS delivery,
       p.ts_cutoff_day || ' ' || p.ts_cutoff_time AS wk_cutoff,
       p.mec_period_id AS mec_id,
       TO_CHAR(p.mec_synced_on,'DD-MON HH24:MI') AS synced
  FROM oc_time_period p ORDER BY p.start_date;

PROMPT
PROMPT --- periods MEC has never heard of (not deleted, reported) ----
SELECT period_name, status, TO_CHAR(start_date,'DD-MON-YY') AS starts,
       (SELECT COUNT(*) FROM oc_ts_week w WHERE w.period_id = p.period_id) AS weeks
  FROM oc_time_period p WHERE p.mec_period_id IS NULL ORDER BY p.start_date;

PROMPT
PROMPT Anything listed above exists only here. Once MEC carries every period
PROMPT this should be empty -- and if a row has weeks against it, it cannot
PROMPT simply be removed either.
PROMPT
PROMPT WK_CUTOFF must never be blank. MEC has no weekly cut-off, so a period
PROMPT created by this sync takes the module default of Monday 17:00; a null
PROMPT would leave every Submit in that month unclassifiable under V4 TIMING.
