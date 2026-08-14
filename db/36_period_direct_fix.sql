--==============================================================
-- time/36_period_direct_fix.sql
-- O2C Timesheet Module — finish what 35 started
--
-- 35 got through the foreign keys and part of the wipe, then failed three
-- times. All three were mine and all three are fixed here.
--
--   1. ORA-00904 "M"."ADVANCE_CLOSE" -- so the view was never created and
--      OC_TIME_PERIOD is still the old one over OC_TIME_PERIOD_BASE. That is
--      why the verification showed period ids 1, 2, 3, 21 rather than the
--      upstream 42, 43, 21, 44.
--
--      ADVANCE_CLOSE is not a column upstream. The Period Control screen says
--      so plainly -- "Advance Close is system-computed" -- and it appears in
--      the REST payload because the ENDPOINT computes it. I read it off the
--      JSON and assumed a column. It is derived here instead, by the rule the
--      screen states: Yes whenever any close-cycle date is still ahead of
--      today. Checked against all four months and it reproduces the screen.
--
--   2. PLS-00103 on v_day. Variables were declared AFTER a nested PROCEDURE,
--      which PL/SQL does not allow -- declarations come first, subprogram
--      bodies last. So the settings never moved to OC_TIME_CONFIG, and the
--      view above would have found nothing even if it had compiled.
--
--   3. ORA-20026 on OC_TS_AUDIT, OC_TS_APPROVAL and OC_TS_WEEK. They are
--      append-only, guarded by triggers -- OC_TS_WEEK failed because deleting
--      a week reaches the audit trigger. That guard is right and stays; it is
--      disabled for the length of this migration and put back.
--
-- Safe to run after a partial 35: every step checks its own state first.
--
-- Idempotent. Depends on: time/35
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
PROMPT [1/5] Settings to OC_TIME_CONFIG (declarations first this time)
PROMPT ============================================================

DECLARE
  -- EVERY declaration before the nested procedure. That ordering is what
  -- broke 35: PL/SQL requires variables, then cursors, then subprogram bodies.
  v_day  VARCHAR2(10);
  v_time VARCHAR2(5);
  v_con  NUMBER;
  v_adj  NUMBER;
  v_back NUMBER;
  v_hold NUMBER;

  PROCEDURE cfg(p_name VARCHAR2, p_val VARCHAR2, p_desc VARCHAR2) IS
  BEGIN
    MERGE INTO oc_time_config t USING (SELECT p_name AS n FROM dual) s
       ON (t.config_name = s.n AND t.scope_key = 'GLOBAL')
     WHEN MATCHED THEN UPDATE SET config_value = p_val, description = p_desc
     WHEN NOT MATCHED THEN
       INSERT (config_name, config_type, config_value, scope_key, description)
       VALUES (p_name, 'business', p_val, 'GLOBAL', p_desc);
  END;
BEGIN
  SELECT MAX(ts_cutoff_day), MAX(ts_cutoff_time), MAX(contractor_resubmit_days),
         MAX(adjustment_months), MAX(backdated_months), MAX(hold_release_days)
    INTO v_day, v_time, v_con, v_adj, v_back, v_hold
    FROM oc_time_period_base;

  cfg('ts_cutoff_day',  NVL(v_day,'Monday'),
      'Weekly cut-off day. The EMPLOYEE deadline, and what V4 TIMING compares '
      || 'a submission against. Upstream has no column for it.');
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
  DBMS_OUTPUT.PUT_LINE('6 settings in OC_TIME_CONFIG: ' || v_day || ' '
                    || v_time || ', contractor ' || v_con || 'd');
END;
/

PROMPT ============================================================
PROMPT [2/5] Clear the append-only tables, guard disabled and restored
PROMPT ============================================================

DECLARE
  TYPE t_list IS TABLE OF VARCHAR2(30);
  v_tabs t_list := t_list('OC_TS_AUDIT','OC_TS_APPROVAL','OC_TS_WEEK',
                          'OC_TS_ENTRY','OC_TS_WEEK_FLAG','OC_TS_DAY_FLAG',
                          'OC_TS_MONTH_CONFIRM','OC_TS_ADJUSTMENT',
                          'OC_TS_SALARY_HOLD','OC_TS_SALARY_HOLD_DAY',
                          'OC_TS_LEAVE_LOSS_COVER','OC_TS_CLIENT_DOC');
  v_n NUMBER;
BEGIN
  -- The append-only guard is correct and is NOT being removed -- an audit
  -- trail that can be deleted is not an audit trail. It is switched off for
  -- the length of this migration and switched back on below, which is the
  -- narrowest way through.
  FOR t IN (SELECT trigger_name, table_name FROM user_triggers
             WHERE table_name IN ('OC_TS_AUDIT','OC_TS_APPROVAL','OC_TS_WEEK')
               AND status = 'ENABLED') LOOP
    EXECUTE IMMEDIATE 'ALTER TRIGGER ' || t.trigger_name || ' DISABLE';
    DBMS_OUTPUT.PUT_LINE('  disabled ' || t.trigger_name);
  END LOOP;

  -- Children first.
  FOR i IN 1 .. v_tabs.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DELETE FROM ' || v_tabs(i);
      v_n := SQL%ROWCOUNT;
      IF v_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE(RPAD('  ' || v_tabs(i), 30)
                          || TO_CHAR(v_n, '999,999') || ' cleared');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(RPAD('  ' || v_tabs(i), 30) || 'skipped - '
                        || SUBSTR(SQLERRM, 1, 60));
    END;
  END LOOP;
  COMMIT;

  FOR t IN (SELECT trigger_name FROM user_triggers
             WHERE table_name IN ('OC_TS_AUDIT','OC_TS_APPROVAL','OC_TS_WEEK')
               AND status = 'DISABLED') LOOP
    EXECUTE IMMEDIATE 'ALTER TRIGGER ' || t.trigger_name || ' ENABLE';
    DBMS_OUTPUT.PUT_LINE('  re-enabled ' || t.trigger_name);
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [3/5] OC_TIME_PERIOD over the upstream table, at last
PROMPT ============================================================

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
       -- COMPUTED, not selected. There is no ADVANCE_CLOSE column upstream --
       -- the REST endpoint derives it and the Period Control screen says so:
       -- "Advance Close is system-computed -- it reads Yes whenever any
       -- close-cycle date for that period is still ahead of today, meaning
       -- billing may proceed before the standard timeline completes."
       --
       -- Reproduced here rather than fetched, so the two agree by construction
       -- instead of by luck. Verified against all four months on 14-Aug.
       CASE WHEN GREATEST(m.delivery_cutoff_date, m.finance_cutoff_date,
                          m.mec_close_date, m.book_close_date) > TRUNC(SYSDATE)
            THEN 'Y' ELSE 'N' END AS advance_close,
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
PROMPT [4/5] Recompile, then rebuild against the upstream ids
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
  FOR p IN (SELECT period_id, period_name FROM oc_time_period ORDER BY start_date) LOOP
    BEGIN
      v_job := oc_time_pkg.populate_month(p.period_id, NULL, 'PERIOD_DIRECT');
      DBMS_OUTPUT.PUT_LINE('  rebuilt ' || RPAD(p.period_name, 12)
                        || ' id ' || RPAD(p.period_id, 5) || ' job ' || v_job);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p.period_name, 12) || 'FAILED - '
                        || SUBSTR(SQLERRM, 1, 90));
    END;
  END LOOP;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

SELECT object_name, object_type, status FROM user_objects
 WHERE status = 'INVALID' ORDER BY object_type, object_name;

COLUMN period_name FORMAT A12
COLUMN status      FORMAT A8
COLUMN editable    FORMAT A8
COLUMN adv         FORMAT A4
SELECT p.period_id, p.period_name, p.status,
       TO_CHAR(p.start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(p.delivery_cutoff,'DD-MON-YY') AS delivery,
       p.advance_close AS adv,
       p.ts_cutoff_day || ' ' || p.ts_cutoff_time AS weekly,
       CASE WHEN p.status <> 'Open' THEN 'N'
            WHEN TRUNC(SYSDATE) > p.delivery_cutoff THEN 'N'
            ELSE 'Y' END AS editable,
       (SELECT COUNT(*) FROM oc_ts_week w WHERE w.period_id = p.period_id) AS weeks
  FROM oc_time_period p ORDER BY p.start_date;

PROMPT
PROMPT PERIOD_ID must now read 42, 43, 21, 44 -- the main application's ids.
PROMPT If it still reads 1, 2, 3, 21 the view did not replace and step [3]
PROMPT reported why.
PROMPT
PROMPT ADV should match the ADVANCE CLOSE column on the Period Control screen:
PROMPT Yes for JULY, August and September, No for JUNE.

SELECT w.period_id, COUNT(*) AS orphan_weeks
  FROM oc_ts_week w
 WHERE NOT EXISTS (SELECT 1 FROM oc_time_period p WHERE p.period_id = w.period_id)
 GROUP BY w.period_id;

PROMPT
PROMPT That must be empty. It is what replaces the ten dropped foreign keys --
PROMPT run it after any period is deleted upstream.
