--==============================================================
-- time/52_roster_realign.sql
-- O2C Timesheet Module — a roster change reaches weeks already built
--
-- populate never revisits a day it has already created: the insert is guarded
-- by NOT EXISTS, which is what stops it trampling entered hours. The cost is
-- that a schedule assigned or changed AFTER a week was prepopulated never
-- reaches it. RI2824's 17-23 Aug week had to be deleted by hand to pick up
-- their Sunday-to-Thursday roster, and that does not scale past one person.
--
-- WHAT THIS DOES
--   For every day in range where the roster now says NON-WORKING but a
--   prepopulated row still sits, the row is removed. populate then fills any
--   day the roster now says IS working, because those cells are empty and its
--   own guard lets it. Two halves, and the second one is already built.
--
-- WHAT IT WILL NOT TOUCH, and these are the point
--   * anything a PERSON entered  - source is Employee, Manager or Import
--   * leave                      - IS_LEAVE = 'Y', owned by Absence
--   * Default, Reversal, Adjustment - a defaulted week's hours, and the
--                                  entries that offset them, are decisions
--   * a submitted or decided week - SUBMISSION_STATUS must be NotYetSubmitted
--   * a locked week              - LOCKED_FLAG must be 'N'
--   * a closed period            - the month must still be Open
--
--   So the worst it can do is remove hours that populate itself invented, on a
--   week nobody has looked at, in a month still open. Everything else it
--   leaves exactly where it is.
--
-- Idempotent -- a second run finds nothing, because the first one aligned it.
-- Depends on: time/51
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
PROMPT [1/4] OC_TIME_REALIGN_ROSTER
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_realign_roster(
  p_from        IN DATE,
  p_to          IN DATE,
  p_employee_id IN VARCHAR2 DEFAULT NULL,
  p_actor       IN VARCHAR2 DEFAULT 'ROSTER_REALIGN')
IS
  v_shift VARCHAR2(30);
  v_std   NUMBER;
  v_work  VARCHAR2(1);
  v_hol   VARCHAR2(200);
  v_del   NUMBER := 0;
  v_seen  NUMBER := 0;
BEGIN
  FOR e IN (
    SELECT e.ts_entry_id, e.ts_week_id, e.project_id, e.task_id, e.entry_date,
           e.hours, e.billable_type, w.employee_id
      FROM oc_ts_entry    e
      JOIN oc_ts_week     w ON w.ts_week_id = e.ts_week_id
      JOIN oc_time_period p ON p.period_id  = w.period_id
     WHERE e.entry_date BETWEEN p_from AND p_to
       -- Only what populate itself put there. An Employee, Manager or Import
       -- row is somebody's work and is never the roster's to remove.
       AND e.source       = 'Prepopulated'
       AND e.entry_type   = 'Actual'
       AND e.is_leave     = 'N'
       AND w.submission_status = 'NotYetSubmitted'
       AND w.locked_flag  = 'N'
       AND p.status       = 'Open'
       AND (p_employee_id IS NULL OR w.employee_id = p_employee_id)
  ) LOOP
    v_seen := v_seen + 1;

    -- The roster's current answer for that day, asked per row because
    -- resolve_day is the only thing that knows the layer precedence and the
    -- "missing day in a rostered week" rule.
    oc_time_pkg.resolve_day(e.employee_id, e.project_id, e.entry_date,
                            v_shift, v_std, v_work, v_hol);

    IF v_work = 'N' THEN
      -- Audited BEFORE the delete. There is no DELETE trigger on OC_TS_ENTRY,
      -- so an unaudited removal leaves nothing to explain why a day that had
      -- hours yesterday has none today.
      INSERT INTO oc_ts_audit (
        ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
        old_project_id, old_task_id, old_hours, old_bill_type,
        new_project_id, new_task_id, new_hours,
        change_reason, changed_by, changed_on)
      VALUES (
        e.ts_entry_id, e.ts_week_id, e.employee_id, e.entry_date,
        'DefaultCorrection',
        e.project_id, e.task_id, e.hours, e.billable_type,
        NULL, NULL, 0,
        'Roster now shows this day as non-working'
          || CASE WHEN v_hol IS NOT NULL THEN ' (' || v_hol || ')' END
          || '; prepopulated hours removed.',
        p_actor, SYSTIMESTAMP);

      DELETE FROM oc_ts_entry WHERE ts_entry_id = e.ts_entry_id;
      v_del := v_del + 1;
    END IF;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_seen || ' prepopulated day(s) checked, '
                    || v_del || ' removed as non-working');
  DBMS_OUTPUT.PUT_LINE('Days the roster has newly OPENED are filled by '
                    || 'populate, which runs next.');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/4] Put it in the daily chain, BEFORE populate
PROMPT ============================================================

-- Order matters and it is the same argument as the leave sync, one step
-- earlier. Realign removes the days the roster has closed; populate then fills
-- the days it has opened. Running populate first would leave the stale rows in
-- place for a whole day, and running realign after it would delete rows
-- populate had only just decided were correct.
--
--   period health -> expire allocations -> REALIGN -> populate -> leave sync
CREATE OR REPLACE PROCEDURE oc_time_daily_post_load(
  p_action_date IN DATE     DEFAULT TRUNC(SYSDATE),
  p_actor       IN VARCHAR2 DEFAULT 'OIC_DAILY',
  o_summary     OUT VARCHAR2,
  o_job_id      OUT NUMBER)
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
  SELECT MIN(start_date), MAX(end_date) INTO v_from, v_to
    FROM oc_time_period
   WHERE p_action_date BETWEEN start_date AND end_date;

  IF v_from IS NULL THEN
    o_summary := 'No period covers ' || TO_CHAR(p_action_date,'DD-MON-YYYY')
              || '; nothing done.';
    DBMS_OUTPUT.PUT_LINE(o_summary);
    RETURN;
  END IF;

  v_step := 'period health';
  oc_time_daily_period_health;
  note('periods checked');

  v_step := 'expire allocations';
  oc_time_expire_allocations(p_actor);
  note('allocations aged');

  -- NEW: the roster may have moved since these weeks were built.
  v_step := 'roster realign';
  oc_time_realign_roster(v_from, v_to, NULL, p_actor);
  note('roster realigned');

  v_step := 'populate';
  v_job := oc_time_pkg.populate_daily(p_action_date, NULL, p_actor);
  o_job_id := v_job;
  note('populate job ' || v_job);

  v_step := 'leave sync';
  oc_time_sync_leave(v_from, v_to, NULL, p_actor);
  note('leave reconciled ' || TO_CHAR(v_from,'DD-MON') || '..'
       || TO_CHAR(v_to,'DD-MON'));

  o_summary := 'OK: ' || v_note;

EXCEPTION WHEN OTHERS THEN
  o_summary := 'FAILED at ' || v_step || ': ' || SUBSTR(SQLERRM, 1, 300);
  DBMS_OUTPUT.PUT_LINE(o_summary);
  RAISE;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] Realign the open period now
PROMPT ============================================================

DECLARE
  v_from DATE; v_to DATE;
BEGIN
  SELECT MIN(start_date), MAX(end_date) INTO v_from, v_to
    FROM oc_time_period WHERE status = 'Open';
  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('no open period; nothing to realign');
    RETURN;
  END IF;
  DBMS_OUTPUT.PUT_LINE('realigning ' || TO_CHAR(v_from,'DD-MON-YY')
                    || ' to ' || TO_CHAR(v_to,'DD-MON-YY'));
  oc_time_realign_roster(v_from, v_to, NULL, 'MANUAL-16AUG');
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

PROMPT --- any prepopulated hours left on a day the roster calls non-working
SELECT COUNT(*) AS misaligned_days
  FROM oc_ts_entry    e
  JOIN oc_ts_week     w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_period p ON p.period_id  = w.period_id
 WHERE e.source     = 'Prepopulated'
   AND e.entry_type = 'Actual'
   AND e.is_leave   = 'N'
   AND w.submission_status = 'NotYetSubmitted'
   AND w.locked_flag = 'N'
   AND p.status      = 'Open'
   AND EXISTS (SELECT 1 FROM oc_time_calendar c
                WHERE c.layer     = 'SHIFT'
                  AND c.scope_key = w.employee_id
                  AND c.cal_date  = e.entry_date
                  AND c.is_working_day = 'N');

PROMPT
PROMPT Must be 0. This only catches the EXPLICIT non-working rows -- the
PROMPT inferred ones, where a rostered week simply has no row for a day, are
PROMPT resolve_day's judgement and cannot be checked with a join.

PROMPT
PROMPT --- RI2824's week, which is the one that started this
COLUMN day FORMAT A14
SELECT TO_CHAR(e.entry_date,'DY DD-Mon') AS day,
       COUNT(*) AS lines, SUM(e.hours) AS hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
 WHERE w.employee_id = 'RI2824'
   AND e.entry_date BETWEEN DATE '2026-08-17' AND DATE '2026-08-23'
 GROUP BY e.entry_date ORDER BY e.entry_date;

PROMPT
PROMPT Friday 21-Aug and Saturday 22-Aug should be GONE. Sunday 23-Aug will not
PROMPT appear until populate runs -- realign only removes, it never seeds. Run
PROMPT jobs/daily, or the OIC sync, and it fills in.
