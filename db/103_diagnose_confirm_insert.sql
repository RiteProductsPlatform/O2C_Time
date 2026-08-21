--==============================================================
-- time/103_diagnose_confirm_insert.sql
-- O2C Timesheet Module — find where ORA-00979 is actually coming from
--
-- db/102 [3/5] failed:
--
--   ORA-00979: not a GROUP BY expression
--   ORA-06512: at "O2C_TIME.OC_TIME_PKG", line 3018
--
-- Line 3018 of the body maps exactly to confirm_month's interface INSERT --
-- verified twice, because the previous compile error at 3027/24 landed on the
-- MAIN_PROJECT_NUMBER column, character for character. And that statement has
-- no GROUP BY. Nor does anything else in confirm_month; the whole file has none
-- after line 2869. There is no trigger and no materialized view on
-- XX_O2C_TIMESHEET_ACCRUAL_IF.
--
-- So the static reading has run out, and I have guessed at this twice already.
-- This runs the pieces separately so the DATABASE says which one is wrong, with
-- a column pointer rather than a line number swallowed by PL/SQL.
--
-- READ-ONLY. Every statement is a SELECT. Nothing is inserted, and confirm_month
-- is not called.
--
-- Depends on: time/09, 81, 101.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/5] What the objects actually are
PROMPT ============================================================

-- If any of these is a VIEW rather than a TABLE, its own definition is where a
-- GROUP BY could be hiding.
COLUMN nm  FORMAT A34
COLUMN typ FORMAT A14
SELECT object_name AS nm, object_type AS typ, status
  FROM user_objects
 WHERE object_name IN ('XX_O2C_TIMESHEET_ACCRUAL_IF','OC_TS_WEEK','OC_TS_ENTRY',
                       'OC_TIME_PROJECT','OC_TIME_TASK','OC_TIME_WORKER',
                       'OC_TIME_ALLOCATION','OC_MAIN_PROJECT_SRC')
 ORDER BY object_type, object_name;

PROMPT
PROMPT And what the synonym resolves to:

COLUMN table_owner FORMAT A14
COLUMN table_name  FORMAT A26
SELECT synonym_name, table_owner, table_name
  FROM user_synonyms WHERE synonym_name = 'OC_MAIN_PROJECT_SRC';

PROMPT ============================================================
PROMPT [2/5] Anything at all on the interface table
PROMPT ============================================================

SELECT trigger_name, trigger_type, status FROM user_triggers
 WHERE table_name = 'XX_O2C_TIMESHEET_ACCRUAL_IF';

PROMPT (no rows = no trigger, so the INSERT fires nothing)

PROMPT ============================================================
PROMPT [3/5] The scalar subquery I added, on its own
PROMPT ============================================================

SELECT p.project_number,
       p.main_project_id,
       (SELECT m.project_number FROM oc_main_project_src m
         WHERE m.project_id = p.main_project_id) AS main_number
  FROM oc_time_project p
 WHERE p.project_number IN ('444','555','PCS10034');

PROMPT
PROMPT If that raised, the fault is mine and it is in that subquery.

PROMPT ============================================================
PROMPT [4/5] The whole SELECT confirm_month runs, verbatim
PROMPT ============================================================

-- Bind values replaced by literals for JUL-2026 / 555 so it can run standalone.
-- Everything else is character-for-character what the package executes, so the
-- error lands with a column pointer instead of a PL/SQL line number.
SELECT COUNT(*) AS rows_it_would_insert
  FROM (
    SELECT 'JUL-2026', 2026, 7, 0,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           p.main_project_id,
           (SELECT m.project_number FROM oc_main_project_src m
             WHERE m.project_id = p.main_project_id),
           (SELECT MAX(al.client_role) FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id
               AND al.project_id  = e.project_id),
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           CASE
             WHEN e.entry_type = 'Reversal'    THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'  THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y' THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y' THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y' THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y' THEN 'Late submission'
             ELSE NULL
           END,
           NVL(TRUNC(CAST(w.approved_on AS DATE)), TRUNC(SYSDATE)),
           e.ts_entry_id, e.adjustment_id, 'DIAG', NULL
      FROM oc_ts_week      w
      JOIN oc_ts_entry     e  ON e.ts_week_id  = w.ts_week_id
      JOIN oc_time_project p  ON p.project_id  = e.project_id
      JOIN oc_time_task    t  ON t.task_id     = e.task_id
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
     WHERE w.period_id  = (SELECT period_id FROM oc_time_period
                            WHERE period_name = 'JUL-2026')
       AND e.project_id = (SELECT project_id FROM oc_time_project
                            WHERE project_number = '555')
       AND e.hours     <> 0
       AND (e.day_status = 'Approved'
            OR ('Advance closure' = 'Advance closure'
                AND e.day_status = 'Pending'))
  );

PROMPT
PROMPT A number here means the SELECT is fine and the fault is elsewhere in
PROMPT confirm_month. An ORA-00979 here names the guilty column.

PROMPT ============================================================
PROMPT [5/5] Is there anything to insert at all
PROMPT ============================================================

-- Separately from the error: July's days must be Pending for advance closure to
-- pick them up. If they are something else, the payload fix targets the wrong
-- value and the batch would be empty even once the error is gone.
SELECT e.day_status, e.entry_type, COUNT(*) AS entries, SUM(e.hours) AS hours
  FROM oc_ts_week  w
  JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
 WHERE w.period_id  = (SELECT period_id FROM oc_time_period WHERE period_name = 'JUL-2026')
   AND e.project_id = (SELECT project_id FROM oc_time_project WHERE project_number = '555')
   AND e.hours     <> 0
 GROUP BY e.day_status, e.entry_type
 ORDER BY 1, 2;

PROMPT
PROMPT Advance closure accepts day_status = 'Pending'. Anything else listed here
PROMPT will not post.
