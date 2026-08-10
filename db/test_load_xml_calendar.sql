--==============================================================
-- test_load_xml_calendar.sql
-- Prove OC_TIME_LOAD_XML end to end, on the clean case.
--
-- Paste into SQL Developer as the O2C_TIME schema owner and press F5.
-- NOT part of install_time.sql -- this is a test, run it by hand.
--
-- CALENDAR is deliberately the first thing tested:
--   * 7 of 7 elements match the table's columns, so nothing is dropped
--   * no foreign key, so the resolution path is not involved yet
--   * SCOPE_KEY + CAL_DATE + LAYER is a real unique key, so the MERGE has
--     something to match on
-- If this passes, the decode, the key discovery and the merge all work, and
-- anything that fails afterwards is about that entity, not the mechanism.
--
-- The three rows below are REAL OUTPUT from O2C_CALENDAR.xdm on the dev20 pod,
-- copied unaltered, so this tests the actual shape rather than a shape somebody
-- believed BIP produces. Note <ROWSET><ROW> -- the model declares a group
-- called G_1 and BIP does not use it.
--==============================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  v_xml    CLOB;
  v_read   NUMBER;
  v_merged NUMBER;
  v_status VARCHAR2(20);
  v_msg    VARCHAR2(2000);
  v_before NUMBER;
  v_after  NUMBER;
BEGIN
  v_xml :=
'<?xml version="1.0" encoding="UTF-8"?>
<DATA_DS><ROWSET>
<ROW><LAYER>CORPORATE</LAYER><SCOPE_KEY>MAYDAY26</SCOPE_KEY><CAL_DATE>2026-05-04</CAL_DATE><IS_WORKING_DAY>N</IS_WORKING_DAY><HOLIDAY_NAME>MAYDAY26</HOLIDAY_NAME><SHIFT_CODE></SHIFT_CODE><STD_HOURS>0</STD_HOURS></ROW>
<ROW><LAYER>CORPORATE</LAYER><SCOPE_KEY>KBDAU26</SCOPE_KEY><CAL_DATE>2026-06-08</CAL_DATE><IS_WORKING_DAY>N</IS_WORKING_DAY><HOLIDAY_NAME>KBDAU26</HOLIDAY_NAME><SHIFT_CODE></SHIFT_CODE><STD_HOURS>0</STD_HOURS></ROW>
<ROW><LAYER>CORPORATE</LAYER><SCOPE_KEY>KBDNZ27</SCOPE_KEY><CAL_DATE>2027-06-07</CAL_DATE><IS_WORKING_DAY>N</IS_WORKING_DAY><HOLIDAY_NAME>KBDNZ27</HOLIDAY_NAME><SHIFT_CODE></SHIFT_CODE><STD_HOURS>0</STD_HOURS></ROW>
</ROWSET></DATA_DS>';

  SELECT COUNT(*) INTO v_before FROM oc_time_calendar
   WHERE scope_key IN ('MAYDAY26','KBDAU26','KBDNZ27');

  DBMS_OUTPUT.PUT_LINE('--- before -------------------------------------');
  DBMS_OUTPUT.PUT_LINE('rows already present : ' || v_before);

  oc_time_load_xml(
    p_table_name  => 'OC_TIME_CALENDAR',
    p_xml         => v_xml,
    p_report_name => 'CALENDAR',
    p_actor       => 'MANUAL_TEST',
    o_rows_read   => v_read,
    o_rows_merged => v_merged,
    o_status      => v_status,
    o_message     => v_msg);

  SELECT COUNT(*) INTO v_after FROM oc_time_calendar
   WHERE scope_key IN ('MAYDAY26','KBDAU26','KBDNZ27');

  DBMS_OUTPUT.PUT_LINE('--- result -------------------------------------');
  DBMS_OUTPUT.PUT_LINE('status   : ' || v_status);
  DBMS_OUTPUT.PUT_LINE('read     : ' || v_read);
  DBMS_OUTPUT.PUT_LINE('merged   : ' || v_merged);
  DBMS_OUTPUT.PUT_LINE('message  : ' || v_msg);
  DBMS_OUTPUT.PUT_LINE('rows now : ' || v_after);
  DBMS_OUTPUT.PUT_LINE('');

  IF v_status = 'Success' AND v_read = 3 AND v_after = 3 THEN
    DBMS_OUTPUT.PUT_LINE('PASS - decode, key discovery and merge all work.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('FAIL - see the message above.');
  END IF;
END;
/

PROMPT
PROMPT === run it a SECOND time ======================================
PROMPT The whole design re-reads overlapping windows, so the same rows
PROMPT arrive again constantly. A second run must UPDATE, not duplicate
PROMPT and not raise ORA-00001. If the count below is still 3, the merge
PROMPT is genuinely idempotent; if it is 6, it is inserting blind.
PROMPT ==============================================================

DECLARE
  v_xml    CLOB;
  v_read   NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000); v_after NUMBER;
BEGIN
  v_xml :=
'<DATA_DS><ROWSET>
<ROW><LAYER>CORPORATE</LAYER><SCOPE_KEY>MAYDAY26</SCOPE_KEY><CAL_DATE>2026-05-04</CAL_DATE><IS_WORKING_DAY>N</IS_WORKING_DAY><HOLIDAY_NAME>MAYDAY26 RENAMED</HOLIDAY_NAME><SHIFT_CODE></SHIFT_CODE><STD_HOURS>0</STD_HOURS></ROW>
</ROWSET></DATA_DS>';

  oc_time_load_xml('OC_TIME_CALENDAR', v_xml, 'CALENDAR', 'MANUAL_TEST',
                   v_read, v_merged, v_status, v_msg);

  SELECT COUNT(*) INTO v_after FROM oc_time_calendar
   WHERE scope_key IN ('MAYDAY26','KBDAU26','KBDNZ27');

  DBMS_OUTPUT.PUT_LINE('status   : ' || v_status || '   ' || v_msg);
  DBMS_OUTPUT.PUT_LINE('rows now : ' || v_after || '   (must still be 3)');

  FOR r IN (SELECT scope_key, holiday_name FROM oc_time_calendar
             WHERE scope_key = 'MAYDAY26') LOOP
    DBMS_OUTPUT.PUT_LINE('holiday  : ' || r.holiday_name ||
                         '   (must be MAYDAY26 RENAMED - proves it UPDATED)');
  END LOOP;
END;
/

PROMPT
PROMPT === and the failure path ======================================
PROMPT A table the config does not target must be refused, because the
PROMPT loader builds dynamic SQL and an unchecked name is an injection
PROMPT point. Expect a Failed status and a message naming the table.
PROMPT ==============================================================

DECLARE
  v_read NUMBER; v_merged NUMBER;
  v_status VARCHAR2(20); v_msg VARCHAR2(2000);
BEGIN
  oc_time_load_xml('OC_TS_ENTRY',
                   '<DATA_DS><ROWSET><ROW><X>1</X></ROW></ROWSET></DATA_DS>',
                   NULL, 'MANUAL_TEST', v_read, v_merged, v_status, v_msg);
  DBMS_OUTPUT.PUT_LINE('status  : ' || v_status || '   (expect Failed)');
  DBMS_OUTPUT.PUT_LINE('message : ' || v_msg);
END;
/

PROMPT
PROMPT === clean up the three test rows ==============================
DELETE FROM oc_time_calendar WHERE scope_key IN ('MAYDAY26','KBDAU26','KBDNZ27');
COMMIT;
PROMPT Test rows removed. Re-run the real CALENDAR sync to reload them properly.
