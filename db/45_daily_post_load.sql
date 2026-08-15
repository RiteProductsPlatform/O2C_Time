--==============================================================
-- time/45_daily_post_load.sql
-- O2C Timesheet Module — one procedure for OIC to call after the feeds land
--
-- WHY THIS IS NEEDED AT ALL
--   44 was a SWEEP, not a fix. It cleaned up the duplicate leave rows and the
--   32 expired allocations that were already there. Nothing calls
--   oc_time_sync_leave or oc_time_expire_allocations, so:
--
--     * the next populate re-creates a duplicate leave row the moment
--       anybody's allocation set changes -- populate has its OWN leave block,
--       with the same MIN(active allocation) and the same project-keyed MERGE
--       that caused the duplicates in the first place;
--     * a withdrawn absence stays on the timesheet for ever, because populate
--       only looks at absences that ARE approved and nothing removes what a
--       withdrawal left behind;
--     * a person end-dated in PPM keeps an Active allocation, because the
--       allocation merge has no NOT MATCHED BY SOURCE branch.
--
--   So the three bugs 44 fixed come straight back on the next daily run. That
--   is the whole reason for this script.
--
-- THE ORDER IS THE POINT, and I had it backwards in 44's closing note.
--
--   1. period health   weeks need a period id that resolves before anything
--                      else can join to one
--   2. expire alloc    leave picks MIN(ACTIVE allocation), so the active set
--                      has to be right BEFORE anything chooses a project
--   3. populate_daily  creates and refreshes the entries
--   4. sync_leave      LAST. populate creates the duplicate; only something
--                      running after it can remove one. Putting sync_leave
--                      first -- which is what 44's note said -- means populate
--                      re-creates exactly what was just deleted, and the
--                      cleanup silently achieves nothing.
--
--   In a steady state step 4 finds nothing: populate's MERGE matches the row
--   that is already there and updates it. It only has work to do when an
--   allocation changed or an absence was withdrawn, which is precisely when
--   somebody needs it to.
--
-- WHAT TO CHANGE IN OIC
--   Nothing structural, and no config row. The daily flow already has a
--   stored-procedure node calling populate. Point that one node at
--   OC_TIME_DAILY_POST_LOAD instead. OC_TIME_SYNC_CONFIG drives which BIP
--   reports load, not which procedures run, so it is not the place for this.
--
-- Idempotent. Depends on: time/44
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
PROMPT [1/3] OC_TIME_DAILY_POST_LOAD
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_daily_post_load(
  p_action_date IN DATE     DEFAULT TRUNC(SYSDATE),
  p_actor       IN VARCHAR2 DEFAULT 'OIC_DAILY',
  o_summary     OUT VARCHAR2)
IS
  v_job    NUMBER;
  v_from   DATE;
  v_to     DATE;
  v_step   VARCHAR2(40);
  v_note   VARCHAR2(400) := '';

  PROCEDURE note(p_txt VARCHAR2) IS
  BEGIN
    v_note := SUBSTR(v_note || CASE WHEN v_note IS NULL THEN '' ELSE '; ' END
                     || p_txt, 1, 400);
    DBMS_OUTPUT.PUT_LINE('  ' || p_txt);
  END note;

BEGIN
  -- The whole period containing the action date. Leave and allocations are
  -- month-shaped facts: an absence withdrawn today may sit three weeks back,
  -- and looking only at today would never find it.
  SELECT MIN(start_date), MAX(end_date) INTO v_from, v_to
    FROM oc_time_period
   WHERE p_action_date BETWEEN start_date AND end_date;

  IF v_from IS NULL THEN
    -- No period covers today. Say so and stop rather than sweeping every
    -- month ever loaded, which is what a null range would silently do.
    o_summary := 'No period covers ' || TO_CHAR(p_action_date,'DD-MON-YYYY')
              || '; nothing done.';
    DBMS_OUTPUT.PUT_LINE(o_summary);
    RETURN;
  END IF;

  -- ── 1. periods ─────────────────────────────────────────────
  v_step := 'period health';
  oc_time_daily_period_health;
  note('periods checked');

  -- ── 2. allocations ─────────────────────────────────────────
  -- Before anything picks a project, because "which project does this
  -- person's leave belong to" is answered with MIN(ACTIVE allocation).
  v_step := 'expire allocations';
  oc_time_expire_allocations(p_actor);
  note('allocations aged');

  -- ── 3. populate ────────────────────────────────────────────
  v_step := 'populate';
  v_job := oc_time_pkg.populate_daily(p_action_date, NULL, p_actor);
  note('populate job ' || v_job);

  -- ── 4. leave, LAST ─────────────────────────────────────────
  -- populate creates the duplicate leave row; only something running after it
  -- can take one away. This also retracts leave whose absence was withdrawn,
  -- and sends any already-decided week back through DailyChange.
  v_step := 'leave sync';
  oc_time_sync_leave(v_from, v_to, NULL, p_actor);
  note('leave reconciled ' || TO_CHAR(v_from,'DD-MON') || '..'
       || TO_CHAR(v_to,'DD-MON'));

  o_summary := 'OK: ' || v_note;

EXCEPTION WHEN OTHERS THEN
  -- Name the step. Without it the OIC fault handler reports an ORA number
  -- against "the daily job" and whoever picks it up has four procedures to
  -- read before they know which one stopped.
  o_summary := 'FAILED at ' || v_step || ': ' || SUBSTR(SQLERRM, 1, 300);
  DBMS_OUTPUT.PUT_LINE(o_summary);
  RAISE;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/3] Correct the ordering note left in 44
PROMPT ============================================================

PROMPT 44 closes by saying to run the leave sync BEFORE populate_daily.
PROMPT That is wrong and this script supersedes it: populate has its own leave
PROMPT block, so anything cleaning up before it runs is undone immediately.

PROMPT ============================================================
PROMPT [3/3] Dry run against today
PROMPT ============================================================

DECLARE
  v_out VARCHAR2(4000);
BEGIN
  oc_time_daily_post_load(TRUNC(SYSDATE), 'MANUAL-15AUG', v_out);
  DBMS_OUTPUT.PUT_LINE(CHR(10) || v_out);
END;
/

PROMPT
PROMPT --- nothing should be left for it to fix
SELECT COUNT(*) AS dup_leave_days FROM (
  SELECT w.employee_id, e.entry_date
    FROM oc_ts_entry e JOIN oc_ts_week w ON w.ts_week_id = e.ts_week_id
   WHERE e.is_leave = 'Y'
   GROUP BY w.employee_id, e.entry_date HAVING COUNT(*) > 1);

SELECT COUNT(*) AS stale_active FROM oc_time_allocation
 WHERE status = 'Active'
   AND oc_time_alloc_active_on(start_date, end_date) = 'N';

PROMPT
PROMPT ============================================================
PROMPT IN OIC
PROMPT ============================================================
PROMPT
PROMPT The daily flow already has a stored-procedure node calling populate.
PROMPT Point it at OC_TIME_DAILY_POST_LOAD instead and remove nothing else --
PROMPT this procedure calls populate itself, so leaving both would populate
PROMPT twice.
PROMPT
PROMPT It takes an action date and an actor, and returns O_SUMMARY. Map that to
PROMPT something the run log keeps: on failure it names the step that broke,
PROMPT which is the difference between "the daily job failed" and "the leave
PROMPT sync failed".
PROMPT
PROMPT No change to OC_TIME_SYNC_CONFIG. That table drives which BIP reports
PROMPT load; it has no notion of what runs afterwards.
