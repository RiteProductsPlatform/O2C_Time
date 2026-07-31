--==============================================================
-- time/ords/11_ords_time.sql
-- O2C Timesheet Module — ORDS module oc.time  (EMPLOYEE surface)
--
-- Base path: /oc/time/        (full URL: <ords>/<schema>/oc/time/...)
-- Personas:  PER-001 Employee, PER-002 Contractor
-- Full rebuild (DELETE_MODULE first), consistent with the O2C convention.
--
-- Endpoints
--   GET  me/:employeeId                          worker + role + allocation %
--   GET  periods                                 month LOV with editability
--   GET  weeks/:employeeId/:periodId             weeks in the month + status
--   POST weeks/ensure                            create/find a week for a date
--   GET  grid/:tsWeekId                          the weekly grid (pivoted)
--   GET  shift/:tsWeekId                         per-day shift & standard row
--   PUT  entry                                   save one cell (Save Draft)
--   POST entries/batch                           save many cells in one call
--   DELETE line/:tsWeekId/:projectId/:taskId     remove a line
--   POST weeks/:id/submit                        submit for approval
--   GET  allocation/:employeeId                  allocation pop-up
--   GET  tasks/:projectId                        task LOV (WBS + common)
--   GET  projects/:employeeId                    projects the employee may charge
--   GET  cutoffs/:periodId                       cut-off display
--   GET  lookups/:type                           any seeded dictionary
--   GET  rejection/:tsWeekId                     reason + remarks + rejected dates
--   POST adjustments                             apply a retro day-wise change
--   GET  adjustments/:employeeId                 my adjustments & their status
--   GET  clientdocs/:projectId/:periodId         client timesheet documents
--   POST clientdocs                              upload a client timesheet
--   DELETE clientdocs/:id                        remove a document
--
-- NOTE: write handlers emit JSON via HTP.P, never APEX_JSON — APEX is not
--       installed on every target schema and referencing it makes ORDS reject
--       the handler with a 403.
--
-- Depends on: time/01 .. time/10
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

BEGIN ORDS.DELETE_MODULE(p_module_name => 'oc.time'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time',
    p_base_path      => '/oc/time/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'O2C Timesheet - employee surface (entry, submit, adjustments, client docs).');
  COMMIT;
END;
/

-- ── GET me/:employeeId ───────────────────────────────────────
-- RULE-022 drives the menu from APP_ROLE. TOTAL_ALLOC_PCT lets PAGE-001 raise
-- the RULE-001 warning without a second round-trip.
--
-- Resolves on EMAIL **or** EMPLOYEE_ID. The identity provider gives the shell an
-- email address, not an HCM PersonNumber, so an employee_id-only lookup would
-- never match a real sign-in; matching either also keeps the endpoint usable
-- from a test harness that knows the person number.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'me/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'me/:employeeId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT w.employee_id, w.employee_name, w.email, w.worker_type, w.app_role,
             w.base_country, w.deputed_country, w.std_hours_per_day,
             w.manager_emp_id, m.employee_name AS manager_name,
             w.status,
             (SELECT NVL(SUM(alloc_pct),0) FROM oc_time_allocation al
               WHERE al.employee_id = w.employee_id AND al.status = 'Active')
               AS total_alloc_pct,
             oc_time_pkg.get_open_period_id AS open_period_id
        FROM oc_time_worker w
        LEFT JOIN oc_time_worker m ON m.employee_id = w.manager_emp_id
       WHERE UPPER(w.email) = UPPER(:employeeId)
          OR w.employee_id  = :employeeId
    ]');
  COMMIT;
END;
/

-- ── GET periods ──────────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'periods');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'periods', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT period_id, period_name, period_year, period_month, status,
             period_state, editable_flag, adjustment_allowed,
             start_date, end_date, ts_cutoff_day, ts_cutoff_time,
             delivery_cutoff, payroll_cutoff, advance_close, adjustment_months
        FROM v_oc_ts_my_periods
       ORDER BY period_year DESC, period_month DESC
    ]');
  COMMIT;
END;
/

-- ── GET weeks/:employeeId/:periodId ──────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time',
                       p_pattern => 'weeks/:employeeId/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'weeks/:employeeId/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT ts_week_id, week_index, week_start, week_end, week_range,
             week_status, locked_flag,
             billable_hours, non_billable_hours, leave_hours,
             billing_loss_hours, total_hours, standard_hours,
             defaulted_flag, late_submission_flag,
             advance_closure_flag, overridden_flag,
             reject_reason, reject_remarks, submitted_on, approved_on,
             days_total, days_pending, days_approved, days_rejected
        FROM v_oc_ts_week_detail
       WHERE employee_id = :employeeId
         AND period_id   = :periodId
       ORDER BY week_index
    ]');
  COMMIT;
END;
/

-- ── POST weeks/ensure ────────────────────────────────────────
-- The page asks for "the week containing this date" and gets an id back,
-- creating the week on first touch. Weeks are clipped to the month.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'weeks/ensure');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'weeks/ensure', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_id NUMBER;
      BEGIN
        v_id := oc_time_pkg.ensure_week(
                  :employeeId, TO_DATE(:onDate,'YYYY-MM-DD'),
                  NVL(:actor,'VBCS_USER'));
        COMMIT;
        :status_code := 200;
        HTP.P('{"tsWeekId":' || v_id || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── GET grid/:tsWeekId ───────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'grid/:tsWeekId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'grid/:tsWeekId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT ts_week_id, week_index, week_start, week_end, week_status, locked_flag,
             project_id, project_number, project_name, project_type,
             task_id, task_code, task_name, task_type,
             billable_type, unbilled_reason, is_leave,
             mon_hours, tue_hours, wed_hours, thu_hours, fri_hours,
             sat_hours, sun_hours, line_total, line_status
        FROM v_oc_ts_week_grid
       WHERE ts_week_id = :tsWeekId
       ORDER BY project_type, project_name, task_type DESC, task_code
    ]');
  COMMIT;
END;
/

-- ── GET shift/:tsWeekId ──────────────────────────────────────
-- FLD-008 / RULE-011: read-only shift row from HCM, one per day.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'shift/:tsWeekId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'shift/:tsWeekId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT entry_date, day_name, shift_code, standard_hours,
             day_total, is_leave, day_status
        FROM v_oc_ts_day_shift
       WHERE ts_week_id = :tsWeekId
       ORDER BY entry_date
    ]');
  COMMIT;
END;
/

-- ── PUT entry  (save one cell) ───────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'entry');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'entry', p_method => 'PUT',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.save_entry(
          p_ts_week_id      => :tsWeekId,
          p_project_id      => :projectId,
          p_task_id         => :taskId,
          p_entry_date      => TO_DATE(:entryDate,'YYYY-MM-DD'),
          p_hours           => :hours,
          p_source          => NVL(:source,'Employee'),
          p_unbilled_reason => :unbilledReason,
          p_actor           => NVL(:actor,'VBCS_USER'));
        COMMIT;
        :status_code := 200;
        HTP.P('{"saved":true}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        -- -20003 / -20004 / -20007 / -20010 / -20013 are business rules, so they
        -- surface as 400 with the rule's own message for the toast.
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST entries/batch  (save the whole grid in one call) ────
-- The weekly grid produces up to 7 x lines cells. Sending them individually
-- would be 7N round-trips, so the page posts a JSON array and this handler
-- iterates server-side inside ONE transaction: either the whole grid saves or
-- nothing does.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'entries/batch');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'entries/batch', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
      DECLARE
        v_saved NUMBER := 0;
      BEGIN
        FOR c IN (
          SELECT ts_week_id, project_id, task_id, entry_date, hours, unbilled_reason
            FROM JSON_TABLE(TO_CLOB(:cells), '$[*]'
                   COLUMNS (
                     ts_week_id      NUMBER        PATH '$.tsWeekId',
                     project_id      NUMBER        PATH '$.projectId',
                     task_id         NUMBER        PATH '$.taskId',
                     entry_date      VARCHAR2(10)  PATH '$.entryDate',
                     hours           NUMBER        PATH '$.hours',
                     unbilled_reason VARCHAR2(60)  PATH '$.unbilledReason')))
        LOOP
          oc_time_pkg.save_entry(
            p_ts_week_id      => c.ts_week_id,
            p_project_id      => c.project_id,
            p_task_id         => c.task_id,
            p_entry_date      => TO_DATE(c.entry_date,'YYYY-MM-DD'),
            p_hours           => c.hours,
            p_source          => NVL(:source,'Employee'),
            p_unbilled_reason => c.unbilled_reason,
            p_actor           => NVL(:actor,'VBCS_USER'));
          v_saved := v_saved + 1;
        END LOOP;
        COMMIT;
        :status_code := 200;
        HTP.P('{"saved":' || v_saved || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"saved":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── DELETE line/:tsWeekId/:projectId/:taskId ─────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time',
                       p_pattern => 'line/:tsWeekId/:projectId/:taskId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time',
    p_pattern => 'line/:tsWeekId/:projectId/:taskId', p_method => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        oc_time_pkg.remove_line(:tsWeekId, :projectId, :taskId, NVL(:actor,'VBCS_USER'));
        COMMIT;
        :status_code := 200;
        HTP.P('{"removed":true}');
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

-- ── POST weeks/:id/submit ────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'weeks/:id/submit');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'weeks/:id/submit', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(30);
      BEGIN
        oc_time_pkg.submit_week(:id, NVL(:actor,'VBCS_USER'), :traceId);
        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :id;
        COMMIT;
        :status_code := 200;
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

-- ── GET allocation/:employeeId  (ACT-008 pop-up) ─────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'allocation/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'allocation/:employeeId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT allocation_id, project_id, project_number, project_name, customer_name,
             project_type, revenue_model, alloc_pct, billing_status, client_role,
             cap_type, cap_hours, approving_manager_id, approving_manager_name,
             start_date, end_date, total_alloc_pct
        FROM v_oc_ts_allocation
       WHERE employee_id = :employeeId
       ORDER BY project_type, project_name
    ]');
  COMMIT;
END;
/

-- ── GET tasks/:projectId  (RULE-010 LOV) ─────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'tasks/:projectId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'tasks/:projectId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT task_id, task_code, task_name, task_type, task_group,
             billable_type, unbilled_reason
        FROM v_oc_ts_task_lov
       WHERE project_id = :projectId
       ORDER BY sort_order, task_code
    ]');
  COMMIT;
END;
/

-- ── GET projects/:employeeId ─────────────────────────────────
-- Allocated projects (a 50/50 split shows both) PLUS the Organization
-- (Non-Billable) project, which is implicitly assigned to everyone (FLD-006).
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'projects/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'projects/:employeeId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT p.project_id, p.project_number, p.project_name, p.customer_name,
             p.project_type, p.revenue_model, p.leave_loss_flag,
             al.alloc_pct, al.billing_status, al.client_role,
             al.approving_manager_id
        FROM oc_time_project    p
        JOIN oc_time_allocation al ON al.project_id = p.project_id
       WHERE al.employee_id = :employeeId
         AND al.status      = 'Active'
         AND p.status       = 'Active'
      UNION ALL
      SELECT p.project_id, p.project_number, p.project_name, p.customer_name,
             p.project_type, p.revenue_model, p.leave_loss_flag,
             NULL, 'Unbilled', NULL, NULL
        FROM oc_time_project p
       WHERE p.project_type = 'Organization'
         AND p.status       = 'Active'
         AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al2
                          WHERE al2.project_id  = p.project_id
                            AND al2.employee_id = :employeeId
                            AND al2.status      = 'Active')
       ORDER BY 5, 3
    ]');
  COMMIT;
END;
/

-- ── GET cutoffs/:periodId ────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'cutoffs/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'cutoffs/:periodId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT period_id, period_name, status, payroll_country,
             start_date, end_date, accounting_date,
             ts_cutoff_day, ts_cutoff_time, weekly_cutoff_display,
             delivery_cutoff, finance_cutoff, book_closure, mec_close,
             client_cutoff, payroll_cutoff, advance_close,
             adjustment_months, backdated_months,
             hold_release_days, contractor_resubmit_days
        FROM v_oc_time_cutoffs
       WHERE period_id = :periodId
    ]');
  COMMIT;
END;
/

-- ── GET lookups/:type ────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'lookups/:type');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'lookups/:type', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT lookup_code AS value, meaning AS label, usage_note, selectable, sort_order
        FROM oc_time_lookup
       WHERE lookup_type = UPPER(:type)
         AND active_flag = 'Y'
       ORDER BY sort_order, lookup_code
    ]');
  COMMIT;
END;
/

-- ── GET rejection/:tsWeekId  (#5 shown to the employee) ──────
-- The employee must see the reason, the remarks AND the specific rejected
-- dates, so this returns one row per rejected day.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'rejection/:tsWeekId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'rejection/:tsWeekId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT DISTINCT
             e.reject_reason, e.reject_remarks,
             TO_CHAR(e.entry_date,'YYYY-MM-DD') AS rejected_date,
             TO_CHAR(e.entry_date,'DY')         AS rejected_day
        FROM oc_ts_entry e
       WHERE e.ts_week_id = :tsWeekId
         AND e.day_status = 'Rejected'
       ORDER BY 3
    ]');
  COMMIT;
END;
/

-- ── POST adjustments  (ACT-009 retro day-wise change) ────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'adjustments');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'adjustments', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_id NUMBER;
      BEGIN
        v_id := oc_time_pkg.apply_adjustment(
                  p_employee_id    => :employeeId,
                  p_work_date      => TO_DATE(:workDate,'YYYY-MM-DD'),
                  p_old_project_id => :oldProjectId,
                  p_old_task_id    => :oldTaskId,
                  p_old_hours      => :oldHours,
                  p_new_project_id => :newProjectId,
                  p_new_task_id    => :newTaskId,
                  p_new_hours      => :newHours,
                  p_reason         => :reason,
                  p_adj_kind       => NVL(:adjKind,'RetroWBS'),
                  p_actor          => NVL(:actor,'VBCS_USER'),
                  p_trace_id       => :traceId);
        COMMIT;
        :status_code := 201;
        HTP.P('{"adjustmentId":' || v_id || ',"status":"Awaiting Approval"}');
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

-- ── GET adjustments/:employeeId ──────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'adjustments/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'adjustments/:employeeId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT adjustment_id, work_date, adj_kind, source_period, post_period,
             old_project_name, old_task_code, old_hours,
             new_project_name, new_task_code, new_hours, net_hours,
             status, reason, action_date, posted_flag,
             old_mgr_approved_by, new_mgr_approved_by, applied_on
        FROM v_oc_ts_adjustment
       WHERE employee_id = :employeeId
       ORDER BY work_date DESC, adjustment_id DESC
    ]');
  COMMIT;
END;
/

-- ── GET/POST/DELETE clientdocs (PROC-011) ────────────────────
-- Metadata only on the list: the BLOB is fetched separately so the documents
-- table stays cheap to render.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time',
                       p_pattern => 'clientdocs/:projectId/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'clientdocs/:projectId/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT d.doc_id, d.doc_name, d.mime_type, d.doc_size, d.display_mode,
             d.week_index, d.uploaded_by,
             TO_CHAR(d.uploaded_on,'YYYY-MM-DD HH24:MI') AS uploaded_on,
             d.remarks,
             ROUND(d.doc_size / 1024, 1) AS size_kb
        FROM oc_ts_client_doc d
       WHERE d.project_id = :projectId
         AND d.period_id  = :periodId
       ORDER BY d.uploaded_on DESC
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'clientdocs');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'clientdocs', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE
        v_id   NUMBER;
        v_blob BLOB;
        v_size NUMBER;
      BEGIN
        -- The page sends base64; decode server-side so the 25MB ceiling and the
        -- MIME whitelist (CHK_OC_TSCD_SIZE / CHK_OC_TSCD_MIME) are enforced
        -- where a caller cannot bypass them.
        v_blob := oc_time_b64_to_blob(:content);
        v_size := NVL(DBMS_LOB.GETLENGTH(v_blob), 0);

        IF v_size = 0 THEN
          :status_code := 400;
          HTP.P('{"error":"The uploaded file is empty."}');
          RETURN;
        END IF;

        IF v_size > 26214400 THEN
          :status_code := 400;
          HTP.P('{"error":"File exceeds the 25MB limit."}');
          RETURN;
        END IF;

        INSERT INTO oc_ts_client_doc (
          project_id, period_id, display_mode, week_index,
          doc_name, mime_type, doc_size, doc_content, uploaded_by, remarks)
        VALUES (
          :projectId, :periodId, NVL(:displayMode,'Whole month'), :weekIndex,
          :docName, :mimeType, v_size, v_blob, NVL(:actor,'VBCS_USER'), :remarks)
        RETURNING doc_id INTO v_id;

        COMMIT;
        :status_code := 201;
        HTP.P('{"docId":' || v_id || ',"docSize":' || v_size || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'clientdocs/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'clientdocs/:id', p_method => 'GET',
    p_source_type => ORDS.source_type_media,
    p_source => q'[
      SELECT mime_type, doc_content FROM oc_ts_client_doc WHERE doc_id = :id
    ]');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'clientdocs/:id', p_method => 'DELETE',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      BEGIN
        DELETE FROM oc_ts_client_doc WHERE doc_id = :id;
        IF SQL%ROWCOUNT = 0 THEN
          ROLLBACK; :status_code := 404;
          HTP.P('{"error":"Document not found"}');
          RETURN;
        END IF;
        COMMIT; :status_code := 200;
        HTP.P('{"docId":' || :id || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT ORDS module oc.time defined.
PROMPT ============================================================
