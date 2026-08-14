--==============================================================
-- time/33_repair_after_cleanup.sql
-- O2C Timesheet Module — put back what 32 removed, and revalidate
--
-- WHAT WENT WRONG, 14-Aug-2026
--   30 renamed OC_TIME_PERIOD to OC_TIME_PERIOD_BASE and created the view --
--   but the grant on OC_MEC_PERIOD was not yet in place, so the view compiled
--   INVALID. Oracle reports an invalid view as ORA-00942 when it is reached
--   through a %TYPE reference, which is what 31 then hit.
--
--   That was misread as "connected to the wrong schema". It was not. The
--   module lives in the SAME schema as OC_MEC_PERIOD, and 'o2c_time' in the
--   ORDS url is a URL MAPPING rather than a schema name -- the object listing
--   32 printed proves it: OC_TIME_WORKER, OC_TIME_PKG and OC_TIME_PERIOD_BASE
--   are all right there.
--
--   32, written on that wrong diagnosis, then dropped the live view. Net
--   effect: no OC_TIME_PERIOD at all, and everything reading it INVALID --
--   the package body, V_OC_TIME_SIGNIN, V_OC_TIME_CUTOFFS and the rest.
--   Sign-in included.
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
BEGIN
  BEGIN EXECUTE IMMEDIATE 'DROP SYNONYM oc_mec_period_src';
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Unqualified: OC_MEC_PERIOD is in this schema, or granted and visible.
  EXECUTE IMMEDIATE 'CREATE SYNONYM oc_mec_period_src FOR oc_mec_period';
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM oc_mec_period_src' INTO v_c;
  DBMS_OUTPUT.PUT_LINE('oc_mec_period_src -> oc_mec_period, ' || v_c || ' period(s)');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('Could not reach OC_MEC_PERIOD: ' || SUBSTR(SQLERRM,1,140));
  RAISE;
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
