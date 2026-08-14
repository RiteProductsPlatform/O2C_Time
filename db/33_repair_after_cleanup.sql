--==============================================================
-- time/33_repair_after_cleanup.sql
-- O2C Timesheet Module — put back what 32 removed, and revalidate
--
-- WHAT WENT WRONG, 14-Aug-2026 -- three mistakes, all mine
--
--   1. 30 renamed OC_TIME_PERIOD to OC_TIME_PERIOD_BASE and created the view
--      while the grant on OC_MEC_PERIOD was still missing, so the view
--      compiled INVALID. Oracle reports an invalid view as ORA-00942 through
--      a type reference, which is what 31 hit.
--
--   2. I read the "O2C_DEV.OC_TIME_OPEN_PERIOD" in 31's error as proof of the
--      wrong schema and wrote 32 to clean up. Run against O2C_TIME -- where
--      the module actually lives -- it dropped the LIVE view and took
--      nineteen objects down with it, sign-in included.
--
--   3. Correcting that, I flipped the synonym from o2c_dev.oc_mec_period to
--      the bare name, on a second wrong belief that the module sat beside
--      OC_MEC_PERIOD. It does not. The grant makes the QUALIFIED name visible
--      from O2C_TIME and leaves the bare one unresolvable, so the synonym
--      created cleanly and then failed with ORA-00980 -- an error that reads
--      like a broken synonym and is really a missing schema prefix.
--
--   The through-line: each fix was built on an inference from an error
--   message rather than on a check. Step [1] now TRIES each candidate with a
--   real query and keeps the one that answers, which is what should have
--   happened at the start.
--
-- WHAT THIS DOES
--   Recreates what 32 dropped, now the grant exists, then recompiles
--   everything that went invalid. Re-running 30 does the same work; this
--   carries the diagnosis with it.
--
-- Idempotent. Depends on: time/30
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Checks for the MODULE, not for a schema name. The first version of this
-- guard asserted 'O2C_TIME' and would have blocked the only schema able to
-- run this -- a guard that is confidently wrong is worse than none.
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
PROMPT [1/4] The synonym 32 dropped
PROMPT ============================================================

DECLARE
  v_c NUMBER;
  v_target VARCHAR2(100) := NULL;

  -- Tries each candidate and keeps the first that actually SELECTS. Creating
  -- the synonym is not proof: CREATE SYNONYM succeeds against a name that does
  -- not resolve, and only fails later with ORA-00980. So the test is a query.
  FUNCTION works(p_target VARCHAR2) RETURN BOOLEAN IS
    v_n NUMBER;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_target INTO v_n;
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN RETURN FALSE;
  END;
BEGIN
  -- QUALIFIED FIRST. The module is in O2C_TIME and OC_MEC_PERIOD is in
  -- O2C_DEV, so the grant makes o2c_dev.oc_mec_period visible but leaves the
  -- bare name unresolvable. An earlier version of this script used the bare
  -- name and failed with ORA-00980 -- which reads like a broken synonym and
  -- is really a missing schema prefix.
  IF    works('o2c_dev.oc_mec_period') THEN v_target := 'o2c_dev.oc_mec_period';
  ELSIF works('oc_mec_period')          THEN v_target := 'oc_mec_period';
  ELSIF works('oc_mec_period@o2c_dev_link') THEN v_target := 'oc_mec_period@o2c_dev_link';
  END IF;

  IF v_target IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('OC_MEC_PERIOD is not readable from '
                      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || '.');
    DBMS_OUTPUT.PUT_LINE('Tried: o2c_dev.oc_mec_period, oc_mec_period,');
    DBMS_OUTPUT.PUT_LINE('       oc_mec_period@o2c_dev_link');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Run as o2c_dev or ADMIN, then re-run this script:');
    DBMS_OUTPUT.PUT_LINE('  GRANT SELECT ON o2c_dev.oc_mec_period TO o2c_time;');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('A grant to a ROLE will not do -- a view compiled by');
    DBMS_OUTPUT.PUT_LINE('this schema needs the privilege granted DIRECTLY.');
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    RAISE_APPLICATION_ERROR(-20032, 'OC_MEC_PERIOD unreadable - see output above');
  END IF;

  BEGIN EXECUTE IMMEDIATE 'DROP SYNONYM oc_mec_period_src';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  EXECUTE IMMEDIATE 'CREATE SYNONYM oc_mec_period_src FOR ' || v_target;

  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM oc_mec_period_src' INTO v_c;
  DBMS_OUTPUT.PUT_LINE('oc_mec_period_src -> ' || v_target
                    || '   (' || v_c || ' period(s))');
END;
/

PROMPT ============================================================
PROMPT [2/4] OC_TIME_PERIOD — the view 32 dropped
PROMPT ============================================================

CREATE OR REPLACE VIEW oc_time_period AS
SELECT b.period_id, b.period_name, b.period_year, b.period_month,
       NVL(m.status, b.status)                        AS status,
       b.start_date,
       NVL(m.end_date, b.end_date)                    AS end_date,
       NVL(m.accounting_date, b.accounting_date)      AS accounting_date,
       NVL(m.delivery_cutoff_date, b.delivery_cutoff) AS delivery_cutoff,
       NVL(m.finance_cutoff_date,  b.finance_cutoff)  AS finance_cutoff,
       NVL(m.mec_close_date,       b.mec_close)       AS mec_close,
       NVL(m.book_close_date,      b.book_closure)    AS book_closure,
       b.ts_cutoff_day, b.ts_cutoff_time,
       b.client_cutoff, b.payroll_country, b.payroll_cutoff,
       b.advance_close, b.contractor_resubmit_days, b.hold_release_days,
       b.adjustment_months, b.backdated_months,
       m.period_id   AS mec_period_id,
       m.period_name AS mec_period_name,
       CASE WHEN m.period_id IS NULL THEN 'N' ELSE 'Y' END AS mec_linked,
       b.created_by, b.created_on, b.updated_by, b.updated_on
  FROM oc_time_period_base b
  LEFT JOIN oc_mec_period_src m ON m.start_date = b.start_date;

PROMPT ============================================================
PROMPT [3/4] Recompile everything that went invalid
PROMPT ============================================================

DECLARE
  v_before NUMBER;
  v_after  NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_before FROM user_objects WHERE status = 'INVALID';
  DBMS_OUTPUT.PUT_LINE('invalid before: ' || v_before);

  -- Two passes. Working out the dependency order is not worth it when a
  -- second pass fixes whatever the first could not see yet.
  FOR pass IN 1 .. 2 LOOP
    FOR o IN (SELECT object_name, object_type FROM user_objects
               WHERE status = 'INVALID'
                 AND object_type IN ('VIEW','PROCEDURE','FUNCTION',
                                     'PACKAGE','PACKAGE BODY','TRIGGER')
               ORDER BY CASE object_type WHEN 'VIEW'    THEN 1
                                         WHEN 'PACKAGE' THEN 2
                                         ELSE 3 END) LOOP
      BEGIN
        IF o.object_type = 'PACKAGE BODY' THEN
          EXECUTE IMMEDIATE 'ALTER PACKAGE ' || o.object_name || ' COMPILE BODY';
        ELSE
          EXECUTE IMMEDIATE 'ALTER ' || o.object_type || ' ' ||
                            o.object_name || ' COMPILE';
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;   -- the count below is the report
      END;
    END LOOP;
  END LOOP;

  SELECT COUNT(*) INTO v_after FROM user_objects WHERE status = 'INVALID';
  DBMS_OUTPUT.PUT_LINE('invalid after : ' || v_after);
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A34
COLUMN object_type FORMAT A14
SELECT object_name, object_type, status
  FROM user_objects WHERE status = 'INVALID'
 ORDER BY object_type, object_name;

PROMPT
PROMPT Nothing above is the right answer. Anything left needs SHOW ERRORS.

COLUMN period_name FORMAT A12
COLUMN mec_name    FORMAT A16
COLUMN status      FORMAT A8
SELECT period_name, status, mec_linked, mec_period_name AS mec_name,
       TO_CHAR(start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(delivery_cutoff,'DD-MON-YY') AS delivery,
       ts_cutoff_day || ' ' || ts_cutoff_time AS weekly
  FROM oc_time_period ORDER BY start_date;

PROMPT
PROMPT MEC_LINKED 'Y' means the row is reading the main application live.
PROMPT STATUS is theirs now — change it on their Period Control screen and it
PROMPT has already changed here, with no sync to wait for.
