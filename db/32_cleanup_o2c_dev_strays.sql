--==============================================================
-- DO NOT RUN THIS. Superseded 14-Aug-2026 by db/33_repair_after_cleanup.sql.
--
-- It was written on a wrong diagnosis -- that 30 and 31 had been run in the
-- wrong schema. They had not. The module lives in the SAME schema as
-- OC_MEC_PERIOD; 'o2c_time' in the ORDS url is a URL mapping, not a schema
-- name. Run here, this script drops the LIVE OC_TIME_PERIOD view and takes
-- sign-in down with it.
--
-- Kept only so the incident is legible. 33 undoes it.
--==============================================================
/*
--==============================================================
-- Run this AS O2C_DEV. It removes the timesheet objects that
-- 30/31 created there by mistake on 14-Aug.
--
-- Nothing here belongs to O2C_DEV. OC_MEC_PERIOD is untouched.
--==============================================================
SET SERVEROUTPUT ON
DECLARE
  TYPE t IS TABLE OF VARCHAR2(100);
  v t := t(
    'DROP VIEW oc_time_period',
    'DROP VIEW v_oc_time_period_admin',
    'DROP FUNCTION oc_time_open_period',
    'DROP FUNCTION oc_time_close_period',
    'DROP PROCEDURE oc_time_provision_mec_periods',
    'DROP PROCEDURE oc_time_merge_mec_periods',
    'DROP PROCEDURE oc_time_fetch_mec_periods',
    'DROP SYNONYM oc_mec_period_src');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE v(i);
      DBMS_OUTPUT.PUT_LINE('dropped : ' || v(i));
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('skipped : ' || v(i) || '  (' || SQLCODE || ')');
    END;
  END LOOP;
END;
/
-- Must return NO ROWS. Anything listed is still stray in O2C_DEV.
SELECT object_name, object_type, status FROM user_objects
 WHERE object_name LIKE 'OC_TIME%' OR object_name LIKE 'V_OC_TIME%'
    OR object_name = 'OC_MEC_PERIOD_SRC'
 ORDER BY object_type, object_name;

*/
