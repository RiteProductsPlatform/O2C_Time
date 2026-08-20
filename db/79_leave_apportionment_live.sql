--==============================================================
-- time/79_leave_apportionment_live.sql
-- O2C Timesheet Module — the live absence loop had its own MIN(project_id)
--
-- db/09 taught populate_month to split a day's leave across the allocations by
-- ALLOC_PCT. That fixed the MONTHLY job and nothing else, because the live
-- browser loop does not go through populate_month at all:
--
--   PAGE-001 load -> refreshAbsenceChain -> POST sync/absence
--                 -> oc_time_sync_leave  (db/44)
--
-- and oc_time_sync_leave carries its OWN copy of the rule, twice. Left alone it
-- does not merely fail to apportion -- it actively undoes it. The retract half
-- decides a leave row is a stale duplicate when it is not on MIN(project_id):
--
--     AND e.project_id = (SELECT MIN(al.project_id) FROM oc_time_allocation al
--                          WHERE al.employee_id = w.employee_id
--                            AND al.status = 'Active')
--
-- With RI2824's day now split 4h/2h/2h across 444, 555 and PCS10034, the 555
-- and PCS10034 rows fail that test, read as stale, and are DELETED -- with an
-- audit row apiece saying the leave was withdrawn, which nobody did. The next
-- page load would have silently put the whole day back on 444 and left a trail
-- claiming a withdrawal. Found before testing, not after.
--
-- Same lesson as the sync-handler drift already in CLAUDE.md: check the whole
-- surface, not the handler in front of you. Two producers, one rule, and the
-- rule was written down twice.
--
-- THE RULE, now in one place. OC_TIME_LEAVE_SHARE returns the apportioned
-- hours per project for one employee-day, so populate_month, oc_time_sync_leave
-- and anything later cannot drift again. It is a pipelined-free plain view
-- function returning a cursor-friendly collection, because the callers need it
-- in a FOR loop and in a NOT EXISTS.
--
-- WHAT MATCHES db/09 EXACTLY, because a difference here is a difference in the
-- numbers depending on which producer ran last:
--   * allocations covering the ABSENCE DATE, not merely Active today
--   * divided by the allocations' own SUM, not by 100
--   * the rounding remainder to the last row, so the shares sum exactly
--   * aggregated per DAY -- two absence types on one date are two rows in
--     OC_TIME_ABSENCE but one cell per project in OC_TS_ENTRY
--
-- Idempotent. Depends on: time/03, 09, 44.
-- RUN db/09 FIRST -- this assumes populate_month already apportions.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_SYNC_LEAVE' AND object_type = 'PROCEDURE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'OC_TIME_SYNC_LEAVE does not exist here. '
      || 'Run db/44_leave_and_allocation_retraction.sql first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1-2/4] V_OC_TS_LEAVE_SHARE - superseded, see db/94
PROMPT ============================================================

-- BOTH SECTIONS DELIBERATELY DO NOTHING NOW.
--
-- [1/4] built the view, dividing the day by PCT_TOTAL -- the sum of that
-- person's allocation percentages -- rather than by 100. That is only correct
-- when somebody's allocations happen to add to exactly 100. A 50%-allocated
-- person had the whole day pushed onto their one project; a person on two
-- full-time projects had each of them charged half a day.
--
-- [2/4] proved the shares sum to the day, and that is precisely the property
-- being withdrawn. A 50%-allocated person's shares should sum to HALF the day,
-- because the other half was never any project's to lose. Re-running that proof
-- against the corrected view reports MISMATCH and tells the reader to stop,
-- which would be exactly the wrong advice.
--
-- Section [3/4] below is still live: OC_TIME_SYNC_LEAVE reads the view rather
-- than restating the rule, which is what made this a one-place fix.
--
-- The live definition is db/94_leave_share_is_the_allocation.sql [2/5], with
-- the per-row check in [5/5].

BEGIN
  DBMS_OUTPUT.PUT_LINE('  Left alone. The live definition is db/94 [2/5].');
END;
/

PROMPT ============================================================
PROMPT [3/4] OC_TIME_SYNC_LEAVE - superseded, see db/80 [3/4]
PROMPT ============================================================

-- THIS SECTION DELIBERATELY DOES NOTHING NOW, and the reason predates today.
--
-- Two files define OC_TIME_SYNC_LEAVE. db/80 added the call to
-- oc_time_leave_displace, which is what stops a full day of leave sitting
-- beside worked hours. THIS copy does not have it. Running 79 after 80
-- therefore turned leave displacement off entirely -- silently, because the
-- procedure still exists, still succeeds, and still reports rows applied.
--
-- Found 21-Aug while correcting the split. Nothing had gone wrong from it yet;
-- the two files simply had to be run in an order nobody had written down.
--
-- The live definition is db/80_leave_displaces_hours.sql [3/4].

BEGIN
  DBMS_OUTPUT.PUT_LINE('  Left alone. The live definition is db/80 [3/4].');
END;
/

PROMPT ============================================================
PROMPT [4/4] Re-split what is already there
PROMPT ============================================================

-- Existing leave rows were written by the old rule and all sit on one project.
-- Re-run over every period that has leave so the cache matches the rule; the
-- procedure is idempotent, so this is also the repair for any half-applied
-- state left by an earlier run.
DECLARE
  v_from DATE; v_to DATE;
BEGIN
  SELECT MIN(absence_date), MAX(absence_date) INTO v_from, v_to
    FROM oc_time_absence WHERE approval_status = 'Approved';
  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('  No approved absence; nothing to re-split.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  Re-splitting ' || TO_CHAR(v_from,'DD-Mon-YY')
                      || ' to ' || TO_CHAR(v_to,'DD-Mon-YY'));
    oc_time_sync_leave(v_from, v_to, NULL, 'APPORTION_79');
  END IF;
END;
/

COLUMN employee_name FORMAT A24
COLUMN project_number FORMAT A12
SELECT w.employee_id, wk.employee_name,
       TO_CHAR(e.entry_date,'DD-Mon-YY') AS entry_date,
       p.project_number, e.hours,
       SUM(e.hours) OVER (PARTITION BY w.employee_id, e.entry_date) AS day_total
  FROM oc_ts_entry e
  JOIN oc_ts_week      w  ON w.ts_week_id  = e.ts_week_id
  JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
  JOIN oc_time_project p  ON p.project_id  = e.project_id
 WHERE e.is_leave = 'Y'
   AND w.employee_id IN ('RI2824','RI2894','RI2900','RI9001','RI2249')
 ORDER BY w.employee_id, e.entry_date, p.project_number;

PROMPT
PROMPT RI2824 is 50/25/25 across 444, 555 and PCS10034, so a leave day should
PROMPT show three rows whose DAY_TOTAL equals their standard day.
PROMPT
PROMPT NOW SAFE TO TEST apply -> withdraw -> apply from Fusion.
