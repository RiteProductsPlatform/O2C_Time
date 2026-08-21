--==============================================================
-- time/99_recover_the_rows_97_could_not_reach.sql
-- O2C Timesheet Module — a recovery that matched nothing and said "0"
--
-- db/97 [1/4] found two put-aside rows with nothing remembered:
--
--   Sam Joshuva S  07-Aug-26  PCS10034  1          (nothing)
--   Sam Joshuva S  07-Aug-26  444       01.01.111  (nothing)
--
-- and [3/4] then recovered ZERO of them, reporting "0 put-aside row(s) now
-- remember their hours" as though there had been nothing to do. Those are the
-- same two rows, three sections apart, and the script did not notice.
--
-- The recovery was restricted to SOURCE = 'Prepopulated'. run_weekly_defaulting
-- retags a prepopulated row to SOURCE = 'Job' when it fills a week in on the
-- employee's behalf, and Sam's 03-09 Aug week defaulted -- so the filter could
-- not see its own rows. Third time this session that a guard has identified its
-- own work too narrowly and then reported success: populate's ENTRY_TYPE guard,
-- oc_time_cover_billing's, and now this.
--
-- WIDENED TO THE JOB-WRITTEN SOURCES, NOT TO EVERYTHING. 'Prepopulated' and
-- 'Job' are the same row before and after defaulting, and both hold hours the
-- allocation put there, so rebuilding the value from the allocation is exact
-- rather than a guess. 'Employee' and 'Manager' are left alone: a person who
-- typed a zero meant it, and handing them back an allocation-derived number on
-- withdrawal would invent hours somebody had deliberately removed.
--
-- AND IT REPORTS WHAT IT COULD NOT DO. [3/3] lists anything still unremembered
-- with its source, so a recovery that matches nothing says which rows it
-- skipped and why -- which is the part db/97 got wrong.
--
-- db/09 already stops populate forgetting from here on. This is only the
-- backlog it left behind.
--
-- Idempotent. Supersedes db/97 [3/4]. Depends on: time/80, 94, 97.
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
PROMPT [1/3] What is unremembered, and what wrote it
PROMPT ============================================================

-- SOURCE and ENTRY_TYPE are the columns db/97 needed and did not print. Read
-- straight from the table, because V_OC_TS_DAY_DETAIL now hides these rows --
-- correctly for the manager, and inconveniently for anybody diagnosing them.
COLUMN nm   FORMAT A24
COLUMN proj FORMAT A10
COLUMN task FORMAT A12
SELECT w.employee_name AS nm,
       TO_CHAR(e.entry_date,'DD-Mon-YY') AS on_date,
       p.project_number AS proj, t.task_code AS task,
       e.source, e.entry_type,
       ROUND(NVL(e.standard_hours,0) * NVL(
         (SELECT MAX(al.alloc_pct) FROM oc_time_allocation al
           WHERE al.employee_id = w2.employee_id
             AND al.project_id  = e.project_id
             AND al.status      = 'Active'
             AND e.entry_date BETWEEN al.start_date
                              AND NVL(al.end_date, e.entry_date)), 0)
         / 100 * 4) / 4                  AS recoverable
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
 ORDER BY w.employee_name, e.entry_date, p.project_number;

PROMPT
PROMPT RECOVERABLE is what the allocation says the day was worth. A zero there
PROMPT means the allocation has since gone and there is nothing to rebuild from.

PROMPT ============================================================
PROMPT [2/3] Remember what the job zeroed
PROMPT ============================================================

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
         e.updated_by = 'FIX_99'
   WHERE e.is_leave = 'N'
     AND e.hours    = 0
     AND e.pre_leave_hours IS NULL
     -- 'Job' AS WELL AS 'Prepopulated'. db/97 had only the first, and
     -- run_weekly_defaulting renames it to the second the moment a week
     -- defaults -- which is exactly what had happened to the rows it was
     -- written to recover. A person's own zero ('Employee', 'Manager') is
     -- theirs and is not touched.
     AND e.source IN ('Prepopulated','Job')
     AND EXISTS (SELECT 1 FROM oc_ts_entry l
                  WHERE l.ts_week_id = e.ts_week_id
                    AND l.entry_date = e.entry_date
                    AND l.is_leave   = 'Y'
                    AND l.hours      > 0);
  v_n := SQL%ROWCOUNT;

  -- No allocation left to rebuild from: NULL rather than a fabricated zero,
  -- so [3/3] still reports it instead of it looking settled.
  UPDATE oc_ts_entry SET pre_leave_hours = NULL
   WHERE pre_leave_hours = 0 AND updated_by = 'FIX_99';

  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' row(s) matched and now remember.');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [3/3] What is still unremembered, and why
PROMPT ============================================================

COLUMN why FORMAT A46
SELECT w.employee_name AS nm,
       TO_CHAR(e.entry_date,'DD-Mon-YY') AS on_date,
       p.project_number AS proj, e.source,
       CASE
         WHEN e.source NOT IN ('Prepopulated','Job')
           THEN 'a person set this to zero; left as theirs'
         WHEN NOT EXISTS (SELECT 1 FROM oc_time_allocation al
                           WHERE al.employee_id = w2.employee_id
                             AND al.project_id  = e.project_id
                             AND al.status      = 'Active'
                             AND e.entry_date BETWEEN al.start_date
                                              AND NVL(al.end_date, e.entry_date))
           THEN 'no active allocation; nothing to rebuild from'
         ELSE 'unexplained - investigate'
       END AS why
  FROM oc_ts_entry e
  JOIN oc_ts_week  w2 ON w2.ts_week_id = e.ts_week_id
  JOIN oc_time_worker  w ON w.employee_id = w2.employee_id
  JOIN oc_time_project p ON p.project_id  = e.project_id
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
PROMPT No rows is the goal. Anything reading "unexplained" is a row this script
PROMPT should have matched and did not, which is the fault db/97 had.

PROMPT
PROMPT Withdrawing leave on any day still listed here retracts the leave
PROMPT correctly and leaves the day at zero: there is nothing to hand back, and
PROMPT the employee will have to retype those hours.
