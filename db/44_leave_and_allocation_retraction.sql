--==============================================================
-- time/44_leave_and_allocation_retraction.sql
-- O2C Timesheet Module — the sync learns to take things back
--
-- Three symptoms, one cause: the sync ADDS and UPDATES but never RETRACTS.
--
--   * A person's leave shows twice. Both populate_month and populate_daily
--     pick ONE project for leave -- MIN(active allocation) -- which is right.
--     But the MERGE matches on PROJECT_ID, so when a second allocation with a
--     lower id appears, MIN returns a different project, the MERGE finds no
--     match, inserts a new leave row, and the old one stays. Observed 15-Aug:
--     16 + 16 = 32 leave hours for two days off, and 16.00 entered against a
--     standard of 8.00.
--
--   * A withdrawn absence stays on the timesheet. The live panel re-reads
--     Fusion per person per date so it disappears from the screen, but the
--     OC_TS_ENTRY row persists -- populate only looks at absences that ARE
--     approved, and nothing deletes what a withdrawal left behind. The screen
--     shows no absence while the hours still flow to accrual. Half-reflecting
--     is worse than not reflecting at all, because nothing looks wrong.
--
--   * A person removed from a project in PPM keeps their allocation. The
--     allocation MERGE has no NOT MATCHED BY SOURCE branch and there is no
--     deactivation pass, so they keep the project in their LOV and keep
--     counting toward the manager's team, indefinitely.
--
-- DECIDED 15-Aug-2026:
--   1. A withdrawn absence MAY un-approve a week. Correct: the hours changed
--      after the manager looked at them, and DailyChange is exactly that event.
--   2. The retracted row is DELETED, but must survive in history.
--   3. Membership of a project is decided by the EFFECTIVE DATES, not by
--      disappearing from the feed. PPM end-dates the assignment; we honour it.
--
-- Idempotent. Depends on: time/43
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
PROMPT [1/7] OC_TIME_ALLOCATION_ACTIVE_ON — one definition of "on the project"
PROMPT ============================================================

-- Membership is a DATE RANGE, not a flag. Today only populate looks at the
-- dates, and only at one end of them (end_date >= period start); the
-- allocation pop-up and the RULE-001 percentage total both read STATUS alone,
-- so an allocation that ended in June still appears and still counts.
--
-- A function rather than a repeated predicate, because the same question is
-- asked in five places and they had drifted apart.
CREATE OR REPLACE FUNCTION oc_time_alloc_active_on(
  p_start IN DATE,
  p_end   IN DATE,
  p_on    IN DATE DEFAULT NULL) RETURN VARCHAR2
DETERMINISTIC
IS
  v_on DATE := NVL(p_on, TRUNC(SYSDATE));
BEGIN
  -- A null start means "always has been", a null end means "still is". Fusion
  -- leaves the end open on a current assignment, so a null there is the normal
  -- case and must not read as expired.
  RETURN CASE
           WHEN p_start IS NOT NULL AND v_on < p_start THEN 'N'
           WHEN p_end   IS NOT NULL AND v_on > p_end   THEN 'N'
           ELSE 'Y'
         END;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/7] V_OC_TS_ALLOCATION honours the dates
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_allocation AS
SELECT al.allocation_id,
       al.employee_id,
       w.employee_name,
       al.project_id,
       p.project_number,
       p.project_name,
       p.customer_name,
       p.project_type,
       p.revenue_model,
       al.alloc_pct,
       al.billing_status,
       al.client_role,
       al.cap_type,
       al.cap_hours,
       al.approving_manager_id,
       mw.employee_name AS approving_manager_name,
       TO_CHAR(al.start_date,'YYYY-MM-DD') AS start_date,
       TO_CHAR(al.end_date,  'YYYY-MM-DD') AS end_date,
       al.status,
       -- RULE-001 totals only what is effective TODAY. Summing expired
       -- allocations produced totals over 100% and a warning nobody could act
       -- on -- the offending row was not on screen, because the pop-up filtered
       -- them out by date while the total did not.
       SUM(al.alloc_pct) OVER (PARTITION BY al.employee_id) AS total_alloc_pct
  FROM oc_time_allocation al
  JOIN oc_time_worker  w  ON w.employee_id  = al.employee_id
  JOIN oc_time_project p  ON p.project_id   = al.project_id
  LEFT JOIN oc_time_worker mw ON mw.employee_id = al.approving_manager_id
 WHERE al.status = 'Active'
   AND oc_time_alloc_active_on(al.start_date, al.end_date) = 'Y';

PROMPT ============================================================
PROMPT [3/7] ALLOCATION_PCT counts only what is effective today
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_expire_allocations(
  p_actor IN VARCHAR2 DEFAULT 'SYNC')
IS
  v_n NUMBER;
BEGIN
  -- PPM end-dates an assignment when somebody is taken off a project; it does
  -- not delete it, and neither do we. Status follows the dates so every reader
  -- that filters on Active gets the right answer without also knowing the rule.
  UPDATE oc_time_allocation
     SET status     = 'Inactive',
         updated_by = p_actor,
         updated_on = SYSTIMESTAMP
   WHERE status = 'Active'
     AND oc_time_alloc_active_on(start_date, end_date) = 'N';
  v_n := SQL%ROWCOUNT;

  -- And back again, because an end date can be extended or cleared upstream.
  -- Without this an allocation expired by a typo would never recover.
  UPDATE oc_time_allocation
     SET status     = 'Active',
         updated_by = p_actor,
         updated_on = SYSTIMESTAMP
   WHERE status = 'Inactive'
     AND oc_time_alloc_active_on(start_date, end_date) = 'Y'
     AND fusion_synced_on IS NOT NULL;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' allocation(s) expired by date, '
                    || SQL%ROWCOUNT || ' reinstated');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/7] OC_TIME_SYNC_LEAVE — one leave row, and it can be taken back
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_sync_leave(
  p_from        IN DATE,
  p_to          IN DATE,
  p_employee_id IN VARCHAR2 DEFAULT NULL,
  p_actor       IN VARCHAR2 DEFAULT 'ABSENCE_SYNC')
IS
  v_task    NUMBER;
  v_week    NUMBER;
  v_added   NUMBER := 0;
  v_moved   NUMBER := 0;
  v_pulled  NUMBER := 0;
  v_unappr  NUMBER := 0;
  v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
BEGIN
  SELECT task_id INTO v_task
    FROM oc_time_task
   WHERE task_type = 'COMMON' AND UPPER(task_code) = 'LEAVE';

  -- ── RETRACT ────────────────────────────────────────────────
  -- Every leave row in range with no matching APPROVED absence behind it.
  -- Two causes, handled identically: the absence was withdrawn, or the row is
  -- a stale duplicate left on a project that MIN(allocation) no longer picks.
  FOR e IN (
    SELECT e.ts_entry_id, e.ts_week_id, e.entry_date, e.project_id, e.task_id,
           e.hours, e.absence_type, w.employee_id, w.period_id,
           w.approval_status
      FROM oc_ts_entry e
      JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
     WHERE e.is_leave = 'Y'
       AND e.entry_date BETWEEN p_from AND p_to
       AND (p_employee_id IS NULL OR w.employee_id = p_employee_id)
       AND NOT EXISTS (
             SELECT 1 FROM oc_time_absence ab
              WHERE ab.employee_id    = w.employee_id
                AND ab.absence_date   = e.entry_date
                AND ab.approval_status = 'Approved'
                -- the row must ALSO be on the project leave belongs to now,
                -- or it is the stale copy and goes the same way
                AND e.project_id = (SELECT MIN(al.project_id)
                                      FROM oc_time_allocation al
                                     WHERE al.employee_id = w.employee_id
                                       AND al.status = 'Active'))
  ) LOOP

    -- HISTORY FIRST. There is no DELETE trigger on OC_TS_ENTRY -- the audit
    -- triggers are BEFORE UPDATE OF -- so a deleted row would otherwise leave
    -- no trace at all. Written before the delete so the values are still here.
    INSERT INTO oc_ts_audit (
      ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
      old_project_id, old_task_id, old_hours, old_bill_type,
      new_project_id, new_task_id, new_hours,
      change_reason, changed_by, changed_on)
    VALUES (
      e.ts_entry_id, e.ts_week_id, e.employee_id, e.entry_date, 'AbsenceSync',
      e.project_id, e.task_id, e.hours, 'Non-billable',
      NULL, NULL, 0,
      'Leave withdrawn in the absence module (' || NVL(e.absence_type,'Leave')
        || '); row removed by the sync.',
      p_actor, SYSTIMESTAMP);

    DELETE FROM oc_ts_entry WHERE ts_entry_id = e.ts_entry_id;
    v_pulled := v_pulled + 1;

    -- A DECIDED WEEK GOES BACK. The hours changed after the manager looked at
    -- them, which is precisely DailyChange -- confirmed 15-Aug that a withdrawn
    -- absence may un-approve a week. A Pending week needs no event: nobody has
    -- judged it yet, and firing one would only add noise to its version trail.
    IF e.approval_status <> 'Pending' THEN
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', p_actor, v_s, v_a, v_f);
        v_unappr := v_unappr + 1;
      EXCEPTION WHEN OTHERS THEN
        -- Never let a missing rule strand a half-retracted week: the row is
        -- already gone and the audit already written.
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;

  -- ── APPLY ──────────────────────────────────────────────────
  -- One row per employee per date, on the project MIN(allocation) picks. The
  -- retraction above has already removed any copy on a project it no longer
  -- picks, so this cannot leave a second one behind.
  FOR ab IN (
    SELECT ab.employee_id, ab.absence_date, ab.absence_hours, ab.absence_type,
           (SELECT MIN(al.project_id) FROM oc_time_allocation al
             WHERE al.employee_id = ab.employee_id
               AND al.status = 'Active') AS project_id
      FROM oc_time_absence ab
     WHERE ab.absence_date BETWEEN p_from AND p_to
       AND ab.approval_status = 'Approved'
       AND (p_employee_id IS NULL OR ab.employee_id = p_employee_id)
  ) LOOP
    CONTINUE WHEN ab.project_id IS NULL;

    -- Resolved into a variable BEFORE the MERGE, never called inside it.
    -- ensure_week INSERTs a missing week, and a function that performs DML
    -- cannot be called from a SQL statement -- ORA-14551, raised at runtime
    -- rather than at compile time, so it would have passed every check here
    -- and failed on the first absence the sync tried to apply.
    v_week := oc_time_pkg.ensure_week(ab.employee_id, ab.absence_date, p_actor);

    MERGE INTO oc_ts_entry e
    USING (SELECT v_week AS wk, ab.project_id AS pid,
                  v_task AS tid, ab.absence_date AS d FROM dual) s
       ON (e.ts_week_id = s.wk AND e.project_id = s.pid
       AND e.task_id    = s.tid AND e.entry_date = s.d
       AND e.entry_type = 'Actual')
     WHEN MATCHED THEN UPDATE
          SET e.hours        = ab.absence_hours,
              e.is_leave     = 'Y',
              e.absence_type = ab.absence_type,
              e.source       = 'Absence',
              e.updated_by   = p_actor
     WHEN NOT MATCHED THEN
          INSERT (ts_week_id, project_id, task_id, entry_date, hours,
                  entry_type, is_leave, absence_type, source,
                  billable_type, unbilled_reason, created_by)
          VALUES (s.wk, s.pid, s.tid, s.d, ab.absence_hours,
                  'Actual', 'Y', ab.absence_type, 'Absence',
                  'Non-billable', 'Leave', p_actor);
    v_added := v_added + SQL%ROWCOUNT;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_pulled || ' leave row(s) retracted, '
    || v_unappr || ' decided week(s) sent back, '
    || v_added  || ' applied');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [5/7] OC_TS_AUDIT must accept 'AbsenceSync' before the sweep
PROMPT ============================================================

-- 25_absence_source.sql meant to widen this and missed. It dropped
-- 'chk_oc_tsa_ctype'; the constraint 04_approval_audit.sql creates is
-- 'chk_oc_tsau_type'. The drop failed with ORA-02443, the handler swallowed
-- it, a second constraint was added, and the original -- which rejects
-- AbsenceSync -- stayed. A row must satisfy both, so the retraction below
-- failed with ORA-02290 on the very first audit row it wrote.
--
-- Repeated here rather than left to a re-run of 25, because this script
-- cannot do its work without it and must be runnable on its own. Driven off
-- the dictionary so it does not matter what the constraint is called.
DECLARE
  v_done NUMBER := 0;
BEGIN
  FOR c IN (SELECT constraint_name
              FROM user_constraints
             WHERE table_name      = 'OC_TS_AUDIT'
               AND constraint_type = 'C'
               AND UPPER(search_condition_vc) LIKE '%CHANGE_TYPE%')
  LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_audit DROP CONSTRAINT ' || c.constraint_name;
    DBMS_OUTPUT.PUT_LINE('  dropped ' || c.constraint_name);
    v_done := v_done + 1;
  END LOOP;

  EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_audit ADD CONSTRAINT chk_oc_tsau_type
    CHECK (change_type IN ('Override','Adjustment','Reversal','ManagerEdit',
                           'Import','DefaultCorrection','AbsenceSync'))~';
  DBMS_OUTPUT.PUT_LINE('chk_oc_tsau_type now accepts AbsenceSync ('
                    || v_done || ' replaced)');
END;
/

PROMPT ============================================================
PROMPT [6/7] Clean up what is already there
PROMPT ============================================================

DECLARE
  v_from DATE;
  v_to   DATE;
BEGIN
  SELECT MIN(start_date), MAX(end_date) INTO v_from, v_to FROM oc_time_period;
  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('no periods; nothing to sync');
    RETURN;
  END IF;
  DBMS_OUTPUT.PUT_LINE('sweeping ' || TO_CHAR(v_from,'DD-MON-YY')
                    || ' to ' || TO_CHAR(v_to,'DD-MON-YY'));
  oc_time_sync_leave(v_from, v_to, NULL, 'CLEANUP-15AUG');
  oc_time_expire_allocations('CLEANUP-15AUG');
END;
/

PROMPT ============================================================
PROMPT [7/7] Verification
PROMPT ============================================================

PROMPT --- any employee/date still carrying more than one leave row
COLUMN employee_id FORMAT A14
SELECT w.employee_id, e.entry_date, COUNT(*) AS leave_rows,
       SUM(e.hours) AS leave_hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
 WHERE e.is_leave = 'Y'
 GROUP BY w.employee_id, e.entry_date
HAVING COUNT(*) > 1
 ORDER BY 1, 2;

PROMPT
PROMPT Must be empty. Any row is a day where the same absence is counted twice.

PROMPT
PROMPT --- leave with no approved absence behind it
SELECT COUNT(*) AS orphaned_leave
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
 WHERE e.is_leave = 'Y'
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = w.employee_id
                      AND ab.absence_date    = e.entry_date
                      AND ab.approval_status = 'Approved');

PROMPT
PROMPT --- allocations whose dates have passed but still read Active
SELECT COUNT(*) AS stale_active
  FROM oc_time_allocation
 WHERE status = 'Active'
   AND oc_time_alloc_active_on(start_date, end_date) = 'N';

PROMPT
PROMPT Both must be 0.

PROMPT
PROMPT ============================================================
PROMPT STILL TO WIRE
PROMPT ============================================================
PROMPT
PROMPT oc_time_sync_leave and oc_time_expire_allocations are not called by
PROMPT anything yet. Add both to the OIC daily run, after the absence and
PROMPT allocation feeds land and BEFORE populate_daily -- populate picks the
PROMPT leave project from MIN(active allocation), so expiring allocations
PROMPT afterwards would leave the leave row on a project the person has left.
PROMPT
PROMPT Note the ordering inside oc_time_sync_leave is the same rule: retract
PROMPT first, then apply. Applying first would re-create the row this run is
PROMPT about to delete.
