--==============================================================
-- query_daywise_timesheet.sql
-- The My Timesheet screen, day by day, with status and flags
--
-- Not an installer -- nothing here changes anything. Kept in db/ because it is
-- the query people reach for when a screen and the data appear to disagree,
-- and it is worth it reading the same sources the screen does rather than an
-- approximation of them.
--
-- -- WHICH SOURCE FOR WHAT ---------------------------------------
--
--   V_OC_TS_DAY_DETAIL   the day grid. Already excludes the put-aside
--                        zero-hour row a full day of leave leaves behind
--                        (db/97), which is why a one-entry day does not read
--                        as two here.
--   OC_TS_WEEK           the two axes. The view carries only WEEK_STATUS,
--                        which is the derived revision-2 column -- the truth
--                        is SUBMISSION_STATUS x APPROVAL_STATUS.
--   V_OC_TS_DAY_FLAGS    live day flags, cleared ones excluded (db/122).
--   OC_TS_WEEK_FLAG      live week flags. ShortOfStandard lives HERE and
--                        never on a day (db/124).
--
-- -- THE DAY AND THE WEEK CAN DISAGREE, AND THAT IS THE DESIGN ---
--
-- A week stays Pending until NO day is left undecided (sync_week_from_days),
-- so three Approved days under a Pending week is correct rather than a bug in
-- either. Once every day is decided, a single Rejected day makes the week
-- Rejected.
--
-- And REJECTED_ON_WEEK below can be Y while DAY_STATUS still reads Pending:
-- rejecting a week records its dates against the WEEK, and DAY_STATUS only
-- moves when a manager acts on that day itself. The screen tints the day from
-- the week's rejected dates for exactly this reason.
--==============================================================
-- SET DEFINE **ON**, unlike every installer in db/. Those turn it off so an
-- ampersand inside a string is not read as a substitution variable; this file
-- wants exactly that behaviour, because &emp and &period below are how it is
-- pointed at somebody. Copying the house rule here would have left the query
-- asking the literal string '&emp'.
SET DEFINE ON
SET LINESIZE 250
SET PAGESIZE 200

-- Change these two. UNQUOTED here, quoted at every use site below.
--
-- Whether DEFINE strips surrounding quotes varies between SQL*Plus, SQLcl and
-- SQL Developer, so "DEFINE emp = 'RI2249'" plus "= '&emp'" can expand to
-- = ''RI2249'' on some of them and match nothing -- with no error, just an
-- empty result, which reads as "this person has no timesheet".
--
-- Unquoted value, quoted usage, is the form that means the same thing
-- everywhere.
--
--   emp     OC_TIME_WORKER.EMPLOYEE_ID   RI2249, RI2894, RI2824, RI9001 ...
--   period  OC_TIME_PERIOD.PERIOD_NAME   JUN-2026, JUL-2026, AUG-2026
--                                        (upper case, exactly as stored)
DEFINE emp    = RI2249
DEFINE period = AUG-2026

COLUMN nm         FORMAT A22
COLUMN wk         FORMAT A17
COLUMN dy         FORMAT A10
COLUMN proj       FORMAT A26
COLUMN task       FORMAT A18
COLUMN day_status FORMAT A10
COLUMN day_flags  FORMAT A24
COLUMN wk_flags   FORMAT A34
COLUMN rej        FORMAT A3

SELECT d.employee_id,
       d.employee_name                                   AS nm,
       'W' || w.week_index || ' '
         || TO_CHAR(w.week_start,'DD-Mon') || '-'
         || TO_CHAR(w.week_end,'DD-Mon')                 AS wk,
       d.entry_date,
       d.day_name                                        AS dy,
       d.project_name                                    AS proj,
       d.task_name                                       AS task,
       d.hours,
       d.standard_hours                                  AS std,
       d.entry_type,
       d.billable_type,
       d.is_leave,
       d.source,

       -- -- the two axes, week level --
       w.submission_status,
       w.approval_status                                 AS week_approval,

       -- -- the day's own verdict --
       NVL(d.day_status,'Pending')                       AS day_status,

       -- Was this DATE named in a week-level rejection? Independent of
       -- DAY_STATUS, and the thing the employee actually has to act on.
       CASE WHEN EXISTS (SELECT 1 FROM oc_ts_entry e2
                          WHERE e2.ts_week_id = d.ts_week_id
                            AND e2.entry_date = TO_DATE(d.entry_date,'YYYY-MM-DD')
                            AND e2.reject_reason IS NOT NULL)
            THEN 'Y' ELSE 'N' END                        AS rej,
       d.reject_reason,
       d.reject_remarks,

       -- -- flags --
       d.flag_codes                                      AS day_flags,
       (SELECT LISTAGG(f.flag_code, ',') WITHIN GROUP (ORDER BY f.flag_code)
          FROM oc_ts_week_flag f
         WHERE f.ts_week_id = d.ts_week_id
           AND f.cleared_on IS NULL)                     AS wk_flags

  FROM v_oc_ts_day_detail d
  JOIN oc_ts_week         w ON w.ts_week_id = d.ts_week_id
  JOIN oc_time_period     p ON p.period_id  = w.period_id
 WHERE d.employee_id  = '&emp'
   AND p.period_name  = '&period'
 ORDER BY w.week_index, d.entry_date, d.project_name, d.task_code;

PROMPT
PROMPT REJ = Y with DAY_STATUS Pending is not a contradiction: the rejection is
PROMPT recorded against the WEEK with its dates, and DAY_STATUS only moves when
PROMPT a manager decides that day. The screen tints from REJ, not DAY_STATUS.

PROMPT
PROMPT ============================================================
PROMPT The week header the screen shows above the grid
PROMPT ============================================================

COLUMN nm       FORMAT A22
COLUMN wk       FORMAT A17
COLUMN flags    FORMAT A44
COLUMN rejected FORMAT A30
SELECT w.week_index,
       TO_CHAR(w.week_start,'DD-Mon') || ' - '
         || TO_CHAR(w.week_end,'DD-Mon')                 AS wk,
       w.submission_status,
       w.approval_status,
       w.week_status,
       w.defaulted_by,
       w.locked_flag,
       (SELECT LISTAGG(f.flag_code, ', ') WITHIN GROUP (ORDER BY f.sort_order)
          FROM oc_ts_week_flag f
          JOIN oc_ts_flag_def  fd ON fd.flag_code = f.flag_code
         WHERE f.ts_week_id = w.ts_week_id
           AND f.cleared_on IS NULL)                     AS flags,
       -- The dates the banner lists. Held per ENTRY, so DISTINCT.
       (SELECT LISTAGG(DISTINCT TO_CHAR(e.entry_date,'DD-Mon'), ', ')
                 WITHIN GROUP (ORDER BY TO_CHAR(e.entry_date,'DD-Mon'))
          FROM oc_ts_entry e
         WHERE e.ts_week_id = w.ts_week_id
           AND e.reject_reason IS NOT NULL)              AS rejected
  FROM oc_ts_week     w
  JOIN oc_time_period p ON p.period_id = w.period_id
 WHERE w.employee_id = '&emp'
   AND p.period_name = '&period'
 ORDER BY w.week_index;

PROMPT
PROMPT ============================================================
PROMPT Who decided what, and when -- the Approval workflow panel
PROMPT ============================================================

-- OC_TS_APPROVAL is append-only (db/19). GRANULARITY plus ENTRY_DATE is what
-- separates a day decision from a week one; a week action carries a null date.
COLUMN action FORMAT A16
COLUMN gran   FORMAT A6
COLUMN who    FORMAT A14
COLUMN reason FORMAT A22
SELECT TO_CHAR(a.action_on,'DD-Mon HH24:MI') AS at_,
       a.granularity                          AS gran,
       NVL(TO_CHAR(a.entry_date,'DD-Mon'),'(week)') AS on_,
       a.action,
       a.actor_emp_id                         AS who,
       a.reject_reason                        AS reason,
       a.remarks
  FROM oc_ts_approval a
  JOIN oc_ts_week     w ON w.ts_week_id = a.ts_week_id
  JOIN oc_time_period p ON p.period_id  = w.period_id
 WHERE w.employee_id = '&emp'
   AND p.period_name = '&period'
 ORDER BY a.action_on DESC
 FETCH FIRST 30 ROWS ONLY;

PROMPT
PROMPT ============================================================
PROMPT Hours changed, and by whom -- the Change history panel
PROMPT ============================================================

COLUMN chg    FORMAT A18
COLUMN reason FORMAT A34
SELECT TO_CHAR(au.changed_on,'DD-Mon HH24:MI') AS at_,
       TO_CHAR(au.entry_date,'DD-Mon')         AS on_,
       au.change_type                          AS chg,
       au.old_hours, au.new_hours,
       au.change_reason                        AS reason,
       au.changed_by
  FROM oc_ts_audit    au
  JOIN oc_ts_week     w ON w.ts_week_id = au.ts_week_id
  JOIN oc_time_period p ON p.period_id  = w.period_id
 WHERE w.employee_id = '&emp'
   AND p.period_name = '&period'
 ORDER BY au.changed_on DESC
 FETCH FIRST 30 ROWS ONLY;

UNDEFINE emp
UNDEFINE period
