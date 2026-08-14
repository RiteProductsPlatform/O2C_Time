--==============================================================
-- test_load_xml_allocations.sql
-- ALLOCATIONS is the entity that would have broken, and the one that proves
-- Fusion's own ids survive the sync.
--
-- Re-run 16_oic_sync_config.sql and 17_sync_column_gaps.sql FIRST.
--
-- WHY THIS ENTITY IS DIFFERENT FROM TASKS
--
-- TASKS passed its test partly by luck. Its extract aliases Fusion's project
-- id to FUSION_PROJECT_ID, so the element PROJECT_ID was simply absent from
-- the XML and the loader's foreign-key resolution ran unopposed.
--
-- ALLOCATIONS aliased it to PROJECT_ID -- the exact name of the LOCAL
-- surrogate foreign key OC_TIME_ALLOCATION.PROJECT_ID. The loader's column
-- scan matched on name, took Fusion's 300000337787982 as an ordinary column
-- value, and the resolution block then found PROJECT_ID already populated and
-- SKIPPED ITSELF. The guard disabled the protection exactly when it was needed.
--
-- Outcome would have been ORA-02291 if no local project holds that number, or
-- -- far worse and entirely silent -- an allocation attached to the WRONG
-- project if one did. Local project ids are small integers; Fusion's are
-- fifteen digits, so a collision is unlikely rather than impossible. "Unlikely"
-- is not a control.
--
-- Two things changed and this file tests both:
--   * the loader now EXCLUDES a configured FK column from the XML scan, so
--     resolution is the only thing that can populate it
--   * the extract aliases to FUSION_PROJECT_ID and a column was added to hold
--     it, because the OTL push (INT-007) must name the project back to Fusion
--     and cannot do that with our 376
--
-- Paste into SQL Developer as the O2C_TIME schema owner and press F5.
--==============================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

PROMPT === 0. preconditions ==========================================

DECLARE
  v_pid NUMBER; v_emp NUMBER; v_col NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_col FROM user_tab_columns
   WHERE table_name = 'OC_TIME_ALLOCATION' AND column_name = 'FUSION_PROJECT_ID';
  DBMS_OUTPUT.PUT_LINE('FUSION_PROJECT_ID column : ' ||
    CASE v_col WHEN 1 THEN 'present' ELSE 'MISSING - run 17_sync_column_gaps.sql' END);

  SELECT COUNT(*) INTO v_pid FROM oc_time_project WHERE project_number = '444';
  SELECT COUNT(*) INTO v_emp FROM oc_time_worker  WHERE employee_id = 'RI2894';
  DBMS_OUTPUT.PUT_LINE('project 444              : ' ||
    CASE v_pid WHEN 0 THEN 'MISSING - load PROJECTS first' ELSE 'present' END);
  DBMS_OUTPUT.PUT_LINE('worker RI2894            : ' ||
    CASE v_emp WHEN 0 THEN 'MISSING - load WORKERS first' ELSE 'present' END);
END;
/

PROMPT
PROMPT === 1. THE REGRESSION: XML carrying the OLD alias =============
PROMPT The element is named PROJECT_ID and holds Fusion's fifteen-digit id
PROMPT exactly what the extract used to emit. The loader must IGNORE it and
PROMPT resolve PROJECT_ID from PROJECT_NUMBER instead.
PROMPT
PROMPT Storing 300000337787982 here would be the bug. So would ORA-02291.
PROMPT ==============================================================

DECLARE
  v_xml CLOB; v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
  v_pid NUMBER; v_got NUMBER;
BEGIN
  SELECT project_id INTO v_pid FROM oc_time_project WHERE project_number = '444';

  v_xml :=
'<DATA_DS><ROWSET>
<ROW><PROJECT_ID>300000337787982</PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><EMPLOYEE_ID>RI2894</EMPLOYEE_ID><START_DATE>2026-07-01</START_DATE><END_DATE></END_DATE><ALLOC_PCT>50</ALLOC_PCT><CAP_HOURS></CAP_HOURS><TRACK_TIME_FLAG>Y</TRACK_TIME_FLAG><STATUS>Active</STATUS></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_ALLOCATION', v_xml, 'ALLOCATIONS', 'ALLOC_TEST',
                   v_read, v_merged, v_status, v_msg);

  DBMS_OUTPUT.PUT_LINE('status : ' || v_status);
  DBMS_OUTPUT.PUT_LINE('message: ' || v_msg);

  SELECT COUNT(*) INTO v_got FROM oc_time_allocation
   WHERE employee_id = 'RI2894' AND start_date = DATE '2026-07-01'
     AND project_id = v_pid;

  DBMS_OUTPUT.PUT_LINE('rows with local project_id ' || v_pid || ' : ' || v_got);
  DBMS_OUTPUT.PUT_LINE('(must be 1. 0 with a Failed ORA-02291 means Fusion''s');
  DBMS_OUTPUT.PUT_LINE(' id reached the foreign key -- the old bug.)');

  IF v_status = 'Success' AND v_got = 1 THEN
    DBMS_OUTPUT.PUT_LINE('PASS - the colliding element was ignored and the FK resolved.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FAIL - see above.');
  END IF;
END;
/

PROMPT
PROMPT === 2. the CURRENT alias: Fusion's id is kept ================
PROMPT The whole reason the rename is not enough on its own. Resolving the
PROMPT local FK correctly but discarding Fusion's id would leave the OTL push
PROMPT with nothing to send.
PROMPT ==============================================================

DECLARE
  v_xml CLOB; v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
  v_pid NUMBER; v_fpid VARCHAR2(50);
BEGIN
  SELECT project_id INTO v_pid FROM oc_time_project WHERE project_number = '444';

  v_xml :=
'<DATA_DS><ROWSET>
<ROW><FUSION_PROJECT_ID>300000337787982</FUSION_PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><EMPLOYEE_ID>RI2894</EMPLOYEE_ID><START_DATE>2026-07-01</START_DATE><END_DATE></END_DATE><ALLOC_PCT>60</ALLOC_PCT><CAP_HOURS></CAP_HOURS><TRACK_TIME_FLAG>Y</TRACK_TIME_FLAG><STATUS>Active</STATUS></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_ALLOCATION', v_xml, 'ALLOCATIONS', 'ALLOC_TEST',
                   v_read, v_merged, v_status, v_msg);

  SELECT fusion_project_id INTO v_fpid FROM oc_time_allocation
   WHERE employee_id = 'RI2894' AND start_date = DATE '2026-07-01'
     AND project_id = v_pid;

  DBMS_OUTPUT.PUT_LINE('status            : ' || v_status);
  DBMS_OUTPUT.PUT_LINE('local project_id  : ' || v_pid
                    || '   (ours, for the FK and every join)');
  DBMS_OUTPUT.PUT_LINE('fusion_project_id : ' || NVL(v_fpid, '(NULL)')
                    || '   (Fusion''s, for the OTL push)');
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('BOTH must be populated. That is the point: they are');
  DBMS_OUTPUT.PUT_LINE('two names for one project and each has a job.');

  IF v_status = 'Success' AND v_fpid = '300000337787982' THEN
    DBMS_OUTPUT.PUT_LINE('PASS');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FAIL - see above.');
  END IF;
END;
/

PROMPT
PROMPT === 3. an EMPTY Fusion id must not erase a good one ==========
PROMPT The quiet one. <FUSION_PROJECT_ID></FUSION_PROJECT_ID> parses to NULL,
PROMPT and before the NVL guard the MERGE wrote that NULL straight over a
PROMPT populated id. Nothing raised: the column is nullable, and a unique
PROMPT constraint ignores NULL rows entirely. The push would simply find
PROMPT nothing to send for rows that were fine yesterday.
PROMPT
PROMPT ALLOC_PCT below changes to 70 in the same row, so this also proves the
PROMPT guard is NOT just "skip the update" -- ordinary columns still update.
PROMPT ==============================================================

DECLARE
  v_xml CLOB; v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
  v_pid NUMBER; v_fpid VARCHAR2(50); v_pct NUMBER;
BEGIN
  SELECT project_id INTO v_pid FROM oc_time_project WHERE project_number = '444';

  v_xml :=
'<DATA_DS><ROWSET>
<ROW><FUSION_PROJECT_ID></FUSION_PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><EMPLOYEE_ID>RI2894</EMPLOYEE_ID><START_DATE>2026-07-01</START_DATE><END_DATE></END_DATE><ALLOC_PCT>70</ALLOC_PCT><CAP_HOURS></CAP_HOURS><TRACK_TIME_FLAG>Y</TRACK_TIME_FLAG><STATUS>Active</STATUS></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_ALLOCATION', v_xml, 'ALLOCATIONS', 'ALLOC_TEST',
                   v_read, v_merged, v_status, v_msg);

  SELECT fusion_project_id, alloc_pct INTO v_fpid, v_pct
    FROM oc_time_allocation
   WHERE employee_id = 'RI2894' AND start_date = DATE '2026-07-01'
     AND project_id = v_pid;

  DBMS_OUTPUT.PUT_LINE('status            : ' || v_status);
  DBMS_OUTPUT.PUT_LINE('fusion_project_id : ' || NVL(v_fpid, '(NULL)')
                    || '   (must SURVIVE as 300000337787982)');
  DBMS_OUTPUT.PUT_LINE('alloc_pct         : ' || v_pct
                    || '   (must have CHANGED to 70 -- ordinary columns');
  DBMS_OUTPUT.PUT_LINE('                              still update normally)');

  IF v_fpid = '300000337787982' AND v_pct = 70 THEN
    DBMS_OUTPUT.PUT_LINE('PASS - Fusion id preserved, everything else updated.');
  ELSIF v_fpid IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('FAIL - the Fusion id was erased. The NVL guard in');
    DBMS_OUTPUT.PUT_LINE('       OC_TIME_LOAD_XML is missing or not matching');
    DBMS_OUTPUT.PUT_LINE('       the FUSION_% name pattern.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FAIL - see above.');
  END IF;
END;
/

PROMPT
PROMPT === 4. STATUS domain =========================================
PROMPT CHK_OC_TAL_STATUS allows ('Active','Ended'). The extract sent
PROMPT 'Inactive', so every ended allocation failed ORA-02290. Confirm the
PROMPT domain by pushing the value the extract now sends.
PROMPT ==============================================================

DECLARE
  v_xml CLOB; v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
BEGIN
  v_xml :=
'<DATA_DS><ROWSET>
<ROW><FUSION_PROJECT_ID>300000337787982</FUSION_PROJECT_ID><PROJECT_NUMBER>444</PROJECT_NUMBER><EMPLOYEE_ID>RI2894</EMPLOYEE_ID><START_DATE>2025-01-06</START_DATE><END_DATE>2025-06-30</END_DATE><ALLOC_PCT>100</ALLOC_PCT><CAP_HOURS></CAP_HOURS><TRACK_TIME_FLAG>Y</TRACK_TIME_FLAG><STATUS>Ended</STATUS></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_ALLOCATION', v_xml, 'ALLOCATIONS', 'ALLOC_TEST',
                   v_read, v_merged, v_status, v_msg);
  DBMS_OUTPUT.PUT_LINE('status : ' || v_status || '   ' || v_msg);
  DBMS_OUTPUT.PUT_LINE('(Success. An ORA-02290 here means the extract is still');
  DBMS_OUTPUT.PUT_LINE(' sending Inactive.)');
END;
/

PROMPT
PROMPT === clean up ==================================================
DELETE FROM oc_time_allocation
 WHERE employee_id = 'RI2894'
   AND start_date IN (DATE '2026-07-01', DATE '2025-01-06')
   AND project_id = (SELECT project_id FROM oc_time_project
                      WHERE project_number = '444');
COMMIT;
PROMPT Test allocations removed. Run the real ALLOCATIONS sync to load properly.
