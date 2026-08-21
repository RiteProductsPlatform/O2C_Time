--==============================================================
-- time/97_the_put_aside_row_is_not_a_line.sql
-- O2C Timesheet Module — a day put aside for leave shows one line, not two
--
-- Reported from Approval Detail, 21-Aug: on a leave day the task appears twice,
-- once at 0.00 and once as Leave.
--
--   18-Aug TUE  555  Offshore  0.00  Billable       Prepopulated
--   18-Aug TUE  555  Leave     4.00  Non-billable   Absence
--
-- The 0.00 row is real and has to stay in the table: it is where
-- PRE_LEAVE_HOURS keeps the hours the person would have worked, so that
-- withdrawing the leave hands them back verbatim. What it is NOT is a line the
-- manager has anything to do with. There are no hours on it to approve, reject
-- or correct, and it makes a one-entry day read as a two-entry day on the
-- screen the month is signed off from.
--
-- Hidden only where it means that -- a zero-hour WORKED row on a day that
-- carries leave. A zero somebody typed on an ordinary day is still shown,
-- because that is a line they made and may want to change; and the leave row
-- itself is never hidden whatever its hours.
--
-- ── AND THE REASON THE ROW WAS WORTH LOOKING AT ──────────────────────────
--
-- TWO THINGS ZERO THAT ROW AND ONLY ONE REMEMBERS WHAT IT ZEROED.
--
--   oc_time_leave_displace   SET pre_leave_hours = e.hours, hours = 0   remembers
--   populate_month  (db/09)  SET e.hours = 0                            forgets
--
-- They also guard each other out: displace only fires on e.hours > 0, so if
-- populate has already zeroed the row, PRE_LEAVE_HOURS is never set and the
-- hours are simply gone. Withdraw the leave after that and the give-back finds
-- nothing to give -- the day stays at zero and the person has to retype hours
-- that were correct until an absence they did not keep.
--
-- Which of the two runs first is a matter of timing, not design: the live path
-- from PAGE-001 syncs the absence (displace, remembers) and only then calls
-- populate, so it is safe. The monthly population job run before anybody's
-- absence has synced is not. Nothing has been lost yet on this pod -- section
-- [1/4] proves it before the change -- because every absence here arrived
-- through the browser.
--
-- Fixed by making populate remember too, in db/09 where it lives. Same
-- expression, same NULL guard, so whichever runs first records the hours and
-- the second finds nothing to do.
--
-- Idempotent. Depends on: time/04, 09, 80, 94.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TS_ENTRY' AND column_name = 'PRE_LEAVE_HOURS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/80 has not been run: OC_TS_ENTRY.PRE_LEAVE_HOURS is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] Hours already zeroed with nothing remembered
PROMPT ============================================================

-- A worked row sitting at zero on a full-leave day with PRE_LEAVE_HOURS null.
-- Each one is hours that cannot be handed back if the absence is withdrawn.
COLUMN nm FORMAT A24
SELECT w.employee_name AS nm,
       TO_CHAR(e.entry_date,'DD-Mon-YY') AS on_date,
       p.project_number, t.task_code,
       NVL(TO_CHAR(e.pre_leave_hours),'(nothing)') AS remembered
  FROM oc_ts_entry e
  JOIN oc_ts_week  w2 ON w2.ts_week_id = e.ts_week_id
  JOIN oc_time_worker  w ON w.employee_id = w2.employee_id
  JOIN oc_time_project p ON p.project_id  = e.project_id
  JOIN oc_time_task    t ON t.task_id     = e.task_id
 WHERE e.is_leave = 'N'
   AND e.hours    = 0
   AND e.pre_leave_hours IS NULL
   AND EXISTS (SELECT 1 FROM oc_ts_entry l
                WHERE l.ts_week_id = e.ts_week_id
                  AND l.entry_date = e.entry_date
                  AND l.is_leave   = 'Y'
                  AND l.hours      > 0)
 ORDER BY w.employee_name, e.entry_date;

PROMPT
PROMPT No rows means nothing has been lost: every put-aside row still knows what
PROMPT it was holding. Rows here are days whose worked hours cannot be restored
PROMPT if the leave is withdrawn, and the employee will have to retype them.

PROMPT ============================================================
PROMPT [2/4] V_OC_TS_DAY_DETAIL drops the put-aside row
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_day_detail AS
SELECT e.ts_entry_id,
       e.ts_week_id,
       w.employee_id,
       wk.employee_name,
       w.period_id,
       w.week_index,
       TO_CHAR(w.week_start,'YYYY-MM-DD')  AS week_start,
       TO_CHAR(w.week_end,  'YYYY-MM-DD')  AS week_end,
       w.week_status,
       TO_CHAR(e.entry_date,'YYYY-MM-DD')  AS entry_date,
       TO_CHAR(e.entry_date,'DY')          AS day_name,
       e.project_id,
       p.project_name,
       e.task_id,
       t.task_code,
       t.task_name,
       e.hours,
       e.entry_type,
       e.billable_type,
       e.unbilled_reason,
       e.shift_code,
       e.standard_hours,
       e.is_leave,
       e.absence_type,
       e.day_status,
       e.reject_reason,
       e.reject_remarks,
       e.source
  FROM oc_ts_entry     e
  JOIN oc_ts_week      w  ON w.ts_week_id  = e.ts_week_id
  JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
  JOIN oc_time_project p  ON p.project_id  = e.project_id
  JOIN oc_time_task    t  ON t.task_id     = e.task_id
 -- THE PUT-ASIDE ROW IS NOT A LINE. Leave takes the day, so the worked row is
 -- held at zero with its hours in PRE_LEAVE_HOURS, ready to be handed back if
 -- the absence is withdrawn. It has to exist and it has nothing for a manager
 -- to do: no hours to approve, reject or correct. Shown, it made a one-entry
 -- day read as two on the screen the month is signed off from.
 --
 -- NARROW ON PURPOSE. Only a WORKED row, only at exactly zero, and only on a
 -- day that actually carries leave. A zero typed on an ordinary day is a line
 -- somebody made and still appears; the leave row itself is never hidden.
 WHERE NOT (e.is_leave = 'N'
            AND e.hours = 0
            AND EXISTS (SELECT 1 FROM oc_ts_entry l
                         WHERE l.ts_week_id = e.ts_week_id
                           AND l.entry_date = e.entry_date
                           AND l.is_leave   = 'Y'
                           AND l.hours      > 0));

PROMPT ============================================================
PROMPT [3/4] Remember what has already been zeroed
PROMPT ============================================================

-- db/09 stops populate forgetting from now on. This is the backlog: rows it
-- already zeroed, whose hours can be recovered because the allocation still
-- says what the day was worth.
DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_ts_entry e
     SET e.pre_leave_hours =
           (SELECT ROUND(NVL(e.standard_hours,0) * NVL(al.alloc_pct,100) / 100 * 4) / 4
              FROM oc_time_allocation al
              JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
             WHERE al.employee_id = w2.employee_id
               AND al.project_id  = e.project_id
               AND al.status      = 'Active'
               AND e.entry_date BETWEEN al.start_date
                                AND NVL(al.end_date, e.entry_date)
               AND ROWNUM = 1),
         e.updated_by = 'FIX_97'
   WHERE e.is_leave = 'N'
     AND e.hours    = 0
     AND e.pre_leave_hours IS NULL
     AND e.source   = 'Prepopulated'
     AND EXISTS (SELECT 1 FROM oc_ts_entry l
                  WHERE l.ts_week_id = e.ts_week_id
                    AND l.entry_date = e.entry_date
                    AND l.is_leave   = 'Y'
                    AND l.hours      > 0);
  v_n := SQL%ROWCOUNT;

  -- A row whose allocation has since gone gets NULL back rather than a guess.
  UPDATE oc_ts_entry SET pre_leave_hours = NULL
   WHERE pre_leave_hours = 0 AND updated_by = 'FIX_97';

  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' put-aside row(s) now remember their hours.');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

PROMPT
PROMPT One line per leave day. The put-aside row is in the table and not in the
PROMPT view.

COLUMN nm FORMAT A22
SELECT d.employee_name AS nm, d.entry_date, d.day_name,
       d.task_code, d.hours, d.is_leave
  FROM v_oc_ts_day_detail d
 WHERE EXISTS (SELECT 1 FROM v_oc_ts_day_detail l
                WHERE l.ts_week_id = d.ts_week_id
                  AND l.entry_date = d.entry_date
                  AND l.is_leave   = 'Y')
 ORDER BY d.employee_name, d.entry_date, d.is_leave DESC;

PROMPT
PROMPT And what is behind them, straight from the table.

SELECT w.employee_name AS nm,
       TO_CHAR(e.entry_date,'DD-Mon') AS on_date,
       t.task_code, e.hours,
       NVL(TO_CHAR(e.pre_leave_hours),'-') AS held_aside, e.is_leave
  FROM oc_ts_entry e
  JOIN oc_ts_week  w2 ON w2.ts_week_id = e.ts_week_id
  JOIN oc_time_worker w ON w.employee_id = w2.employee_id
  JOIN oc_time_task   t ON t.task_id     = e.task_id
 WHERE EXISTS (SELECT 1 FROM oc_ts_entry l
                WHERE l.ts_week_id = e.ts_week_id
                  AND l.entry_date = e.entry_date
                  AND l.is_leave   = 'Y' AND l.hours > 0)
 ORDER BY w.employee_name, e.entry_date, e.is_leave DESC;

PROMPT
PROMPT HELD_ASIDE on the zero rows is what a withdrawal will hand back. A dash
PROMPT there is a day whose hours are gone; [1/4] listed those before the fix.

PROMPT
PROMPT NEXT: run db/09_pkg_oc_time.sql. populate_month is edited there to
PROMPT remember the hours it zeroes, so the two mechanisms stop disagreeing.
