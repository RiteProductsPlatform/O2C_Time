--==============================================================
-- time/80_leave_displaces_hours.sql
-- O2C Timesheet Module — leave puts hours aside; withdrawing gives them back
--
-- Review 18-Aug-2026, walked through in the room:
--
--   RV : "See, after applying leave, assume that I went and changed the data
--         for Wednesday ... and now I am going and cancelling my leave."
--   RV : "don't bring it back from the old version and all that."
--   Sam: "Then it should come to the latest entered value only, right?"
--   RV : "Yeah."
--
-- Two scenarios, and BOTH were wrong, in different ways.
--
-- APPLY. oc_time_sync_leave writes the leave rows and stops. Clearing the work
-- on that day happens only in populate_month, and only for rows it wrote
-- itself (source = 'Prepopulated'). Hours the employee saved are source
-- 'Employee', so nothing touched them: Wednesday carried 8 hours of work AND
-- 8 hours of leave. Sixteen hours against a standard of eight, on screen,
-- until the week was submitted and the new day-total check refused it.
--
-- WITHDRAW. oc_time_restore_default_hours recomputes standard x alloc_pct --
-- the PREPOPULATED figure. So a week where somebody had typed 6 and 2 came
-- back as 4 and 4. That is precisely "bringing it back from the old version",
-- which is what was ruled out.
--
-- WHY A COLUMN AND NOT THE AUDIT TRAIL. OC_TS_AUDIT does hold the displaced
-- value -- OLD_HOURS on the row the leave zeroed -- and the first design read
-- it back from there. It works and it is fragile: finding "the row the leave
-- zeroed" means matching week, date, project, task and change type, then
-- taking the latest, and every one of those is a guess about which write was
-- the leave. PRE_LEAVE_HOURS holds the answer rather than the evidence for it.
-- The audit trail still records both the zeroing and the restore, so nothing
-- is lost by not parsing it.
--
-- THE RULES, and each is doing work:
--
--   FULL-DAY LEAVE ONLY. A half day leaves the rest genuinely workable, and
--   emptying it would send somebody to their manager to re-enter hours they
--   did work. Same test validate_day already uses for -20002.
--
--   EVERY SOURCE, not just Prepopulated. That restriction is right for a job
--   that ERASES and wrong for one that puts aside: the employee's saved hours
--   are exactly what has to survive the round trip.
--
--   PRE_LEAVE_HOURS IS NULL before displacing. A second sync over the same day
--   would otherwise overwrite the remembered 8 with the current 0, and the
--   hours would be gone for good on the second page load rather than the first.
--
--   HOURS = 0 before restoring. If somebody has typed on the day since, that
--   is newer than what leave displaced and it stands.
--
-- The fallback chain is unchanged and still correct: sync_leave restores what
-- it remembers, then oc_time_restore_default_hours fills anything still at
-- zero with the populate default -- which is right for a row that predates
-- this column and has nothing remembered.
--
-- Idempotent. Depends on: time/03, 09, 44, 61, 79.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TS_ENTRY';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] OC_TS_ENTRY.PRE_LEAVE_HOURS
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE
    'ALTER TABLE oc_ts_entry ADD (PRE_LEAVE_HOURS NUMBER(6,2))';
  DBMS_OUTPUT.PUT_LINE('PRE_LEAVE_HOURS added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN
    DBMS_OUTPUT.PUT_LINE('PRE_LEAVE_HOURS already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- ONE LITERAL, NOT AN EXPRESSION. COMMENT ON ... IS takes a quoted string and
-- nothing else -- no concatenation, no bind, no function. The || form raises
-- ORA-00933 "SQL command not properly ended", which points at the statement
-- rather than at the operator and reads like a typo somewhere else entirely.
COMMENT ON COLUMN oc_ts_entry.pre_leave_hours IS
  'Hours this cell held before full-day leave displaced them. Restored verbatim when the absence is withdrawn, then cleared. NULL means nothing is held aside.';

PROMPT ============================================================
PROMPT [2/4] OC_TIME_LEAVE_DISPLACE — put the day aside, or give it back
PROMPT ============================================================

-- Called by oc_time_sync_leave for the window it is syncing. Split out rather
-- than inlined so the two halves can be read, and tested, on their own.
CREATE OR REPLACE PROCEDURE oc_time_leave_displace(
  p_from        IN  DATE,
  p_to          IN  DATE,
  p_employee_id IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'ABSENCE_SYNC',
  o_put_aside   OUT NUMBER,
  o_given_back  OUT NUMBER)
IS
BEGIN
  -- ── PUT ASIDE ──────────────────────────────────────────────
  -- A day whose leave covers the whole standard day carries no worked hours
  -- (RULE-008). The value is remembered, not discarded.
  UPDATE oc_ts_entry e
     SET e.pre_leave_hours = e.hours,
         e.hours           = 0,
         e.updated_by      = p_actor,
         e.updated_on      = SYSTIMESTAMP
   WHERE e.is_leave        = 'N'
     AND e.entry_type     IN ('Actual','Default')
     AND e.hours           > 0
     AND e.pre_leave_hours IS NULL
     AND e.entry_date BETWEEN p_from AND p_to
     AND EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id
                    AND (p_employee_id IS NULL OR w.employee_id = p_employee_id))
     -- Full-day leave on this cell's own date, in its own week. Compared
     -- against the standard recorded on the day rather than the worker's
     -- global figure, so a 9-hour day is judged against nine.
     AND (SELECT NVL(SUM(l.hours),0) FROM oc_ts_entry l
           WHERE l.ts_week_id = e.ts_week_id
             AND l.entry_date = e.entry_date
             AND l.is_leave   = 'Y')
         >= (SELECT NVL(MAX(s.standard_hours),0) FROM oc_ts_entry s
              WHERE s.ts_week_id = e.ts_week_id
                AND s.entry_date = e.entry_date)
     AND (SELECT NVL(MAX(s.standard_hours),0) FROM oc_ts_entry s
           WHERE s.ts_week_id = e.ts_week_id
             AND s.entry_date = e.entry_date) > 0;
  o_put_aside := SQL%ROWCOUNT;

  -- ── GIVE BACK ──────────────────────────────────────────────
  -- The leave has gone from the day and the cell has not been touched since,
  -- so what it held before is what it should hold now.
  UPDATE oc_ts_entry e
     SET e.hours           = e.pre_leave_hours,
         e.pre_leave_hours = NULL,
         e.updated_by      = p_actor,
         e.updated_on      = SYSTIMESTAMP
   WHERE e.pre_leave_hours IS NOT NULL
     AND e.hours            = 0
     AND e.is_leave         = 'N'
     AND e.entry_date BETWEEN p_from AND p_to
     AND EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id
                    AND (p_employee_id IS NULL OR w.employee_id = p_employee_id))
     AND NOT EXISTS (SELECT 1 FROM oc_ts_entry l
                      WHERE l.ts_week_id = e.ts_week_id
                        AND l.entry_date = e.entry_date
                        AND l.is_leave   = 'Y'
                        AND l.hours      > 0);
  o_given_back := SQL%ROWCOUNT;
END oc_time_leave_displace;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] OC_TIME_SYNC_LEAVE calls it
PROMPT ============================================================

-- Only the tail of the procedure changes: after the retract and apply halves
-- have settled which leave rows exist, the displacement is decided from what
-- is actually on the day. Doing it in that order is what makes one pass
-- correct for both directions -- apply and withdraw differ only in whether a
-- leave row survives, and this reads the answer rather than being told it.
CREATE OR REPLACE PROCEDURE oc_time_sync_leave(
  p_from        IN DATE,
  p_to          IN DATE,
  p_employee_id IN VARCHAR2 DEFAULT NULL,
  p_actor       IN VARCHAR2 DEFAULT 'ABSENCE_SYNC')
IS
  v_task    NUMBER;
  v_week    NUMBER;
  v_added   NUMBER := 0;
  v_pulled  NUMBER := 0;
  v_unappr  NUMBER := 0;
  v_aside   NUMBER := 0;
  v_back    NUMBER := 0;
  v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
BEGIN
  SELECT task_id INTO v_task
    FROM oc_time_task
   WHERE task_type = 'COMMON' AND UPPER(task_code) = 'LEAVE';

  -- ── RETRACT ────────────────────────────────────────────────
  -- A leave row with no share behind it: the absence was withdrawn, or the
  -- split moved and this project is no longer in it.
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
             SELECT 1 FROM v_oc_ts_leave_share ls
              WHERE ls.employee_id  = w.employee_id
                AND ls.absence_date = e.entry_date
                AND ls.project_id   = e.project_id)
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
      'Leave no longer applies to this project ('
        || NVL(e.absence_type,'Leave') || '): the absence was withdrawn or the '
        || 'allocation split changed. Row removed by the sync.',
      p_actor, SYSTIMESTAMP);

    DELETE FROM oc_ts_entry WHERE ts_entry_id = e.ts_entry_id;
    v_pulled := v_pulled + 1;

    -- A DECIDED WEEK GOES BACK. The hours changed after the manager looked at
    -- them, which is precisely DailyChange. A Pending week needs no event:
    -- nobody has judged it yet, and firing one would only add noise.
    IF e.approval_status <> 'Pending' THEN
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', p_actor, v_s, v_a, v_f);
        v_unappr := v_unappr + 1;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;

  -- ── APPLY ──────────────────────────────────────────────────
  -- One row per project per day, at its apportioned share.
  FOR ls IN (
    SELECT ls.employee_id, ls.absence_date, ls.absence_type,
           ls.project_id, ls.share_hours
      FROM v_oc_ts_leave_share ls
     WHERE ls.absence_date BETWEEN p_from AND p_to
       AND (p_employee_id IS NULL OR ls.employee_id = p_employee_id)
  ) LOOP
    -- Resolved into a variable BEFORE the MERGE, never called inside it.
    -- ensure_week performs DML and a function that does cannot be called from
    -- a SQL statement -- ORA-14551, raised at runtime rather than compile time.
    v_week := oc_time_pkg.ensure_week(ls.employee_id, ls.absence_date, p_actor);

    MERGE INTO oc_ts_entry e
    USING (SELECT v_week AS wk, ls.project_id AS pid,
                  v_task AS tid, ls.absence_date AS d FROM dual) s
       ON (e.ts_week_id = s.wk AND e.project_id = s.pid
       AND e.task_id    = s.tid AND e.entry_date = s.d
       AND e.entry_type = 'Actual')
     WHEN MATCHED THEN UPDATE
          SET e.hours        = ls.share_hours,
              e.is_leave     = 'Y',
              e.absence_type = ls.absence_type,
              e.source       = 'Absence',
              e.updated_by   = p_actor
     WHEN NOT MATCHED THEN
          INSERT (ts_week_id, project_id, task_id, entry_date, hours,
                  entry_type, is_leave, absence_type, source,
                  billable_type, unbilled_reason, created_by)
          VALUES (s.wk, s.pid, s.tid, s.d, ls.share_hours,
                  'Actual', 'Y', ls.absence_type, 'Absence',
                  'Non-billable', 'Leave', p_actor);
    v_added := v_added + SQL%ROWCOUNT;
  END LOOP;

  -- ── DISPLACE / RESTORE ─────────────────────────────────────
  -- Runs LAST, so it reads the day as the two halves above have left it.
  oc_time_leave_displace(p_from, p_to, p_employee_id, p_actor, v_aside, v_back);

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_pulled || ' leave row(s) retracted, '
    || v_unappr || ' decided week(s) sent back, '
    || v_added  || ' applied, '
    || v_aside  || ' work row(s) put aside, '
    || v_back   || ' given back');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] Settle the days that are already wrong
PROMPT ============================================================

-- Defining the procedure changes nothing that has already happened. Every day
-- carrying a full day of leave AND worked hours was written before this script
-- existed and stays that way until something looks at it -- which is why the
-- first run reported 2 rather than 0.
--
-- Displacement only, not the whole sync: retract and apply are about which
-- leave rows should exist and they are already correct after db/79. This is
-- the one pass that has never run.
--
-- Anything put aside here is recoverable in the ordinary way: withdraw the
-- absence and the next page load gives it back.
DECLARE
  v_from DATE; v_to DATE; v_aside NUMBER; v_back NUMBER;
BEGIN
  SELECT MIN(entry_date), MAX(entry_date) INTO v_from, v_to FROM oc_ts_entry;

  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('  No timesheet entries; nothing to settle.');
  ELSE
    -- oc_time_leave_displace does NOT commit -- only oc_time_sync_leave does,
    -- and that is deliberate so a caller can wrap both halves. Committed here
    -- because this block is the caller.
    oc_time_leave_displace(v_from, v_to, NULL, 'DISPLACE_80', v_aside, v_back);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  ' || TO_CHAR(v_from,'DD-Mon-YY') || ' to '
      || TO_CHAR(v_to,'DD-Mon-YY') || ': ' || v_aside
      || ' work row(s) put aside, ' || v_back || ' given back.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN employee_id FORMAT A10
COLUMN project_number FORMAT A12
COLUMN task_code FORMAT A12
SELECT w.employee_id, TO_CHAR(e.entry_date,'DD-Mon') AS entry_date,
       p.project_number, t.task_code,
       e.hours, e.pre_leave_hours AS held_aside, e.is_leave, e.source
  FROM oc_ts_entry e
  JOIN oc_ts_week      w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_project p ON p.project_id = e.project_id
  JOIN oc_time_task    t ON t.task_id    = e.task_id
 WHERE e.pre_leave_hours IS NOT NULL
 ORDER BY w.employee_id, e.entry_date, p.project_number;

PROMPT
PROMPT Rows above are holding hours aside behind a full day of leave. Withdraw
PROMPT the absence in Fusion, reload PAGE-001, and HELD_ASIDE moves back into
PROMPT HOURS and clears.

SELECT COUNT(*) AS days_with_leave_and_work
  FROM (SELECT e.ts_week_id, e.entry_date
          FROM oc_ts_entry e
         GROUP BY e.ts_week_id, e.entry_date
        HAVING SUM(CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END) >=
               NVL(MAX(e.standard_hours),0)
           AND NVL(MAX(e.standard_hours),0) > 0
           AND SUM(CASE WHEN e.is_leave = 'N' THEN e.hours ELSE 0 END) > 0);

PROMPT
PROMPT Must be 0. Any row is a day carrying a full day of leave AND worked
PROMPT hours - the 16-hour Wednesday this script exists to stop.
