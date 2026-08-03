--==============================================================
-- time/08_views.sql
-- O2C Timesheet Module — Remaining page projections
--
-- The page-specific views that were not created alongside their tables.
-- Every view is read-only and dated in 'YYYY-MM-DD' so ORDS emits ISO strings
-- and VBCS needs no date coercion.
--
--   V_OC_TS_MGR_PROJECTS   PAGE-003 manager landing (projects managed)
--   V_OC_TS_WEEK_DETAIL    PAGE-005 weekly approval grid
--   V_OC_TS_LLC            PAGE-006 absentee lines with cover
--   V_OC_TIME_CALENDAR_UI  PAGE-009 the four layer cards
--   V_OC_TIME_INTEGRATION  PAGE-012 integration reference (static catalogue)
--   V_OC_TS_MY_PERIODS     PAGE-001 month LOV with editability
--   V_OC_TS_ALLOCATION     PAGE-001 allocation pop-up (ACT-008)
--   V_OC_TS_TASK_LOV       PAGE-001 task LOV (RULE-010)
--   V_OC_TS_AUDIT_TRAIL    REP-007 change history
--
-- Requirement refs: PAGE-001, PAGE-003, PAGE-005, PAGE-006, PAGE-009, PAGE-012,
--                   FLD-001..FLD-007, FLD-026..FLD-036, FLD-048..FLD-050,
--                   FLD-060..FLD-065, FLD-093..FLD-096, FLD-110..FLD-113,
--                   RULE-001, RULE-004, RULE-007, RULE-010, RULE-015, REP-007
-- Idempotent. Depends on: time/01 .. time/07
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/9] V_OC_TS_MGR_PROJECTS — manager landing (PAGE-003)
PROMPT ============================================================

-- FLD-029..FLD-036. One row per project the manager owns per period, with the
-- rolled-up month status (all employees) and the counts the landing page needs
-- to decide whether Confirm Month is even offered (RULE-020).
CREATE OR REPLACE VIEW v_oc_ts_mgr_projects AS
SELECT p.project_id,
       p.project_number,                                    -- FLD-031
       p.project_name,                                      -- FLD-030
       p.customer_name,
       p.revenue_model,
       p.leave_loss_flag,
       p.project_type,
       p.project_manager_id,
       pe.period_id,
       pe.period_name,                                      -- FLD-029
       pe.period_year,
       pe.period_month,
       pe.status AS period_status,
       TO_CHAR(pe.start_date,'YYYY-MM-DD') AS ts_start,     -- FLD-032
       TO_CHAR(pe.end_date,  'YYYY-MM-DD') AS ts_end,       -- FLD-033
       s.employees,
       s.approved_employees,
       s.rejected_employees,
       s.pending_employees,
       -- FLD-034: all approved => Approved, any rejected => Rejected, else Pending
       CASE WHEN NVL(s.employees,0) = 0                   THEN 'No employees'
            WHEN NVL(s.rejected_employees,0) > 0          THEN 'Rejected'
            WHEN s.employees = NVL(s.approved_employees,0) THEN 'Approved'
            ELSE 'Pending' END              AS month_status,
       s.approved_on,                                       -- FLD-035
       s.billable_hours,
       s.non_billable_hours,
       s.leave_hours,
       -- Confirm Month is offered only when every employee is Approved and the
       -- month has not already been confirmed (RULE-020 / ACT-020).
       CASE WHEN NVL(s.employees,0) > 0
             AND s.employees = NVL(s.approved_employees,0)
             AND c.confirm_id IS NULL THEN 'Y' ELSE 'N' END AS confirm_allowed,
       c.confirm_id,
       c.confirm_type,
       TO_CHAR(c.confirmed_on,'YYYY-MM-DD HH24:MI') AS confirmed_on,
       c.accrual_status,
       -- Pending retro adjustments on this project (the adjustments panel).
       (SELECT COUNT(*) FROM oc_ts_adjustment a
         WHERE a.status = 'Awaiting Approval'
           AND (a.old_project_id = p.project_id OR a.new_project_id = p.project_id)
       ) AS pending_adjustments
  FROM oc_time_project p
 CROSS JOIN oc_time_period pe
  LEFT JOIN (SELECT project_id, period_id,
                    COUNT(*)                                                  AS employees,
                    SUM(CASE WHEN month_status = 'Approved' THEN 1 ELSE 0 END) AS approved_employees,
                    SUM(CASE WHEN month_status = 'Rejected' THEN 1 ELSE 0 END) AS rejected_employees,
                    SUM(CASE WHEN month_status = 'Pending'  THEN 1 ELSE 0 END) AS pending_employees,
                    SUM(billable_hours)     AS billable_hours,
                    SUM(non_billable_hours) AS non_billable_hours,
                    SUM(leave_hours)        AS leave_hours,
                    MAX(approved_on)        AS approved_on
               FROM v_oc_ts_month_summary
              GROUP BY project_id, period_id) s
         ON s.project_id = p.project_id AND s.period_id = pe.period_id
  LEFT JOIN oc_ts_month_confirm c
         ON c.project_id = p.project_id AND c.period_id = pe.period_id
 WHERE p.status = 'Active';

PROMPT ============================================================
PROMPT [2/9] V_OC_TS_WEEK_DETAIL — weekly approval grid (PAGE-005)
PROMPT ============================================================

-- FLD-048..FLD-050 plus the workflow card. One row per week per employee, with
-- the day-level pending count so the weekly/daily toggle can show progress.
CREATE OR REPLACE VIEW v_oc_ts_week_detail AS
SELECT w.ts_week_id,
       w.employee_id,
       wk.employee_name,
       wk.worker_type,
       wk.manager_emp_id,
       w.period_id,
       w.period_year,
       w.period_month,
       w.week_index,                                        -- FLD-049
       TO_CHAR(w.week_start,'YYYY-MM-DD') AS week_start,
       TO_CHAR(w.week_end,  'YYYY-MM-DD') AS week_end,
       TO_CHAR(w.week_start,'DD-Mon') || ' to ' ||
       TO_CHAR(w.week_end,  'DD-Mon') AS week_range,        -- FLD-050
       w.week_status,
       w.billable_hours,
       w.non_billable_hours,
       w.leave_hours,
       w.billing_loss_hours,
       w.total_hours,
       w.standard_hours,
       w.defaulted_flag,
       -- EMPLOYEE or MANAGER. Projected because the screens need to explain a
       -- Defaulted badge rather than just show it: only an EMPLOYEE default
       -- locks the week and holds pay (RULE-016), and a manager looking at
       -- their own lateness should not be told the employee failed to submit.
       w.defaulted_by,
       w.late_submission_flag,
       w.advance_closure_flag,
       w.overridden_flag,
       w.has_reversal_flag,
       w.has_adjustment_flag,
       w.locked_flag,
       w.reject_reason,
       w.reject_remarks,
       w.submitted_by,
       TO_CHAR(w.submitted_on,'YYYY-MM-DD HH24:MI') AS submitted_on,
       w.approved_by,
       TO_CHAR(w.approved_on, 'YYYY-MM-DD HH24:MI') AS approved_on,
       (SELECT COUNT(DISTINCT e.entry_date) FROM oc_ts_entry e
         WHERE e.ts_week_id = w.ts_week_id) AS days_total,
       (SELECT COUNT(DISTINCT e.entry_date) FROM oc_ts_entry e
         WHERE e.ts_week_id = w.ts_week_id AND e.day_status = 'Pending')  AS days_pending,
       (SELECT COUNT(DISTINCT e.entry_date) FROM oc_ts_entry e
         WHERE e.ts_week_id = w.ts_week_id AND e.day_status = 'Approved') AS days_approved,
       (SELECT COUNT(DISTINCT e.entry_date) FROM oc_ts_entry e
         WHERE e.ts_week_id = w.ts_week_id AND e.day_status = 'Rejected') AS days_rejected,
       -- Projects touched in the week, so the manager can be filtered to the
       -- ones they own without a second round-trip.
       (SELECT LISTAGG(DISTINCT p2.project_number, ', ')
                 WITHIN GROUP (ORDER BY p2.project_number)
          FROM oc_ts_entry e2
          JOIN oc_time_project p2 ON p2.project_id = e2.project_id
         WHERE e2.ts_week_id = w.ts_week_id) AS projects
  FROM oc_ts_week     w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id;

PROMPT ============================================================
PROMPT [3/9] V_OC_TS_LLC — absentee lines with cover (PAGE-006)
PROMPT ============================================================

-- FLD-060..FLD-065. Restricted to FCP projects with Leave Loss = Yes
-- (PROC-006 entry condition) and excluding LOP / maternity absences (RULE-014).
CREATE OR REPLACE VIEW v_oc_ts_llc AS
SELECT l.llc_id,
       l.project_id,
       p.project_number,
       p.project_name,
       p.revenue_model,
       p.leave_loss_flag,
       p.project_manager_id,
       l.period_id,
       pe.period_name,
       l.absent_employee_id,                                -- FLD-060
       aw.employee_name AS absent_employee_name,            -- FLD-061
       TO_CHAR(l.absence_date,'YYYY-MM-DD') AS absence_date, -- FLD-062
       TO_CHAR(l.absence_date,'DY')         AS absence_day,
       l.absence_type,
       l.absence_hours,                                     -- FLD-063
       l.cover_employee_id,                                 -- FLD-064
       cw.employee_name AS cover_employee_name,
       l.llc_status,                                        -- FLD-065
       l.billed_flag,
       l.assigned_by,
       TO_CHAR(l.assigned_on,'YYYY-MM-DD HH24:MI') AS assigned_on,
       l.approved_by,
       TO_CHAR(l.approved_on,'YYYY-MM-DD HH24:MI') AS approved_on,
       l.remarks
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_project p  ON p.project_id   = l.project_id
                         AND p.revenue_model   = 'FCP'
                         AND p.leave_loss_flag = 'Y'
  JOIN oc_time_period  pe ON pe.period_id    = l.period_id
  JOIN oc_time_worker  aw ON aw.employee_id  = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id;

PROMPT ============================================================
PROMPT [4/9] V_OC_TIME_CALENDAR_UI — layer cards (PAGE-009)
PROMPT ============================================================

-- FLD-093..FLD-096. One row per layer with its sync state, plus the precedence
-- note the page renders (Shift > Client > Project > Corporate).
CREATE OR REPLACE VIEW v_oc_time_calendar_ui AS
SELECT layer,
       CASE layer
         WHEN 'CORPORATE' THEN 'Corporate + standard hours'
         WHEN 'CLIENT'    THEN 'Client Holiday'
         WHEN 'PROJECT'   THEN 'Project Standard Hours'
         WHEN 'SHIFT'     THEN 'Shift'
       END AS layer_label,
       CASE layer
         WHEN 'CORPORATE' THEN 'HCM / Corporate — country work days & holidays (optional city holidays)'
         WHEN 'CLIENT'    THEN 'CRM / Client — client site closures'
         WHEN 'PROJECT'   THEN 'Fusion PPM — project standard hours, country-wise'
         WHEN 'SHIFT'     THEN 'HCM Work Schedules — one shift per employee per day'
       END AS source_description,
       MAX(precedence)              AS precedence,
       COUNT(*)                     AS day_count,
       COUNT(DISTINCT scope_key)    AS scope_count,
       MIN(TO_CHAR(cal_date,'YYYY-MM-DD')) AS from_date,
       MAX(TO_CHAR(cal_date,'YYYY-MM-DD')) AS to_date,
       MAX(source_system)           AS source_system,
       TO_CHAR(MAX(synced_on),'YYYY-MM-DD HH24:MI') AS last_synced_on,
       SUM(CASE WHEN is_working_day = 'N' THEN 1 ELSE 0 END) AS non_working_days
  FROM oc_time_calendar
 GROUP BY layer;

PROMPT ============================================================
PROMPT [5/9] V_OC_TIME_INTEGRATION — integration reference (PAGE-012)
PROMPT ============================================================

-- FLD-110..FLD-113. PAGE-012 is a text reference (ACT-034, wired at the
-- integration phase), so the catalogue lives in OC_TIME_LOOKUP under
-- 'INTEGRATION' and is projected here. Keeping it as data rather than markup
-- means the page needs no redeploy when an endpoint changes.
CREATE OR REPLACE VIEW v_oc_time_integration AS
SELECT SUBSTR(lookup_code, 1, INSTR(lookup_code,'|') - 1)           AS integration_id,
       REGEXP_SUBSTR(meaning, '^[^|]*')                             AS fusion_source,   -- FLD-110
       REGEXP_SUBSTR(meaning, '[^|]*', 1, 2)                        AS object_usage,    -- FLD-111
       REGEXP_SUBSTR(meaning, '[^|]*', 1, 3)                        AS rest_resource,   -- FLD-112
       REGEXP_SUBSTR(meaning, '[^|]*', 1, 4)                        AS load_pattern,    -- FLD-113
       SUBSTR(lookup_code, INSTR(lookup_code,'|') + 1)              AS area,
       usage_note                                                   AS notes,
       sort_order
  FROM oc_time_lookup
 WHERE lookup_type = 'INTEGRATION'
   AND active_flag = 'Y';

PROMPT ============================================================
PROMPT [6/9] V_OC_TS_MY_PERIODS — month LOV with editability (PAGE-001)
PROMPT ============================================================

-- FLD-001 / FLD-002 / RULE-004 / RULE-007. Tells the employee page, per period,
-- whether it may be edited at all:
--   Open   before payroll cut-off  -> editable
--   Closed after                   -> read-only, retro adjustment card instead
--   Future                         -> visible but frozen (SC-02)
CREATE OR REPLACE VIEW v_oc_ts_my_periods AS
SELECT p.period_id,
       p.period_name,
       p.period_year,
       p.period_month,
       p.status,
       p.payroll_country,
       TO_CHAR(p.start_date,'YYYY-MM-DD') AS start_date,
       TO_CHAR(p.end_date,  'YYYY-MM-DD') AS end_date,
       p.ts_cutoff_day,
       p.ts_cutoff_time,
       TO_CHAR(p.delivery_cutoff,'YYYY-MM-DD') AS delivery_cutoff,
       TO_CHAR(p.payroll_cutoff, 'YYYY-MM-DD') AS payroll_cutoff,
       p.advance_close,
       p.adjustment_months,
       CASE
         WHEN p.start_date > TRUNC(SYSDATE)              THEN 'Future'
         WHEN p.status = 'Open'                          THEN 'Open'
         ELSE 'Closed'
       END AS period_state,
       -- RULE-004: a future period is never fillable. RULE-007: an open period
       -- stays editable until the delivery cut-off.
       CASE
         WHEN p.start_date > TRUNC(SYSDATE)              THEN 'N'
         WHEN p.status <> 'Open'                         THEN 'N'
         WHEN p.delivery_cutoff IS NOT NULL
          AND TRUNC(SYSDATE) > p.delivery_cutoff         THEN 'N'
         ELSE 'Y'
       END AS editable_flag,
       -- Retro adjustments are offered on a closed month inside the window.
       CASE
         WHEN p.status = 'Open' THEN 'N'
         WHEN p.end_date >= ADD_MONTHS(TRUNC(SYSDATE,'MM'), -p.adjustment_months)
           THEN 'Y' ELSE 'N'
       END AS adjustment_allowed
  FROM oc_time_period p;

PROMPT ============================================================
PROMPT [7/9] V_OC_TS_ALLOCATION — allocation pop-up (PAGE-001 / ACT-008)
PROMPT ============================================================

-- FLD-005. The pop-up shows project / client / allocation % / approving
-- manager. TOTAL_ALLOC_PCT lets the page raise the RULE-001 warning ("must
-- total 100%") client-side without a second call.
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
       SUM(al.alloc_pct) OVER (PARTITION BY al.employee_id) AS total_alloc_pct
  FROM oc_time_allocation al
  JOIN oc_time_worker  w  ON w.employee_id  = al.employee_id
  JOIN oc_time_project p  ON p.project_id   = al.project_id
  LEFT JOIN oc_time_worker mw ON mw.employee_id = al.approving_manager_id
 WHERE al.status = 'Active';

PROMPT ============================================================
PROMPT [8/9] V_OC_TS_TASK_LOV — task LOV (PAGE-001 / RULE-010)
PROMPT ============================================================

-- FLD-007 / RULE-010. For a given project the LOV is: that project's WBS tasks
-- UNION the common non-billable tasks, which appear in EVERY project and in the
-- Organization (Non-Billable) project. Leave and Billing Loss are excluded by
-- SELECTABLE_FLAG so the employee can never pick them (RULE-008 / RULE-009).
--
-- TIME_ENTRY_ENABLED is the other gate, and it is the one that keeps this list
-- usable at all (CrewRite CR-B-BR08 / Reuse Assessment 2.4). Status alone is
-- every active project in the enterprise: 424 on the reference pod against the
-- 46 anyone actually tracks time against. The Organization project is exempt —
-- PRJ-ORG is created locally, not synced, so nothing would ever set its flag,
-- and FLD-006 requires it to appear for every employee.
CREATE OR REPLACE VIEW v_oc_ts_task_lov AS
-- Project-specific WBS tasks
SELECT t.task_id,
       t.project_id,
       p.project_number,
       p.project_name,
       t.task_code,
       t.task_name,
       t.task_type,
       t.billable_type,
       t.unbilled_reason,
       'WBS' AS task_group,
       t.sort_order
  FROM oc_time_task    t
  JOIN oc_time_project p ON p.project_id = t.project_id
 WHERE t.task_type       = 'WBS'
   AND t.status          = 'Active'
   AND t.selectable_flag = 'Y'
   AND t.chargeable_flag = 'Y'
   AND (p.time_entry_enabled = 'Y' OR p.project_type = 'Organization')
UNION ALL
-- Common non-billable tasks, replicated across every active project
SELECT t.task_id,
       p.project_id,
       p.project_number,
       p.project_name,
       t.task_code,
       t.task_name,
       t.task_type,
       t.billable_type,
       t.unbilled_reason,
       'Common (non-billable)' AS task_group,
       900 + t.sort_order      AS sort_order
  FROM oc_time_task t
 CROSS JOIN oc_time_project p
 WHERE t.task_type       = 'COMMON'
   AND t.status          = 'Active'
   AND t.selectable_flag = 'Y'
   AND p.status          = 'Active'
   AND (p.time_entry_enabled = 'Y' OR p.project_type = 'Organization');

PROMPT ============================================================
PROMPT [9/9] V_OC_TS_AUDIT_TRAIL — change history (REP-007)
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_audit_trail AS
SELECT a.audit_id,
       a.employee_id,
       w.employee_name,
       TO_CHAR(a.entry_date,'YYYY-MM-DD') AS entry_date,
       a.change_type,
       op.project_name AS old_project_name,
       ot.task_code    AS old_task_code,
       a.old_hours,
       a.old_bill_type,
       a.old_reason,
       np.project_name AS new_project_name,
       nt.task_code    AS new_task_code,
       a.new_hours,
       a.new_bill_type,
       a.new_reason,
       (NVL(a.new_hours,0) - NVL(a.old_hours,0)) AS delta_hours,
       a.change_reason,
       a.changed_by,
       TO_CHAR(a.changed_on,'YYYY-MM-DD HH24:MI:SS') AS changed_on,
       a.trace_id
  FROM oc_ts_audit    a
  JOIN oc_time_worker w  ON w.employee_id = a.employee_id
  LEFT JOIN oc_time_project op ON op.project_id = a.old_project_id
  LEFT JOIN oc_time_project np ON np.project_id = a.new_project_id
  LEFT JOIN oc_time_task    ot ON ot.task_id    = a.old_task_id
  LEFT JOIN oc_time_task    nt ON nt.task_id    = a.new_task_id;

PROMPT
PROMPT ============================================================
PROMPT time/08_views complete.
PROMPT ============================================================
