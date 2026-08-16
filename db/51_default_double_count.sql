--==============================================================
-- time/51_default_double_count.sql
-- O2C Timesheet Module — a defaulted week was populated twice
--
-- RI2824's week of 03-09 Aug holds 128 hours across five working days:
--
--   Job / Default        10 rows   64h    <- the cut-off job's retag
--   Prepopulated/Actual  10 rows   64h    <- populate, put back afterwards
--
-- WHY
--   run_weekly_defaulting does not create rows; it RETAGS the prepopulated
--   ones, entry_type 'Actual' -> 'Default' and source 'Prepopulated' -> 'Job',
--   so the accrual hand-off can tell a real entry from a defaulted one.
--
--   populate_daily then skips a cell it has already filled, guarded by
--
--       AND NOT EXISTS (... AND e.entry_type = 'Actual')
--
--   which stops matching the moment the retag happens. The cell looks empty,
--   populate fills it again, and the day now carries the defaulted hours AND a
--   fresh copy.
--
--   UK_OC_TSE_CELL includes ENTRY_TYPE, so the database permits it. That is
--   deliberate and right for Reversal(-) sitting on the same day as the
--   Actual it offsets -- but Default is not a counterpart to Actual, it IS
--   that Actual wearing another label.
--
-- HOW BAD
--   The cut-off job defaulted 134 weeks on 15-Aug and the daily process has
--   run since, so this is not one week. Every defaulted week that populate has
--   touched afterwards carries double hours -- and a defaulted week is locked,
--   holds salary under RULE-016, and its hours are what reach accrual.
--
-- Idempotent. Depends on: time/09
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
PROMPT [1/3] How many cells carry both a Default and an Actual
PROMPT ============================================================

COLUMN employee_id FORMAT A14
SELECT COUNT(*)                        AS duplicated_cells,
       COUNT(DISTINCT e.ts_week_id)    AS weeks,
       SUM(e.hours)                    AS surplus_hours
  FROM oc_ts_entry e
 WHERE e.entry_type = 'Actual'
   AND e.is_leave   = 'N'
   AND EXISTS (SELECT 1 FROM oc_ts_entry d
                WHERE d.ts_week_id = e.ts_week_id
                  AND d.project_id = e.project_id
                  AND d.task_id    = e.task_id
                  AND d.entry_date = e.entry_date
                  AND d.entry_type = 'Default');

PROMPT
PROMPT SURPLUS_HOURS is hours that exist twice. On a defaulted week those are
PROMPT also the hours holding somebody's salary and heading for accrual.

PROMPT ============================================================
PROMPT [2/3] Remove the duplicate, keep the Default
PROMPT ============================================================

-- The DEFAULT row is the one to keep. It is what the cut-off job produced and
-- what the accrual hand-off reads as "these hours were not entered by a
-- person" -- deleting it would erase that distinction. The Actual is the copy
-- populate added afterwards and is a straight duplicate of it.
--
-- Only where an identical Default exists on the same cell, and never on a
-- leave row, which lives on its own task and cannot collide this way.
DECLARE
  v_n NUMBER;
BEGIN
  -- Audited before deletion, because there is no DELETE trigger on
  -- OC_TS_ENTRY -- the audit triggers are BEFORE UPDATE OF -- and a row
  -- removed by a repair script should not be the one row nobody can account
  -- for later.
  INSERT INTO oc_ts_audit (
    ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
    old_project_id, old_task_id, old_hours, old_bill_type,
    new_project_id, new_task_id, new_hours,
    change_reason, changed_by, changed_on)
  SELECT e.ts_entry_id, e.ts_week_id, w.employee_id, e.entry_date,
         'DefaultCorrection',
         e.project_id, e.task_id, e.hours, e.billable_type,
         NULL, NULL, 0,
         'Duplicate of the Default row on the same cell; populate re-created '
         || 'it after the cut-off job retagged the original.',
         'FIX-DOUBLE-COUNT', SYSTIMESTAMP
    FROM oc_ts_entry e
    JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
   WHERE e.entry_type = 'Actual'
     AND e.is_leave   = 'N'
     AND EXISTS (SELECT 1 FROM oc_ts_entry d
                  WHERE d.ts_week_id = e.ts_week_id
                    AND d.project_id = e.project_id
                    AND d.task_id    = e.task_id
                    AND d.entry_date = e.entry_date
                    AND d.entry_type = 'Default');

  DELETE FROM oc_ts_entry e
   WHERE e.entry_type = 'Actual'
     AND e.is_leave   = 'N'
     AND EXISTS (SELECT 1 FROM oc_ts_entry d
                  WHERE d.ts_week_id = e.ts_week_id
                    AND d.project_id = e.project_id
                    AND d.task_id    = e.task_id
                    AND d.entry_date = e.entry_date
                    AND d.entry_type = 'Default');
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' duplicate row(s) removed');
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

SELECT COUNT(*) AS still_duplicated
  FROM oc_ts_entry e
 WHERE e.entry_type = 'Actual'
   AND e.is_leave   = 'N'
   AND EXISTS (SELECT 1 FROM oc_ts_entry d
                WHERE d.ts_week_id = e.ts_week_id
                  AND d.project_id = e.project_id
                  AND d.task_id    = e.task_id
                  AND d.entry_date = e.entry_date
                  AND d.entry_type = 'Default');

PROMPT
PROMPT --- a defaulted week should now total its working days, not twice them
COLUMN wk FORMAT A22
SELECT TO_CHAR(w.week_start,'DD-Mon') || ' to ' || TO_CHAR(w.week_end,'DD-Mon') AS wk,
       w.submission_status, e.source, e.entry_type,
       COUNT(*) AS rows_, SUM(e.hours) AS hours
  FROM oc_ts_week w
  JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
  JOIN oc_time_period p ON p.period_id = w.period_id
 WHERE w.employee_id = 'RI2824' AND p.period_name = 'AUG-2026'
 GROUP BY w.week_start, w.week_end, w.submission_status, e.source, e.entry_type
 ORDER BY w.week_start, e.source;

PROMPT
PROMPT ============================================================
PROMPT THE GUARD ITSELF IS FIXED IN 09_pkg_oc_time.sql
PROMPT ============================================================
PROMPT
PROMPT This script only clears what has already happened. Re-run
PROMPT 09_pkg_oc_time.sql for the fix, or the next populate over any defaulted
PROMPT week puts the duplicates straight back.
