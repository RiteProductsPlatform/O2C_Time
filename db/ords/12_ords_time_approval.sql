--==============================================================
-- time/ords/12_ords_time_approval.sql
-- O2C Timesheet Module — ORDS module oc.time.approval  (MANAGER surface)
--
-- Base path: /oc/time/approval/
-- Persona:   PER-003 Manager / Delivery Manager
--
-- Every write here passes an ACTOR_EMP_ID so OC_TIME_PKG can enforce RULE-015
-- (a manager never approves their own timesheet). The handlers do not decide
-- authorisation themselves — the package does, so the rule cannot be bypassed
-- by calling a different endpoint.
--
-- Endpoints
--   GET  managers/:employeeId                    manager switcher (ACT-011)
--   GET  projects/:managerId/:periodId           landing: projects managed
--   GET  summary/:projectId/:periodId            monthly summary per employee
--   GET  weeks/:projectId/:periodId/:employeeId  weekly detail rows
--   GET  days/:tsWeekId                          daily line-wise detail
--   POST approve/month                           approve selected employees
--   POST reject/month                            reject selected employees
--   POST approve/week/:id                        approve one week
--   POST reject/week/:id                         reject one week / dates
--   POST approve/day/:id                         approve one date
--   POST reject/day/:id                          reject one date
--   POST override/:tsEntryId                     override an hour cell
--   POST override/:tsWeekId/finish               close the overridden week
--   POST approve/allweeks                        approve every pending week
--   POST advanceapprove                          advance-approve a future month
--   POST confirm                                 confirm month -> accrual
--   GET  adjustments/:managerId                  retro adjustments to approve
--   POST adjustments/:id/approve                 approve a retro adjustment
--   GET  llc/:projectId/:periodId                leave-loss absentee lines
--   POST llc/generate                            build the absentee list
--   GET  llc/cover/:projectId/:absenceDate       eligible cover LOV
--   POST llc/:id/assign                          assign a cover
--   POST llc/:id/approve                         approve the coverage
--   GET  salaryhold/:periodId                    defaulted employees
--   POST salaryhold/run/:periodId                run the salary-stopping job
--   POST salaryhold/:id/release                  release a hold
--   GET  audit/:tsWeekId                         change history for a week
--
-- Depends on: time/01 .. time/10
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

BEGIN ORDS.DELETE_MODULE(p_module_name => 'oc.time.approval'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time.approval',
    p_base_path      => '/oc/time/approval/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'O2C Timesheet - manager surface (approve, reject, override, LLC, salary hold, confirm).');
  COMMIT;
END;
/

-- ── GET managers/:employeeId  (ACT-011 switcher) ─────────────
-- A split employee reports into more than one manager, so the manager may need
-- to switch identity to review each team.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'managers/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'managers/:employeeId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT DISTINCT m.employee_id, m.employee_name, m.email
        FROM oc_time_worker m
       WHERE m.app_role IN ('ROLE_TIME_MANAGER','ROLE_TIME_ADMIN')
         AND m.status = 'Active'
         AND ( m.employee_id = :employeeId
            OR EXISTS (SELECT 1 FROM oc_time_project p
                        WHERE p.project_manager_id = m.employee_id) )
       ORDER BY m.employee_name
    ]');
  COMMIT;
END;
/

-- ── GET projects/:managerId/:periodId  (PAGE-003 landing) ────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'projects/:managerId/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'projects/:managerId/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT project_id, project_number, project_name, customer_name,
             revenue_model, leave_loss_flag, project_type,
             period_id, period_name, period_status, ts_start, ts_end,
             employees, approved_employees, rejected_employees, pending_employees,
             month_status, approved_on,
             billable_hours, non_billable_hours, leave_hours,
             confirm_allowed, confirm_id, confirm_type, confirmed_on,
             accrual_status, pending_adjustments
        FROM v_oc_ts_mgr_projects
       WHERE project_manager_id = :managerId
         AND period_id          = :periodId
       ORDER BY project_name
    ]');
  COMMIT;
END;
/

-- ── GET summary/:projectId/:periodId  (PAGE-004) ─────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'summary/:projectId/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'summary/:projectId/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT employee_id, employee_name, worker_type,
             billing_status, client_role, cap_type, cap_hours,
             billable_hours, non_billable_hours, leave_hours, total_hours,
             week_count, approved_weeks, rejected_weeks,
             month_status, approved_on,
             overridden_flag, advance_closure_flag,
             project_id, period_id
        FROM v_oc_ts_month_summary
       WHERE project_id = :projectId
         AND period_id  = :periodId
       ORDER BY employee_name
    ]');
  COMMIT;
END;
/

-- ── GET weeks/:projectId/:periodId/:employeeId  (PAGE-005) ───
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'weeks/:projectId/:periodId/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval',
    p_pattern => 'weeks/:projectId/:periodId/:employeeId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT d.ts_week_id, d.employee_id, d.employee_name, d.worker_type,
             d.week_index, d.week_start, d.week_end, d.week_range, d.week_status,
             d.billable_hours, d.non_billable_hours, d.leave_hours,
             d.billing_loss_hours, d.total_hours, d.standard_hours,
             d.defaulted_flag, d.late_submission_flag,
             d.advance_closure_flag,
             d.overridden_flag, d.locked_flag,
             d.reject_reason, d.reject_remarks,
             d.submitted_on, d.approved_by, d.approved_on,
             d.days_total, d.days_pending, d.days_approved, d.days_rejected,
             d.projects
        FROM v_oc_ts_week_detail d
       WHERE d.employee_id = :employeeId
         AND d.period_id   = :periodId
         AND EXISTS (SELECT 1 FROM oc_ts_entry e
                      WHERE e.ts_week_id = d.ts_week_id
                        AND e.project_id = :projectId)
       ORDER BY d.week_index
    ]');
  COMMIT;
END;
/

-- ── GET days/:tsWeekId  (line-wise daily view) ───────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'days/:tsWeekId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'days/:tsWeekId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT ts_entry_id, entry_date, day_name,
             project_id, project_name, task_id, task_code, task_name,
             hours, entry_type, billable_type, unbilled_reason,
             shift_code, standard_hours, is_leave, absence_type,
             day_status, reject_reason, reject_remarks, source
        FROM v_oc_ts_day_detail
       WHERE ts_week_id = :tsWeekId
       ORDER BY entry_date, project_name, task_code
    ]');
  COMMIT;
END;
/

-- ── POST approve/month  (ACT-012 multi-select) ───────────────
-- The page sends the selected employee ids as a JSON array so "approve all or
-- some employees" is one transaction, not N calls.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'approve/month');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'approve/month',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_done NUMBER := 0;
      BEGIN
        FOR e IN (SELECT emp FROM JSON_TABLE(TO_CLOB(:employees), '$[*]'
                                COLUMNS (emp VARCHAR2(50) PATH '$'))) LOOP
          oc_time_pkg.approve_employee_month(
            p_project_id   => :projectId,
            p_period_id    => :periodId,
            p_employee_id  => e.emp,
            p_actor_emp_id => :actorEmpId,
            p_actor        => NVL(:actor,'VBCS_USER'),
            p_trace_id     => :traceId);
          v_done := v_done + 1;
        END LOOP;
        COMMIT;
        :status_code := 200;
        HTP.P('{"approved":' || v_done || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"approved":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST reject/month  (ACT-013) ─────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'reject/month');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'reject/month',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_done NUMBER := 0;
      BEGIN
        FOR e IN (SELECT emp FROM JSON_TABLE(TO_CLOB(:employees), '$[*]'
                                COLUMNS (emp VARCHAR2(50) PATH '$'))) LOOP
          oc_time_pkg.reject_employee_month(
            p_project_id   => :projectId,
            p_period_id    => :periodId,
            p_employee_id  => e.emp,
            p_reason       => :reason,
            p_remarks      => :remarks,
            p_actor_emp_id => :actorEmpId,
            p_actor        => NVL(:actor,'VBCS_USER'),
            p_trace_id     => :traceId);
          v_done := v_done + 1;
        END LOOP;
        COMMIT;
        :status_code := 200;
        HTP.P('{"rejected":' || v_done || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"rejected":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST approve/week/:id  &  reject/week/:id ────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'approve/week/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'approve/week/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(30);
      BEGIN
        oc_time_pkg.approve_week(:id, :actorEmpId, NVL(:actor,'VBCS_USER'), :traceId);
        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :id;
        COMMIT; :status_code := 200;
        HTP.P('{"tsWeekId":' || :id || ',"weekStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'reject/week/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'reject/week/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.reject_week(:id, :reason, :remarks, :actorEmpId,
                                NVL(:actor,'VBCS_USER'), :traceId);
        COMMIT; :status_code := 200;
        HTP.P('{"tsWeekId":' || :id || ',"weekStatus":"Rejected"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST approve/day/:id  (ACT-017 date-wise) ────────────────
-- Accepts a JSON array of dates so "approve selected dates" is one call.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'approve/day/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'approve/day/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE
        v_done   NUMBER := 0;
        v_status VARCHAR2(30);
      BEGIN
        FOR d IN (SELECT dt FROM JSON_TABLE(TO_CLOB(:dates), '$[*]'
                                COLUMNS (dt VARCHAR2(10) PATH '$'))) LOOP
          oc_time_pkg.approve_day(:id, TO_DATE(d.dt,'YYYY-MM-DD'), :actorEmpId,
                                  NVL(:actor,'VBCS_USER'), :traceId);
          v_done := v_done + 1;
        END LOOP;
        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :id;
        COMMIT; :status_code := 200;
        HTP.P('{"approvedDates":' || v_done || ',"weekStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"approvedDates":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'reject/day/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'reject/day/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_done NUMBER := 0;
      BEGIN
        FOR d IN (SELECT dt FROM JSON_TABLE(TO_CLOB(:dates), '$[*]'
                                COLUMNS (dt VARCHAR2(10) PATH '$'))) LOOP
          oc_time_pkg.reject_day(:id, TO_DATE(d.dt,'YYYY-MM-DD'), :reason, :remarks,
                                 :actorEmpId, NVL(:actor,'VBCS_USER'), :traceId);
          v_done := v_done + 1;
        END LOOP;
        COMMIT; :status_code := 200;
        HTP.P('{"rejectedDates":' || v_done || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"rejectedDates":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST override/:tsEntryId  (ACT-016) ──────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'override/:tsEntryId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'override/:tsEntryId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.override_approve(:tsEntryId, :newHours, :reason, :actorEmpId,
                                     NVL(:actor,'VBCS_USER'), :traceId);
        COMMIT; :status_code := 200;
        HTP.P('{"tsEntryId":' || :tsEntryId || ',"overridden":true}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST override/:tsWeekId/finish ───────────────────────────
-- Called once after the last cell edit: flips the week to
-- 'Overridden and approved' (the flag was set by each override).
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'override/:tsWeekId/finish');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'override/:tsWeekId/finish',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(30);
      BEGIN
        oc_time_pkg.finish_override(:tsWeekId, :actorEmpId, NVL(:actor,'VBCS_USER'));
        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :tsWeekId;
        COMMIT; :status_code := 200;
        HTP.P('{"tsWeekId":' || :tsWeekId || ',"weekStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST approve/allweeks  (ACT-019 convenience roll-up) ─────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'approve/allweeks');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'approve/allweeks',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.approve_employee_month(
          :projectId, :periodId, :employeeId, :actorEmpId,
          NVL(:actor,'VBCS_USER'), :traceId);
        COMMIT; :status_code := 200;
        HTP.P('{"approved":true}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST advanceapprove  (ACT-024 / PROC-010) ────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'advanceapprove');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'advanceapprove',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_done NUMBER := 0;
      BEGIN
        IF :employees IS NULL THEN
          -- Whole project month.
          oc_time_pkg.advance_approve_month(
            :projectId, :periodId, NULL, :actorEmpId,
            NVL(:actor,'VBCS_USER'), :traceId);
          v_done := 1;
        ELSE
          FOR e IN (SELECT emp FROM JSON_TABLE(TO_CLOB(:employees), '$[*]'
                                  COLUMNS (emp VARCHAR2(50) PATH '$'))) LOOP
            oc_time_pkg.advance_approve_month(
              :projectId, :periodId, e.emp, :actorEmpId,
              NVL(:actor,'VBCS_USER'), :traceId);
            v_done := v_done + 1;
          END LOOP;
        END IF;
        COMMIT; :status_code := 200;
        HTP.P('{"advanceApproved":' || v_done || ',"flag":"Advance closure"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"advanceApproved":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST confirm  (ACT-020 / PROC-009 / RULE-020) ────────────
-- The single all-employees-at-once action. Fills the accrual interface table,
-- which the O2C accrual application then PULLS.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'confirm');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'confirm', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE
        v_id   NUMBER;
        v_rows NUMBER;
        v_msg  VARCHAR2(2000);
      BEGIN
        v_id := oc_time_pkg.confirm_month(
                  p_project_id   => :projectId,
                  p_period_id    => :periodId,
                  p_actor_emp_id => :actorEmpId,
                  p_confirm_type => NVL(:confirmType,'Normal'),
                  p_actor        => NVL(:actor,'VBCS_USER'),
                  p_trace_id     => :traceId);

        SELECT accrual_rows, accrual_message INTO v_rows, v_msg
          FROM oc_ts_month_confirm WHERE confirm_id = v_id;

        COMMIT; :status_code := 200;
        HTP.P('{"confirmId":' || v_id ||
              ',"accrualRows":' || NVL(v_rows,0) ||
              ',"message":"' || REPLACE(NVL(v_msg,''),'"','\"') || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        -- -20020 is the RULE-020 gate; the message tells the manager to approve
        -- everyone first (SC-19).
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── GET adjustments/:managerId  (PAGE-003 panel) ─────────────
-- RA-014: routed to BOTH the old and the new project manager.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'adjustments/:managerId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'adjustments/:managerId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT adjustment_id, employee_id, employee_name, work_date, adj_kind,
             source_period, post_period,
             old_project_name, old_task_code, old_hours,
             new_project_name, new_task_code, new_hours, net_hours,
             status, reason, action_date, posted_flag,
             old_mgr_approved_by, new_mgr_approved_by, applied_by, applied_on,
             CASE WHEN old_project_manager_id = :managerId THEN 'Y' ELSE 'N' END
               AS is_old_project_manager,
             CASE WHEN new_project_manager_id = :managerId THEN 'Y' ELSE 'N' END
               AS is_new_project_manager
        FROM v_oc_ts_adjustment
       WHERE status = 'Awaiting Approval'
         AND (old_project_manager_id = :managerId
           OR new_project_manager_id = :managerId)
       ORDER BY work_date DESC
    ]');
  COMMIT;
END;
/

-- ── POST adjustments/:id/approve  (ACT-021) ──────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'adjustments/:id/approve');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'adjustments/:id/approve',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(30); v_posted CHAR(1);
      BEGIN
        oc_time_pkg.approve_adjustment(:id, :actorEmpId,
                                       NVL(:actor,'VBCS_USER'), :traceId);
        SELECT status, posted_flag INTO v_status, v_posted
          FROM oc_ts_adjustment WHERE adjustment_id = :id;
        COMMIT; :status_code := 200;
        HTP.P('{"adjustmentId":' || :id || ',"status":"' || v_status ||
              '","posted":"' || v_posted || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── Leave-loss coverage (PAGE-006) ───────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'llc/:projectId/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'llc/:projectId/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT llc_id, project_id, project_number, project_name, revenue_model,
             leave_loss_flag, period_id, period_name,
             absent_employee_id, absent_employee_name,
             absence_date, absence_day, absence_type, absence_hours,
             cover_employee_id, cover_employee_name,
             llc_status, billed_flag,
             assigned_by, assigned_on, approved_by, approved_on, remarks
        FROM v_oc_ts_llc
       WHERE project_id = :projectId
         AND period_id  = :periodId
       ORDER BY absence_date, absent_employee_name
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'llc/generate');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'llc/generate',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_n NUMBER;
      BEGIN
        v_n := oc_time_pkg.generate_llc_lines(:projectId, :periodId,
                                              NVL(:actor,'VBCS_USER'));
        COMMIT; :status_code := 200;
        HTP.P('{"linesCreated":' || v_n || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"linesCreated":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- Eligible cover LOV (RULE-014) for one absence date.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'llc/cover/:projectId/:absenceDate');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval',
    p_pattern => 'llc/cover/:projectId/:absenceDate', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT cover_employee_id AS value, employee_name AS label,
             client_role, billing_status
        FROM v_oc_ts_llc_eligible_cover
       WHERE project_id   = :projectId
         AND absence_date = TO_DATE(:absenceDate,'YYYY-MM-DD')
       ORDER BY employee_name
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'llc/:id/assign');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'llc/:id/assign',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.assign_cover(:id, :coverEmployeeId, NVL(:actor,'VBCS_USER'));
        COMMIT; :status_code := 200;
        HTP.P('{"llcId":' || :id || ',"llcStatus":"Assigned"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'llc/:id/approve');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'llc/:id/approve',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.approve_cover(:id, :actorEmpId, NVL(:actor,'VBCS_USER'));
        COMMIT; :status_code := 200;
        HTP.P('{"llcId":' || :id || ',"llcStatus":"Approved","billed":true}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── Salary stopping (PAGE-007) ───────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'salaryhold/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'salaryhold/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT h.hold_id, h.employee_id, h.employee_name, h.worker_type,
             h.base_country, h.manager_emp_id, h.period_id, h.period_name,
             h.weeks_total, h.weeks_submitted, h.weeks_defaulted, h.weeks_split,
             h.applied_hours, h.default_hours,
             h.salary_status, h.hold_release_days, h.window_expires_on,
             h.window_expired, h.held_on, h.released_on, h.released_by, h.remarks
        FROM v_oc_ts_salary_hold h
       WHERE h.period_id = :periodId
         AND (:managerId IS NULL OR h.manager_emp_id = :managerId)
       ORDER BY h.salary_status, h.employee_name
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'salaryhold/run/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'salaryhold/run/:periodId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_job NUMBER;
      BEGIN
        v_job := oc_time_pkg.run_salary_stopping(:periodId, NVL(:actor,'VBCS_USER'));
        :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- Weeks breakdown pop-up: submitted vs defaulted with applied vs default hours.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'salaryhold/:periodId/:employeeId/weeks');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval',
    p_pattern => 'salaryhold/:periodId/:employeeId/weeks', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT ts_week_id, week_index, week_start, week_end, week_range, week_status,
             defaulted_flag, locked_flag,
             total_hours,
             CASE WHEN week_status = 'Defaulted' THEN 0 ELSE total_hours END
               AS applied_hours,
             CASE WHEN week_status = 'Defaulted' THEN total_hours ELSE 0 END
               AS default_hours
        FROM v_oc_ts_week_detail
       WHERE period_id   = :periodId
         AND employee_id = :employeeId
       ORDER BY week_index
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'salaryhold/:id/release');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'salaryhold/:id/release',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.release_salary_hold(:id, :actorEmpId, :remarks,
                                        NVL(:actor,'VBCS_USER'));
        COMMIT; :status_code := 200;
        HTP.P('{"holdId":' || :id || ',"salaryStatus":"Released"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── GET audit/:tsWeekId  (REP-007) ───────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'audit/:tsWeekId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'audit/:tsWeekId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT a.audit_id, a.employee_id, a.employee_name, a.entry_date,
             a.change_type,
             a.old_project_name, a.old_task_code, a.old_hours,
             a.new_project_name, a.new_task_code, a.new_hours, a.delta_hours,
             a.change_reason, a.changed_by, a.changed_on
        FROM v_oc_ts_audit_trail a
       WHERE EXISTS (SELECT 1 FROM oc_ts_audit x
                      WHERE x.audit_id   = a.audit_id
                        AND x.ts_week_id = :tsWeekId)
       ORDER BY a.changed_on DESC
    ]');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT ORDS module oc.time.approval defined.
PROMPT ============================================================
