--==============================================================
-- time/100_enable_scheduled_absence_sync.sql
-- O2C Timesheet Module — the ABSENCES feed goes back on
--
-- Asked 21-Aug: "Scheduled absence sync stays off - turn it on for now".
--
-- db/16 registered ABSENCES and switched it off on 09-Aug with this reason:
--
--   "OFF: absence is read LIVE per person per date at page load, not synced.
--    The model is kept because the leave-loss absentee list still needs a bulk
--    read. Enable only if that decision changes."
--
-- The decision has changed, so it goes on.
--
-- TWO THINGS TO KNOW, AND THE SECOND IS THE ONE THAT MATTERS.
--
-- 1. RE-RUNNING db/16 WOULD NOT HAVE DONE THIS. Its seed is
--    INSERT ... WHERE NOT EXISTS, so editing the 'N' in the t_row literal
--    changes what a FRESH schema gets and leaves an existing row exactly as it
--    was. Both are done here: db/16's literal now says 'Y', and the UPDATE
--    below moves the row that is already there.
--
-- 2. THE SCHEDULED FEED ADDS; IT CANNOT RETRACT. This is not a limitation of
--    the flag, it is the shape of the two paths:
--
--      browser  posts employeeId + windowFrom + windowTo -- a CLAIM that these
--               are all the absences in that window, so the handler can delete
--               what it was not sent
--      BIP/OIC  hands OC_TIME_LOAD_XML a batch of rows and no window, so
--               "absent from this batch" and "no longer exists" are the same
--               thing to it, and it can only MERGE
--
--    So after this, leave APPLIED in Fusion reaches the module on the schedule
--    without anybody opening a screen -- which is the point -- but leave
--    WITHDRAWN or DELETED still only retracts when a screen does the live read.
--    The per-page pulls therefore stay, and are not redundant.
--
--    Giving the scheduled path a window is real work: the extract would have to
--    declare the range it covers and OC_TIME_LOAD_XML would have to honour it.
--    Worth doing, not done here, and not pretended.
--
-- 3. Nothing schedules it yet either. This makes the row eligible; INT-001 in
--    OIC is what actually calls it, and the cadence is set there.
--
-- Idempotent. Depends on: time/16.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables
   WHERE table_name = 'OC_TIME_SYNC_CONFIG';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/16 has not been run: OC_TIME_SYNC_CONFIG is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] Before
PROMPT ============================================================

COLUMN bip_report_name FORMAT A16
COLUMN target_table    FORMAT A20
COLUMN schedule_tag    FORMAT A10
SELECT run_order, bip_report_name, target_table, sync_mode, schedule_tag,
       enabled_flag,
       NVL(TO_CHAR(lastsync_date,'DD-Mon-YY HH24:MI'),'never') AS lastsync
  FROM oc_time_sync_config
 WHERE bip_report_name = 'ABSENCES';

PROMPT ============================================================
PROMPT [2/3] Enable it
PROMPT ============================================================

DECLARE
  v_n   NUMBER;
  v_tgt VARCHAR2(40);
BEGIN
  -- CHK_OC_TSC_TGT refuses an enabled row with no target table, so the row
  -- would fail on UPDATE rather than load nothing later. Checked first so the
  -- message names the cause.
  SELECT MAX(target_table) INTO v_tgt
    FROM oc_time_sync_config WHERE bip_report_name = 'ABSENCES';

  IF v_tgt IS NULL THEN
    RAISE_APPLICATION_ERROR(-20098,
      'ABSENCES has no TARGET_TABLE, so it cannot be enabled. Expected '
      || 'OC_TIME_ABSENCE - check db/16 ran completely.');
  END IF;

  UPDATE oc_time_sync_config
     SET enabled_flag = 'Y',
         purpose = 'Approved absence per person per day. Feeds OC_TIME_ABSENCE, '
                || 'which drives the Leave rows and the leave-loss absentee '
                || 'list. ON since 21-Aug-2026. NOTE: this path ADDS and '
                || 'UPDATES only -- it sends no window, so a withdrawn or '
                || 'deleted absence still retracts only through the live '
                || 'per-page read, which posts a windowed claim.'
   WHERE bip_report_name = 'ABSENCES'
     AND enabled_flag <> 'Y';
  v_n := SQL%ROWCOUNT;

  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Already enabled - nothing to do.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  ABSENCES enabled.');
  END IF;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [3/3] After — every entity the schedule will now run
PROMPT ============================================================

SELECT run_order, bip_report_name, target_table, schedule_tag, enabled_flag
  FROM oc_time_sync_config
 WHERE enabled_flag = 'Y'
 ORDER BY run_order;

PROMPT
PROMPT ABSENCES should appear above at run_order 70. It is now ELIGIBLE; OIC
PROMPT INT-001 is what actually calls it, and the cadence is set there.

PROMPT
PROMPT AND THE LIVE READS STAY. This path adds and updates; it sends no window,
PROMPT so it cannot tell "not in this batch" from "no longer exists". A
PROMPT withdrawn absence still retracts only when a screen does the live read.
