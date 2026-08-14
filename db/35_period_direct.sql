--==============================================================
-- time/35_period_direct.sql
-- O2C Timesheet Module — O2C_DEV.OC_MEC_PERIOD *is* the period table
--
-- Decided 14-Aug-2026. Not a mirror, not a sync, not an anchor row. The main
-- application's table IS period control from here, and this module reads it
-- directly. OC_TIME_PERIOD becomes a view over it and nothing else.
--
-- THE SIMPLIFICATION THAT MAKES THIS EASY
--   An earlier draft went to some trouble to REMAP every existing PERIOD_ID so
--   no timesheet was orphaned. That was effort spent protecting data that does
--   not need protecting: OC_TS_WEEK and OC_TS_ENTRY are DERIVED. They are
--   built by populate_month from allocations and the calendar, and rebuilding
--   them is one call.
--
--   So: take the upstream ids as they are, clear what referenced the old ones,
--   and repopulate. Simpler, and it leaves nothing translating between two id
--   spaces forever.
--
--   WHAT THAT COSTS: hours an employee typed, submissions, approvals and
--   rejections in the affected periods. Everything prepopulated comes back
--   identical; everything a person did does not. That is fine in a schema
--   being built and is NOT fine once anyone is really using it -- so this
--   script is a one-time migration, not a tool.
--
-- THE SETTINGS THAT LOOKED LIKE PERIOD DATA
--   TS_CUTOFF_DAY, TS_CUTOFF_TIME, CONTRACTOR_RESUBMIT_DAYS,
--   ADJUSTMENT_MONTHS, BACKDATED_MONTHS, HOLD_RELEASE_DAYS were stored per
--   period and are identical in every one of them -- 10_seed.sql writes
--   'Monday', '17:00', 60, 3, 3 each time. They are module settings and move
--   to OC_TIME_CONFIG. The upstream table has no column for them and should
--   not: the weekly cut-off is this module's business.
--
-- THE FOREIGN KEYS GO
--   A view cannot be their target. The constraint stopped a week pointing at a
--   period that does not exist -- but the main application can delete a period
--   we hold weeks against and no constraint of ours would stop it. The
--   guarantee left when ownership did. Step [6] prints the query that replaces
--   it.
--
-- Reversible: OC_TIME_PERIOD_BASE is kept, holding the old rows and old ids.
--
-- Idempotent. Depends on: time/33
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/6] What is upstream, and what is about to be rebuilt
PROMPT ============================================================

COLUMN period_name FORMAT A16
COLUMN status      FORMAT A8
SELECT period_id, period_name, status,
       TO_CHAR(start_date,'DD-MON-YY')           AS starts,
       TO_CHAR(delivery_cutoff_date,'DD-MON-YY') AS delivery
  FROM oc_mec_period_src ORDER BY start_date;

PROMPT
PROMPT --- transactions that will be cleared and rebuilt
SELECT 'oc_ts_week'  AS table_name, COUNT(*) AS rows_ FROM oc_ts_week
UNION ALL SELECT 'oc_ts_entry',     COUNT(*) FROM oc_ts_entry
UNION ALL SELECT 'oc_ts_approval',  COUNT(*) FROM oc_ts_approval
UNION ALL SELECT 'oc_ts_audit',     COUNT(*) FROM oc_ts_audit;

PROMPT
PROMPT Prepopulated hours come back identically. Anything a PERSON did
PROMPT typed hours, submissions, approvals, rejections -- does not.

PROMPT ============================================================
PROMPT [2/6] Module settings out of the period row
PROMPT ============================================================

DECLARE
  PROCEDURE cfg(p_name VARCHAR2, p_val VARCHAR2, p_desc VARCHAR2) IS
  BEGIN
    MERGE INTO oc_time_config t USING (SELECT p_name AS n FROM dual) s
       ON (t.config_name = s.n AND t.scope_key = 'GLOBAL')
     WHEN MATCHED THEN UPDATE SET config_value = p_val, description = p_desc
     WHEN NOT MATCHED THEN
       INSERT (config_name, config_type, config_value, scope_key, description)
       VALUES (p_name, 'business', p_val, 'GLOBAL', p_desc);
  END;
  v_day VARCHAR2(10); v_time VARCHAR2(5);
  v_con NUMBER; v_adj NUMBER; v_back NUMBER; v_hold NUMBER;
BEGIN
  -- Read from the existing rows, not hardcoded, so a hand-tuned schema keeps
  -- its values. They are identical across periods; MAX picks the shared one.
  SELECT MAX(ts_cutoff_day), MAX(ts_cutoff_time), MAX(contractor_resubmit_days),
         MAX(adjustment_months), MAX(backdated_months), MAX(hold_release_days)
    INTO v_day, v_time, v_con, v_adj, v_back, v_hold
    FROM oc_time_period_base;

  cfg('ts_cutoff_day',  NVL(v_day,'Monday'),
      'Weekly cut-off day -- the EMPLOYEE deadline, and what V4 TIMING '
      || 'compares a submission against. Upstream has no column for it.');
  cfg('ts_cutoff_time', NVL(v_time,'17:00'), 'Weekly cut-off time, 24h.');
  cfg('contractor_resubmit_days', TO_CHAR(NVL(v_con,60)),
      'How far back a contractor may resubmit, in calendar days.');
  cfg('adjustment_months', TO_CHAR(NVL(v_adj,3)),
      'How many closed months back an adjustment may be raised.');
  cfg('backdated_months',  TO_CHAR(NVL(v_back,3)),
      'How far back a backdated change is accepted.');
  cfg('hold_release_days', TO_CHAR(NVL(v_hold,60)),
      'Days before an unresolved salary hold auto-releases.');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('6 settings moved to OC_TIME_CONFIG (GLOBAL)');
END;
/

PROMPT ============================================================
PROMPT [3/6] Drop the foreign keys, clear what held the old ids
PROMPT ============================================================

DECLARE
  v_n NUMBER := 0;
  PROCEDURE wipe(p_table VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'DELETE FROM ' || p_table;
    DBMS_OUTPUT.PUT_LINE(RPAD('  ' || p_table, 32)
                      || TO_CHAR(SQL%ROWCOUNT, '999,999') || ' cleared');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE(RPAD('  ' || p_table, 32) || 'skipped - '
                      || SUBSTR(SQLERRM,1,50));
  END;
BEGIN
  -- Discovered, not listed. A hardcoded list goes stale, and nothing may
  -- reference the base table once the view replaces it.
  FOR c IN (SELECT c.table_name, c.constraint_name
              FROM user_constraints c
              JOIN user_constraints p ON p.constraint_name = c.r_constraint_name
             WHERE c.constraint_type = 'R'
               AND p.table_name = 'OC_TIME_PERIOD_BASE') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE ' || c.table_name
                   || ' DROP CONSTRAINT ' || c.constraint_name;
    DBMS_OUTPUT.PUT_LINE('  dropped FK ' || c.constraint_name
                      || ' on ' || c.table_name);
    v_n := v_n + 1;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(v_n || ' foreign key(s) dropped');
  DBMS_OUTPUT.PUT_LINE('');

  -- Children first. Everything here is derived and comes back from populate.
  wipe('oc_ts_audit');
  wipe('oc_ts_leave_loss_cover');
  wipe('oc_ts_salary_hold_day');
  wipe('oc_ts_salary_hold');
  wipe('oc_ts_adjustment');
  wipe('oc_ts_approval');
  wipe('oc_ts_month_confirm');
  wipe('oc_ts_day_flag');
  wipe('oc_ts_week_flag');
  wipe('oc_ts_entry');
  wipe('oc_ts_week');
  wipe('xx_o2c_timesheet_accrual_if');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/6] OC_TIME_PERIOD — the upstream table, directly
PROMPT ============================================================

-- No local table in the FROM. Add a period upstream and it is here on the next
-- query: nothing to provision, nothing to sync, nothing to remember.
--
-- PERIOD_NAME is derived rather than taken. Theirs reads 'August 2026'; every
-- screen and message in this module reads 'AUG-2026'. Their name is carried
-- alongside so nothing is hidden.
CREATE OR REPLACE VIEW oc_time_period AS
SELECT m.period_id,
       UPPER(TO_CHAR(m.start_date, 'MON-YYYY'))  AS period_name,
       EXTRACT(YEAR  FROM m.start_date)          AS period_year,
       EXTRACT(MONTH FROM m.start_date)          AS period_month,
       m.status,
       m.start_date,
       m.end_date,
       m.accounting_date,
       m.delivery_cutoff_date AS delivery_cutoff,
       m.finance_cutoff_date  AS finance_cutoff,
       m.mec_close_date       AS mec_close,
       m.book_close_date      AS book_closure,
       c.ts_cutoff_day,
       c.ts_cutoff_time,
       CAST(NULL AS DATE)              AS client_cutoff,
       CAST(NULL AS VARCHAR2(60 CHAR)) AS payroll_country,
       CAST(NULL AS DATE)              AS payroll_cutoff,
       -- Theirs, and it means what THEY mean by it: any close-cycle date still
       -- ahead of today. This module used to record something different in a
       -- column of the same name -- that a month went to accrual without full
       -- approval -- and that record lives on OC_TS_MONTH_CONFIRM.CONFIRM_TYPE,
       -- which is where its detail always was.
       m.advance_close,
       c.contractor_resubmit_days,
       c.hold_release_days,
       c.adjustment_months,
       c.backdated_months,
       m.period_id   AS mec_period_id,
       m.period_name AS mec_period_name,
       'Y'           AS mec_linked,
       m.created_by, m.created_on, m.updated_by, m.updated_on
  FROM oc_mec_period_src m
 CROSS JOIN (
       SELECT MAX(CASE WHEN config_name='ts_cutoff_day'  THEN config_value END) AS ts_cutoff_day,
              MAX(CASE WHEN config_name='ts_cutoff_time' THEN config_value END) AS ts_cutoff_time,
              MAX(CASE WHEN config_name='contractor_resubmit_days' THEN TO_NUMBER(config_value) END) AS contractor_resubmit_days,
              MAX(CASE WHEN config_name='hold_release_days'        THEN TO_NUMBER(config_value) END) AS hold_release_days,
              MAX(CASE WHEN config_name='adjustment_months'        THEN TO_NUMBER(config_value) END) AS adjustment_months,
              MAX(CASE WHEN config_name='backdated_months'         THEN TO_NUMBER(config_value) END) AS backdated_months
         FROM oc_time_config WHERE scope_key = 'GLOBAL') c;

PROMPT ============================================================
PROMPT [5/6] Recompile, then rebuild every period from Fusion
PROMPT ============================================================

DECLARE
  v_after NUMBER;
BEGIN
  FOR pass IN 1 .. 2 LOOP
    FOR o IN (SELECT object_name, object_type FROM user_objects
               WHERE status = 'INVALID'
                 AND object_type IN ('VIEW','PROCEDURE','FUNCTION',
                                     'PACKAGE','PACKAGE BODY','TRIGGER')
               ORDER BY CASE object_type WHEN 'VIEW' THEN 1
                                         WHEN 'PACKAGE' THEN 2 ELSE 3 END) LOOP
      BEGIN
        IF o.object_type = 'PACKAGE BODY' THEN
          EXECUTE IMMEDIATE 'ALTER PACKAGE ' || o.object_name || ' COMPILE BODY';
        ELSE
          EXECUTE IMMEDIATE 'ALTER ' || o.object_type || ' ' || o.object_name || ' COMPILE';
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END LOOP;
  SELECT COUNT(*) INTO v_after FROM user_objects WHERE status = 'INVALID';
  DBMS_OUTPUT.PUT_LINE('invalid after recompile: ' || v_after);
END;
/

DECLARE
  v_job NUMBER;
BEGIN
  -- Every period upstream, not just the open one. A closed month still needs
  -- its weeks to exist so the screens can show it read-only, and so month-end
  -- has something to confirm.
  FOR p IN (SELECT period_id, period_name FROM oc_time_period ORDER BY start_date) LOOP
    BEGIN
      v_job := oc_time_pkg.populate_month(p.period_id, NULL, 'PERIOD_DIRECT');
      DBMS_OUTPUT.PUT_LINE('  rebuilt ' || RPAD(p.period_name, 12) || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p.period_name, 12) || 'FAILED - '
                        || SUBSTR(SQLERRM, 1, 90));
    END;
  END LOOP;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [6/6] Verification
PROMPT ============================================================

SELECT object_name, object_type, status FROM user_objects
 WHERE status = 'INVALID' ORDER BY object_type, object_name;

COLUMN period_name FORMAT A12
COLUMN status      FORMAT A8
COLUMN editable    FORMAT A8
SELECT p.period_id, p.period_name, p.status,
       TO_CHAR(p.start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(p.delivery_cutoff,'DD-MON-YY') AS delivery,
       p.ts_cutoff_day || ' ' || p.ts_cutoff_time AS weekly,
       CASE WHEN p.status <> 'Open' THEN 'N'
            WHEN TRUNC(SYSDATE) > p.delivery_cutoff THEN 'N'
            ELSE 'Y' END AS editable,
       (SELECT COUNT(*) FROM oc_ts_week w WHERE w.period_id = p.period_id) AS weeks,
       (SELECT COUNT(DISTINCT w.employee_id) FROM oc_ts_week w
         WHERE w.period_id = p.period_id) AS people
  FROM oc_time_period p ORDER BY p.start_date;

PROMPT
PROMPT --- weeks on an id no period has (must be empty)
SELECT w.period_id, COUNT(*) AS weeks
  FROM oc_ts_week w
 WHERE NOT EXISTS (SELECT 1 FROM oc_time_period p WHERE p.period_id = w.period_id)
 GROUP BY w.period_id;

PROMPT
PROMPT PERIOD_ID is now the main application's own id. Add a period there and
PROMPT it is here immediately -- then run populate_month for it, or let the
PROMPT monthly job do it.
PROMPT
PROMPT The query above replaces the dropped foreign keys. Run it after any
PROMPT upstream deletion; it is the only thing left that would notice.
PROMPT
PROMPT OC_TIME_PERIOD_BASE still holds the old rows and old ids. Drop it once
PROMPT this is proven -- until then it is the way back.
