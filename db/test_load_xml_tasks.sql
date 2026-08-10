--==============================================================
-- test_load_xml_tasks.sql
-- Prove the FOREIGN KEY RESOLUTION, which CALENDAR never exercised.
--
-- Run 18_task_natural_key.sql FIRST. OC_TIME_TASK has no natural unique key
-- without it and the loader will refuse the merge -- correctly, because the
-- alternative is duplicating all 624 tasks on every sync.
--
-- Paste into SQL Developer as the O2C_TIME schema owner and press F5.
--
-- WHAT IS ACTUALLY BEING TESTED
--
-- These are real rows from O2C_TASKS.xdm for project 444. Fusion calls that
-- project 300000337787982. Our OC_TIME_PROJECT calls it 376. Both numbers are
-- correct and they have nothing to do with each other.
--
-- OC_TIME_TASK.PROJECT_ID is a foreign key to OUR number, so the only
-- acceptable outcome is 376. Anything else is a bug:
--
--   300000337787982  the loader took Fusion's id straight through
--   NULL             the lookup ran and found nothing
--   ORA-02291        it tried Fusion's id against the foreign key
--
-- Ordering cannot fix this and never could. Loading projects first makes 376
-- EXIST; it does not make 300000337787982 MEAN anything here.
--==============================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

PROMPT === 1. does 444 exist locally, and under what id? =============

DECLARE
  v_pid NUMBER;
BEGIN
  SELECT project_id INTO v_pid FROM oc_time_project WHERE project_number = '444';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_PROJECT.PROJECT_ID for 444 = ' || v_pid);
  DBMS_OUTPUT.PUT_LINE('Fusion calls the same project 300000337787982.');
  DBMS_OUTPUT.PUT_LINE('The loader must store the FIRST number, not the second.');
EXCEPTION WHEN NO_DATA_FOUND THEN
  DBMS_OUTPUT.PUT_LINE('444 is NOT in OC_TIME_PROJECT. Load PROJECTS first -- '
    || 'the lookup has nothing to find and this test cannot mean anything.');
END;
/

PROMPT
PROMPT === 2. load two real tasks for 444 ============================

DECLARE
  v_xml    CLOB;
  v_read   NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
  v_pid    NUMBER; v_got NUMBER; v_bad NUMBER;
BEGIN
  SELECT project_id INTO v_pid FROM oc_time_project WHERE project_number = '444';

  -- Verbatim from the pod. Note FUSION_PROJECT_ID and PROJECT_NUMBER both
  -- present: the first is what we must NOT use, the second is what the lookup
  -- matches on.
  v_xml :=
'<?xml version="1.0" encoding="UTF-8"?>
<DATA_DS><P_EFFECTIVE_DATE>2026-08-01</P_EFFECTIVE_DATE><P_LAST_SYNC>1900-01-01</P_LAST_SYNC>
<ROWSET>
<ROW><FUSION_TASK_ID>300000337788008</FUSION_TASK_ID><FUSION_PROJECT_ID>300000337787982</FUSION_PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><TASK_CODE>01.01.112</TASK_CODE><TASK_NAME>Near shore</TASK_NAME><CHARGEABLE_FLAG>Y</CHARGEABLE_FLAG><BILLABLE_TYPE>Billable</BILLABLE_TYPE><WBS_LEVEL>3</WBS_LEVEL><PARENT_TASK_ID>300000337787998</PARENT_TASK_ID><START_DATE></START_DATE><END_DATE></END_DATE><EXPENDITURE_TYPE></EXPENDITURE_TYPE></ROW>
<ROW><FUSION_TASK_ID>300000337787989</FUSION_TASK_ID><FUSION_PROJECT_ID>300000337787982</FUSION_PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><TASK_CODE>02</TASK_CODE><TASK_NAME>ADM</TASK_NAME><CHARGEABLE_FLAG>N</CHARGEABLE_FLAG><BILLABLE_TYPE>Non-billable</BILLABLE_TYPE><WBS_LEVEL>1</WBS_LEVEL><PARENT_TASK_ID>300000337787985</PARENT_TASK_ID><START_DATE></START_DATE><END_DATE></END_DATE><EXPENDITURE_TYPE></EXPENDITURE_TYPE></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_TASK', v_xml, 'TASKS', 'TASK_FK_TEST',
                   v_read, v_merged, v_status, v_msg);

  DBMS_OUTPUT.PUT_LINE('status : ' || v_status);
  DBMS_OUTPUT.PUT_LINE('read   : ' || v_read || ' / merged ' || v_merged);
  DBMS_OUTPUT.PUT_LINE('message: ' || v_msg);

  SELECT COUNT(*) INTO v_got FROM oc_time_task
   WHERE fusion_task_id IN ('300000337788008','300000337787989')
     AND project_id = v_pid;
  SELECT COUNT(*) INTO v_bad FROM oc_time_task
   WHERE fusion_task_id IN ('300000337788008','300000337787989')
     AND (project_id <> v_pid OR project_id IS NULL);

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('rows with PROJECT_ID = ' || v_pid || ' : ' || v_got
                    || '   (must be 2 -- the lookup worked)');
  DBMS_OUTPUT.PUT_LINE('rows with anything else      : ' || v_bad
                    || '   (must be 0)');

  FOR r IN (SELECT fusion_task_id, task_code, task_name, project_id,
                   billable_type, chargeable_flag
              FROM oc_time_task
             WHERE fusion_task_id IN ('300000337788008','300000337787989')
             ORDER BY task_code)
  LOOP
    DBMS_OUTPUT.PUT_LINE('   ' || RPAD(r.task_code,10) || RPAD(r.task_name,14)
      || ' project_id=' || RPAD(TO_CHAR(r.project_id),6)
      || ' ' || RPAD(r.billable_type,13) || ' chargeable=' || r.chargeable_flag);
  END LOOP;

  IF v_status = 'Success' AND v_got = 2 AND v_bad = 0 THEN
    DBMS_OUTPUT.PUT_LINE('PASS - Fusion''s 300000337787982 was translated to '
                      || v_pid || '.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FAIL - see above.');
  END IF;
END;
/

PROMPT
PROMPT === 3. idempotent? the same two tasks again ===================

DECLARE
  v_xml CLOB; v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000); v_n NUMBER;
BEGIN
  v_xml :=
'<DATA_DS><ROWSET>
<ROW><FUSION_TASK_ID>300000337788008</FUSION_TASK_ID><FUSION_PROJECT_ID>300000337787982</FUSION_PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><TASK_CODE>01.01.112</TASK_CODE><TASK_NAME>Near shore RENAMED</TASK_NAME><CHARGEABLE_FLAG>Y</CHARGEABLE_FLAG><BILLABLE_TYPE>Billable</BILLABLE_TYPE><WBS_LEVEL>3</WBS_LEVEL><PARENT_TASK_ID>300000337787998</PARENT_TASK_ID><START_DATE></START_DATE><END_DATE></END_DATE><EXPENDITURE_TYPE></EXPENDITURE_TYPE></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_TASK', v_xml, 'TASKS', 'TASK_FK_TEST',
                   v_read, v_merged, v_status, v_msg);

  SELECT COUNT(*) INTO v_n FROM oc_time_task
   WHERE fusion_task_id IN ('300000337788008','300000337787989');
  DBMS_OUTPUT.PUT_LINE('status   : ' || v_status || '   ' || v_msg);
  DBMS_OUTPUT.PUT_LINE('task rows: ' || v_n || '   (must still be 2, not 3)');
  FOR r IN (SELECT task_name FROM oc_time_task
             WHERE fusion_task_id = '300000337788008') LOOP
    DBMS_OUTPUT.PUT_LINE('name     : ' || r.task_name
      || '   (must say RENAMED -- proves UPDATE, not INSERT)');
  END LOOP;
END;
/

PROMPT
PROMPT === 4. a task whose project is NOT loaded =====================
PROMPT This is the RUN_ORDER failure, and the message is the point. An
PROMPT operator seeing ORA-02291 learns nothing; they need to be told the
PROMPT parent has not loaded yet.
PROMPT ==============================================================

DECLARE
  v_xml CLOB; v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
BEGIN
  -- HC2001 is a real Fusion project that is NOT in OC_TIME_PROJECT.
  v_xml :=
'<DATA_DS><ROWSET>
<ROW><FUSION_TASK_ID>999999999999999</FUSION_TASK_ID><FUSION_PROJECT_ID>300000166633708</FUSION_PROJECT_ID><PROJECT_NUMBER>HC2001</PROJECT_NUMBER><TASK_CODE>1.0</TASK_CODE><TASK_NAME>Orphan</TASK_NAME><CHARGEABLE_FLAG>Y</CHARGEABLE_FLAG><BILLABLE_TYPE>Billable</BILLABLE_TYPE><WBS_LEVEL>1</WBS_LEVEL><PARENT_TASK_ID></PARENT_TASK_ID><START_DATE></START_DATE><END_DATE></END_DATE><EXPENDITURE_TYPE></EXPENDITURE_TYPE></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_TASK', v_xml, 'TASKS', 'TASK_FK_TEST',
                   v_read, v_merged, v_status, v_msg);
  DBMS_OUTPUT.PUT_LINE('status : ' || v_status);
  DBMS_OUTPUT.PUT_LINE('message: ' || v_msg);
  DBMS_OUTPUT.PUT_LINE('(should name PROJECT_ID and mention RUN_ORDER, and');
  DBMS_OUTPUT.PUT_LINE(' must NOT be a raw ORA-02291)');
END;
/

PROMPT
PROMPT === clean up ==================================================
DELETE FROM oc_time_task
 WHERE fusion_task_id IN ('300000337788008','300000337787989','999999999999999');
COMMIT;
PROMPT Test tasks removed. Run the real TASKS sync to load them properly.
