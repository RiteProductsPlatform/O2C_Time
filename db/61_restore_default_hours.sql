--==============================================================
-- time/61_restore_default_hours.sql
-- O2C Timesheet Module — removing leave must give the day back
--
-- Withdrawing an absence emptied the day instead of restoring it. Observed on
-- RI2824, Monday 17-Aug-2026: standard_hours 8, is_leave 'N', day_total 0, and
-- both project rows sitting at zero with nothing to explain why.
--
-- THE ZEROING IS ONE-WAY. Three steps, each correct alone:
--
--   1. populate's allocation loop writes a standard day per active project
--   2. populate's leave loop then sets those rows to HOURS = 0 rather than
--      deleting them (RULE-008 -- a full day of leave takes the whole day),
--      touching only rows it created itself, SOURCE = 'Prepopulated'
--   3. oc_time_sync_leave later deletes the LEAVE row when the absence goes
--
-- Nothing undoes step 2. The work rows still exist at zero, so populate's own
-- guard -- NOT EXISTS a row of entry_type Actual/Default for that cell -- sees
-- them and skips, forever. A re-populate cannot fix it because from populate's
-- point of view the day is already seeded.
--
-- HOW A ZEROED ROW IS RECOGNISED
--   SOURCE = 'Prepopulated' AND HOURS = 0. populate never writes a zero-hour
--   row: it does CONTINUE when v_hours <= 0. So a prepopulated row at zero was
--   put there with hours and zeroed afterwards, and step 2 is the only thing
--   that does that. Typed hours are never touched -- those carry SOURCE
--   'Manual' or 'ManagerEdit', and a person who deliberately entered 0 owns
--   that decision.
--
-- The restored figure is recomputed the way populate computes it, from the
-- allocation and the day's standard hours, rather than remembered -- so an
-- allocation that changed while the person was away is honoured.
--
-- Idempotent, and safe on a day that still has leave: the guard requires no
-- APPROVED absence to remain.
--
-- Depends on: time/09, 44. Called from ords/13 (the live path) and db/45.
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
PROMPT [1/3] How many days are stranded at zero right now
PROMPT ============================================================

COLUMN employee_id FORMAT A12
COLUMN entry_date FORMAT A12
COLUMN project_name FORMAT A32
SELECT w.employee_id,
       TO_CHAR(e.entry_date,'YYYY-MM-DD') AS entry_date,
       p.project_name,
       e.standard_hours,
       e.hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_project p ON p.project_id = e.project_id
 WHERE e.source     = 'Prepopulated'
   AND e.is_leave   = 'N'
   AND e.hours      = 0
   AND e.entry_type IN ('Actual','Default')
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = w.employee_id
                      AND ab.absence_date    = e.entry_date
                      AND ab.approval_status = 'Approved')
 ORDER BY w.employee_id, e.entry_date, p.project_name
 FETCH FIRST 40 ROWS ONLY;

PROMPT
PROMPT Each row is a working day the person can no longer see hours on, with no
PROMPT leave left to explain it. Forty shown; the true count is below.

SELECT COUNT(*) AS stranded_rows,
       COUNT(DISTINCT w.employee_id) AS people,
       COUNT(DISTINCT e.entry_date)  AS days
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
 WHERE e.source     = 'Prepopulated'
   AND e.is_leave   = 'N'
   AND e.hours      = 0
   AND e.entry_type IN ('Actual','Default')
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = w.employee_id
                      AND ab.absence_date    = e.entry_date
                      AND ab.approval_status = 'Approved');

PROMPT ============================================================
PROMPT [2/3] OC_TIME_RESTORE_DEFAULT_HOURS
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_restore_default_hours(
  p_from        IN  DATE,
  p_to          IN  DATE,
  p_employee_id IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'LEAVE_RESTORE',
  o_restored    OUT NUMBER)
IS
  v_hours NUMBER;
BEGIN
  o_restored := 0;

  FOR e IN (
    SELECT e.ts_entry_id, e.ts_week_id, e.entry_date, e.project_id,
           w.employee_id, w.approval_status,
           -- The day's standard, from the row itself where populate recorded
           -- it and from the worker otherwise.
           NVL(e.standard_hours,
               (SELECT wk.std_hours_per_day FROM oc_time_worker wk
                 WHERE wk.employee_id = w.employee_id)) AS std,
           -- Recomputed, not remembered: an allocation changed while somebody
           -- was on leave should be reflected when they come back.
           NVL((SELECT MAX(al.alloc_pct) FROM oc_time_allocation al
                 WHERE al.employee_id = w.employee_id
                   AND al.project_id  = e.project_id
                   AND al.status      = 'Active'), 100) AS pct
      FROM oc_ts_entry e
      JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
     WHERE e.entry_date BETWEEN p_from AND p_to
       AND (p_employee_id IS NULL OR w.employee_id = p_employee_id)
       AND e.source     = 'Prepopulated'
       AND e.is_leave   = 'N'
       AND e.hours      = 0
       AND e.entry_type IN ('Actual','Default')
       -- The day must be genuinely clear. A half-day absence still standing
       -- means the zero may be deliberate, so it is left alone.
       AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                        WHERE ab.employee_id     = w.employee_id
                          AND ab.absence_date    = e.entry_date
                          AND ab.approval_status = 'Approved'))
  LOOP
    -- Exactly populate's arithmetic, including the 15-minute rounding that
    -- CHK_OC_TSE_QUARTER (RULE-005) requires.
    v_hours := ROUND(NVL(e.std,0) * NVL(e.pct,100) / 100 * 4) / 4;
    CONTINUE WHEN v_hours <= 0;

    UPDATE oc_ts_entry
       SET hours      = v_hours,
           updated_by = p_actor,
           updated_on = SYSTIMESTAMP
     WHERE ts_entry_id = e.ts_entry_id;
    o_restored := o_restored + 1;

    -- The hours moved after somebody decided the week, which is DailyChange --
    -- the same treatment oc_time_sync_leave gives a retraction. A Pending week
    -- needs no event; nobody has judged it.
    IF e.approval_status <> 'Pending' THEN
      DECLARE
        v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', p_actor, v_s, v_a, v_f);
      EXCEPTION WHEN OTHERS THEN
        -- Never strand a restored day because a transition is missing. The
        -- hours are already back, which is the part the employee sees.
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(o_restored || ' day-row(s) restored to their default hours');
END oc_time_restore_default_hours;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/3] Repair what is already stranded
PROMPT ============================================================

-- Over the whole of every open period, plus the three months behind it: a day
-- stranded in a closed month still shows a person zero hours they worked.
DECLARE
  v_from DATE;
  v_to   DATE;
  v_n    NUMBER;
BEGIN
  SELECT MIN(start_date) - 92, MAX(end_date)
    INTO v_from, v_to
    FROM oc_time_period
   WHERE status = 'Open';

  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('No open period; nothing repaired.');
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Repairing ' || TO_CHAR(v_from,'DD-Mon-YY')
                       || ' .. ' || TO_CHAR(v_to,'DD-Mon-YY'));
  oc_time_restore_default_hours(v_from, v_to, NULL, 'RESTORE_BACKFILL', v_n);
END;
/

PROMPT
PROMPT --- and the same count again; it should now be zero
SELECT COUNT(*) AS stranded_rows
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
 WHERE e.source     = 'Prepopulated'
   AND e.is_leave   = 'N'
   AND e.hours      = 0
   AND e.entry_type IN ('Actual','Default')
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = w.employee_id
                      AND ab.absence_date    = e.entry_date
                      AND ab.approval_status = 'Approved');

PROMPT
PROMPT Anything left is a row whose allocation resolves to zero hours, which is
PROMPT a different problem and is deliberately not touched here.
