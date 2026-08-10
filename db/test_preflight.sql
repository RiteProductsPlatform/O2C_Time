--==============================================================
-- test_preflight.sql
-- Thirty seconds that stop you debugging the wrong thing.
--
-- Every check below has already been the cause of a confusing failure once.
-- None of them are visible from the test output: a stale procedure, a missing
-- column and an unseeded config row all fail LATE, inside a MERGE, with an
-- error that names a line rather than a cause.
--
-- Read-only. Run as the O2C_TIME schema owner, press F5, fix anything marked
-- FAIL before running the load tests.
--==============================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  v_n    NUMBER;
  v_txt  VARCHAR2(200);
  v_bad  NUMBER := 0;

  PROCEDURE say(p_label VARCHAR2, p_ok BOOLEAN, p_detail VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_label, 34) ||
                         CASE WHEN p_ok THEN 'PASS  ' ELSE 'FAIL  ' END ||
                         p_detail);
    IF NOT p_ok THEN v_bad := v_bad + 1; END IF;
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 88, '-'));

  -- 1. Is the procedure even valid? An INVALID one still "exists" and fails on
  --    first call with ORA-06508 / ORA-04063, which reads like a missing object.
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_LOAD_XML' AND status = 'VALID';
  say('OC_TIME_LOAD_XML compiles', v_n = 1,
      CASE v_n WHEN 1 THEN 'VALID' ELSE 'INVALID or absent - re-run 16, then SHOW ERRORS' END);

  -- 2. WHICH version is in the database. The whole point of this file.
  --    ESCAPE '' is a zero-length escape character: ORA-06502 on every load,
  --    raised at run time, from a line that looks perfectly correct.
  SELECT COUNT(*) INTO v_n FROM user_source
   WHERE name = 'OC_TIME_LOAD_XML' AND INSTR(text, 'SUBSTR(c.nm, 1, 7)') > 0;
  say('  ...and is the CURRENT source', v_n >= 1,
      CASE WHEN v_n >= 1 THEN 'has the SUBSTR guard'
           ELSE 'STALE - compiled before the ESCAPE fix. git pull, re-run 16' END);

  SELECT COUNT(*) INTO v_n FROM user_source
   WHERE name = 'OC_TIME_LOAD_XML' AND INSTR(text, 'ESCAPE ''''') > 0;
  say('  ...no zero-length ESCAPE', v_n = 0,
      CASE v_n WHEN 0 THEN 'clean' ELSE 'ORA-06502 WILL fire on every load' END);

  -- 3. The FK column must be excluded from the XML scan, or ALLOCATIONS puts
  --    Fusion's project id straight into the local foreign key.
  SELECT COUNT(*) INTO v_n FROM user_source
   WHERE name = 'OC_TIME_LOAD_XML'
     AND INSTR(text, 't.column_name <> v_fkcol') > 0;
  say('FK column excluded from scan', v_n >= 1,
      CASE WHEN v_n >= 1 THEN 'resolution cannot be bypassed'
           ELSE 'STALE - the old guard disables itself on a name collision' END);

  DBMS_OUTPUT.PUT_LINE('');

  -- 4. Config columns and seeds.
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TIME_SYNC_CONFIG' AND column_name = 'MERGE_KEY';
  say('MERGE_KEY column', v_n = 1,
      CASE v_n WHEN 1 THEN 'present' ELSE 'MISSING - the per-column ALTER did not run' END);

  IF v_n = 1 THEN
    EXECUTE IMMEDIATE
      'SELECT NVL(MAX(merge_key), ''(null)'') FROM oc_time_sync_config '
      || 'WHERE bip_report_name = ''TASKS'''
      INTO v_txt;
    say('TASKS merge key', v_txt = 'PROJECT_ID,TASK_CODE',
        v_txt || CASE WHEN v_txt = 'PROJECT_ID,TASK_CODE' THEN ''
                 ELSE '  <- must be PROJECT_ID,TASK_CODE, or it merges on the wrong key' END);
  END IF;

  SELECT NVL(MAX(fk_column), '(null)') INTO v_txt
    FROM oc_time_sync_config WHERE bip_report_name = 'TASKS';
  say('TASKS fk_column', v_txt = 'PROJECT_ID', v_txt);

  SELECT NVL(MAX(fk_column), '(null)') INTO v_txt
    FROM oc_time_sync_config WHERE bip_report_name = 'ALLOCATIONS';
  say('ALLOCATIONS fk_column', v_txt = 'PROJECT_ID', v_txt);

  DBMS_OUTPUT.PUT_LINE('');

  -- 5. 17's column. Without it the Fusion id is silently DROPPED, not errored:
  --    the loader intersects USER_TAB_COLUMNS with the XML at run time.
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TIME_ALLOCATION' AND column_name = 'FUSION_PROJECT_ID';
  say('ALLOCATION.FUSION_PROJECT_ID', v_n = 1,
      CASE v_n WHEN 1 THEN 'present' ELSE 'MISSING - run 17. The id would be dropped silently' END);

  -- 6. Test fixtures. Both load tests key off these two rows.
  SELECT COUNT(*) INTO v_n FROM oc_time_project WHERE project_number = '444';
  say('project 444 loaded', v_n = 1,
      CASE v_n WHEN 1 THEN 'present' ELSE 'run the PROJECTS sync first' END);

  SELECT COUNT(*) INTO v_n FROM oc_time_worker WHERE employee_id = 'RI2894';
  say('worker RI2894 loaded', v_n = 1,
      CASE v_n WHEN 1 THEN 'present' ELSE 'run the WORKERS sync first' END);

  DBMS_OUTPUT.PUT_LINE(RPAD('-', 88, '-'));
  IF v_bad = 0 THEN
    DBMS_OUTPUT.PUT_LINE('All clear. Run test_load_xml_tasks.sql, then '
                      || 'test_load_xml_allocations.sql.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(v_bad || ' check(s) failed. Fix these first - each one '
                      || 'fails LATE and misleadingly.');
  END IF;
END;
/
