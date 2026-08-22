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
--   GET  days/:tsWeekId/export                   the same rows as CSV (ACT-018)
--   POST approve/month                           approve selected employees
--   POST reject/month                            reject selected employees
--   POST approve/week/:id                        approve one week
--   POST reject/week/:id                         reject one week / dates
--   POST approve/day/:id                         approve one date
--   POST reject/day/:id                          reject one date
--   POST revoke/day/:id                          undo a day decision
--   POST revoke/week/:id                         undo every decision on a week
--   POST override/:tsEntryId                     override an hour cell
--   POST override/:tsWeekId/finish               close the overridden week
--   POST approve/allweeks                        approve every pending week
--   POST advanceapprove                          advance-approve a future month
--   POST confirm                                 confirm month -> accrual
--   GET  adjustments/:managerId                  retro adjustments to approve
--   POST adjustments/:id/approve                 approve a retro adjustment
--   GET  llc/:projectId/:periodId                leave-loss absentee lines
--   POST llc/generate                            rebuild the absentee list (add + retract)
--   GET  llc/roster/:projectId/:periodId         who the live HR read must ask about
--   GET  llc/cover/:projectId/:absenceDate       eligible cover LOV
--   POST llc/:id/assign                          assign a cover
--   POST llc/:id/approve                         approve the coverage
--   GET  salaryhold/queue/:managerId             corrections awaiting me
--   POST salaryhold/day/:holdDayId/decide        approve/reject one date
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
             week_count, submitted_weeks, approved_weeks, rejected_weeks,
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
    -- PROJECT-SCOPED FIGURES, 18-Aug-2026. :projectId used to be an EXISTS test
    -- and nothing more -- "does this week touch 444?" -- while every number
    -- returned came from V_OC_TS_WEEK_DETAIL, which aggregates the whole week.
    -- So the 444 manager opening Saicharan's week 3 saw PROJECTS "444, 555" and
    -- 40 billable hours when 444's share was 20. Reported from the screen.
    --
    -- The week itself is NOT split -- OC_TS_WEEK stays one row holding
    -- everything, by decision. Only the presentation is scoped, which is what
    -- makes the screen right when two projects have different managers.
    --
    -- WHAT STAYS WEEK-LEVEL, and it is not an oversight:
    --   standard_hours       the person's capacity, from their work pattern
    --   billing_loss_hours   GREATEST(0, standard - billable - leave), so it is
    --                        capacity too. Divided per project it would report
    --                        almost a full week of loss against every one
    --   status, flags, locks the week is the unit of approval and of the
    --                        cut-off; splitting these would invent a state the
    --                        model cannot hold
    --
    -- OTHER_PROJECTS carries the honesty. approve_week fires the event against
    -- the WEEK, so approving from 444 also approves this employee's 555 and
    -- PCS10034 days -- scoping the display without saying so would hide that
    -- rather than fix it. The page shows the count beside the week.
    p_source => q'~
      SELECT d.ts_week_id, d.employee_id, d.employee_name, d.worker_type,
             d.week_index, d.week_start, d.week_end, d.week_range, d.week_status,
             d.submission_status, d.approval_status,
             pa.billable_hours, pa.non_billable_hours, pa.leave_hours,
             d.billing_loss_hours, pa.total_hours, d.standard_hours,
             d.defaulted_flag, d.defaulted_by, d.late_submission_flag,
             d.advance_closure_flag,
             d.overridden_flag, d.locked_flag,
             pa.has_reversal_flag, pa.has_adjustment_flag,
             d.reject_reason, d.reject_remarks,
             d.submitted_on, d.approved_by, d.approved_on,
             pa.days_total, pa.days_pending, pa.days_approved, pa.days_rejected,
             (SELECT p1.project_number FROM oc_time_project p1
               WHERE p1.project_id = :projectId) AS projects,
             (SELECT LISTAGG(DISTINCT p2.project_number, ', ')
                       WITHIN GROUP (ORDER BY p2.project_number)
                FROM oc_ts_entry e2
                JOIN oc_time_project p2 ON p2.project_id = e2.project_id
               WHERE e2.ts_week_id = d.ts_week_id
                 AND e2.project_id <> :projectId) AS other_projects,
             (SELECT COUNT(DISTINCT e3.project_id) FROM oc_ts_entry e3
               WHERE e3.ts_week_id = d.ts_week_id
                 AND e3.project_id <> :projectId) AS other_project_count
        FROM v_oc_ts_week_detail d
        JOIN (SELECT e.ts_week_id,
                     NVL(SUM(CASE WHEN e.billable_type = 'Billable'
                                   AND e.is_leave = 'N' THEN e.hours END),0)
                       AS billable_hours,
                     NVL(SUM(CASE WHEN e.billable_type = 'Non-billable'
                                   AND e.is_leave = 'N' THEN e.hours END),0)
                       AS non_billable_hours,
                     NVL(SUM(CASE WHEN e.is_leave = 'Y' THEN e.hours END),0)
                       AS leave_hours,
                     NVL(SUM(e.hours),0) AS total_hours,
                     MAX(CASE WHEN e.entry_type = 'Reversal'   THEN 'Y' ELSE 'N' END)
                       AS has_reversal_flag,
                     MAX(CASE WHEN e.entry_type = 'Adjustment' THEN 'Y' ELSE 'N' END)
                       AS has_adjustment_flag,
                     COUNT(DISTINCT e.entry_date) AS days_total,
                     COUNT(DISTINCT CASE WHEN e.day_status = 'Pending'
                                         THEN e.entry_date END) AS days_pending,
                     COUNT(DISTINCT CASE WHEN e.day_status = 'Approved'
                                         THEN e.entry_date END) AS days_approved,
                     COUNT(DISTINCT CASE WHEN e.day_status = 'Rejected'
                                         THEN e.entry_date END) AS days_rejected
                FROM oc_ts_entry e
               WHERE e.project_id = :projectId
                 AND e.ts_week_id IN (SELECT w.ts_week_id FROM oc_ts_week w
                                       WHERE w.employee_id = :employeeId
                                         AND w.period_id   = :periodId)
               GROUP BY e.ts_week_id) pa
          ON pa.ts_week_id = d.ts_week_id
       WHERE d.employee_id = :employeeId
         AND d.period_id   = :periodId
       ORDER BY d.week_index
    ~');
  COMMIT;
END;
/

-- ── GET days/:tsWeekId  (line-wise daily view) ───────────────
-- Kept unscoped: the employee's own view and the CSV export both want the whole
-- week. The manager's drill-down uses the project-scoped template below.
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
             day_status, reject_reason, reject_remarks, source,
             flag_count, flag_codes, flag_labels
        FROM v_oc_ts_day_detail
       WHERE ts_week_id = :tsWeekId
       ORDER BY entry_date, project_name, task_code
    ]');
  COMMIT;
END;
/

-- ── GET days/:tsWeekId/project/:projectId  (PAGE-005 drill-down) ──
-- The manager arrived from ONE project and must see that project's days. The
-- unscoped template above listed every project in the week, so opening week 3
-- of Saicharan from 444 showed a 444 line and a 555 line for every day.
--
-- A SEPARATE TEMPLATE rather than an optional bind on the one above. ORDS binds
-- query parameters by name, so :projectId would resolve to NULL when absent and
-- "AND (:projectId IS NULL OR project_id = :projectId)" would read as
-- unfiltered -- which is the right answer only if the parameter was genuinely
-- omitted, and indistinguishable from a page that meant to send it and did not.
-- Silent-NULL is the trap already recorded twice in CLAUDE.md (an undeclared
-- BIP bind, and JSON_TABLE on a wrong PATH). A distinct route cannot be got
-- wrong by omission: either it is called or it is not.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'days/:tsWeekId/project/:projectId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval',
    p_pattern => 'days/:tsWeekId/project/:projectId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT ts_entry_id, entry_date, day_name,
             project_id, project_name, task_id, task_code, task_name,
             hours, entry_type, billable_type, unbilled_reason,
             shift_code, standard_hours, is_leave, absence_type,
             day_status, reject_reason, reject_remarks, source,
             flag_count, flag_codes, flag_labels
        FROM v_oc_ts_day_detail
       WHERE ts_week_id = :tsWeekId
         AND project_id = :projectId
       ORDER BY entry_date, task_code
    ]');
  COMMIT;
END;
/

-- ── GET days/:tsWeekId/export  (ACT-018, download half) ──────
--
-- The day-wise grid as CSV, for a manager who would rather read a week in Excel
-- than on screen. DOWNLOAD ONLY: the upload half of ACT-018 is deliberately not
-- built (decision 01-Aug-2026, on hold). Nothing here is read back, which is
-- why plain CSV is safe — Excel reformatting 8.00 to 8 on save costs nothing
-- when no one parses the file again.
--
-- Emitted with OWA_UTIL rather than as a collection feed so the response
-- carries text/csv and a filename; a feed would hand the browser JSON.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'days/:tsWeekId/export');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'days/:tsWeekId/export',
    p_method => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
      DECLARE
        v_emp   VARCHAR2(200);
        v_range VARCHAR2(60);
        v_file  VARCHAR2(200);

        -- RFC 4180: wrap in quotes and double any embedded quote. Task and
        -- project names carry commas often enough that skipping this would
        -- shift every later column on those rows.
        FUNCTION csv(p IN VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
          IF p IS NULL THEN RETURN ''; END IF;
          RETURN '"' || REPLACE(p, '"', '""') || '"';
        END;
      BEGIN
        SELECT employee_name, week_range INTO v_emp, v_range
          FROM v_oc_ts_week_detail WHERE ts_week_id = :tsWeekId;

        -- Spaces and slashes out of the filename: a raw week range like
        -- "13-Jul to 19-Jul" survives Content-Disposition badly across browsers.
        v_file := 'timesheet-' ||
                  REGEXP_REPLACE(LOWER(v_emp || '-' || v_range),
                                 '[^a-z0-9]+', '-') || '.csv';

        OWA_UTIL.mime_header('text/csv', FALSE);
        HTP.P('Content-Disposition: attachment; filename="' || v_file || '"');
        OWA_UTIL.http_header_close;

        HTP.P('entry_id,entry_date,day,project,task,hours,entry_type,' ||
              'billable_type,unbilled_reason,shift,standard_hours,day_status');

        FOR d IN (SELECT ts_entry_id, entry_date, day_name,
                         project_name, task_code, task_name, hours, entry_type,
                         billable_type, unbilled_reason, shift_code,
                         standard_hours, day_status
                    FROM v_oc_ts_day_detail
                   WHERE ts_week_id = :tsWeekId
                   ORDER BY entry_date, project_name, task_code)
        LOOP
          -- entry_date is ALREADY a string: V_OC_TS_DAY_DETAIL selects
          -- TO_CHAR(e.entry_date,'YYYY-MM-DD'). Formatting it again raised
          -- ORA-01722 on the first row, and the only handler below catches
          -- NO_DATA_FOUND, so ORDS answered 555 and the download did nothing.
          HTP.P(d.ts_entry_id                             || ',' ||
                d.entry_date                              || ',' ||
                csv(d.day_name)                           || ',' ||
                csv(d.project_name)                       || ',' ||
                csv(d.task_code || ' ' || d.task_name)    || ',' ||
                TO_CHAR(d.hours, 'FM99990.00')            || ',' ||
                csv(d.entry_type)                         || ',' ||
                csv(d.billable_type)                      || ',' ||
                csv(d.unbilled_reason)                    || ',' ||
                csv(d.shift_code)                         || ',' ||
                TO_CHAR(d.standard_hours, 'FM99990.00')   || ',' ||
                csv(d.day_status));
        END LOOP;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          -- Plain text, not JSON: the browser is navigating to this URL, so
          -- whatever comes back is what the user reads.
          OWA_UTIL.mime_header('text/plain', TRUE);
          HTP.P('No such week.');
        WHEN OTHERS THEN
          -- Anything else used to escape and become an ORDS 555, which the
          -- browser shows as a failed download with no clue why. Say what
          -- happened, in the response the user is already looking at.
          OWA_UTIL.mime_header('text/plain', TRUE);
          HTP.P('The export could not be produced: ' || SQLERRM);
      END;
    ~');
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
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text, not named binds. A payload carrying a JSON ARRAY cannot be
        -- bound field by field - ORDS has no SQL type for the array, so the
        -- whole request fails with ORA-17004 before any of this runs and the
        -- caller only sees "The request could not be processed for a user
        -- defined resource". Path parameters are unaffected.
        v_body   CLOB := :body_text;
        v_proj   NUMBER;
        v_period NUMBER;
        v_aeid   VARCHAR2(50);
        v_actor  VARCHAR2(100);
        v_trace  VARCHAR2(64);
        v_done   NUMBER := 0;
        -- Per-employee outcome. A bulk action must not be all-or-nothing:
        -- selecting the whole team when the manager is a member of it raised
        -- RULE-015 on their own row, aborted the loop, rolled back and returned
        -- approved:0 -- so nine perfectly approvable months were refused
        -- because of the tenth. Same principle the sync handlers already use:
        -- a bad row is recorded, it does not abort the chunk.
        v_skip   NUMBER := 0;
        v_err    VARCHAR2(500);
        v_detail VARCHAR2(3000);
      BEGIN
        SELECT proj, per, aeid, NVL(act,'VBCS_USER'), tr
          INTO v_proj, v_period, v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (proj NUMBER        PATH '$.projectId',
                          per  NUMBER        PATH '$.periodId',
                          aeid VARCHAR2(50)  PATH '$.actorEmpId',
                          act  VARCHAR2(100) PATH '$.actor',
                          tr   VARCHAR2(64)  PATH '$.traceId'));

        FOR e IN (SELECT emp FROM JSON_TABLE(v_body, '$.employees[*]'
                                COLUMNS (emp VARCHAR2(50) PATH '$'))) LOOP
          BEGIN
            oc_time_pkg.approve_employee_month(
              p_project_id   => v_proj,
              p_period_id    => v_period,
              p_employee_id  => e.emp,
              p_actor_emp_id => v_aeid,
              p_actor        => v_actor,
              p_trace_id     => v_trace);
            v_done := v_done + 1;
          EXCEPTION WHEN OTHERS THEN
            v_skip := v_skip + 1;
            -- SUBSTR is not cosmetic. SQLERRM can exceed the declared length,
            -- and ORA-06502 raised INSIDE this handler would escape the inner
            -- block to the outer one, roll everything back and return
            -- approved:0 -- reinstating the exact bug this loop exists to fix.
            v_err  := SUBSTR(REPLACE(REPLACE(SQLERRM,
                        'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"'),
                        1, 400);
            -- Name the employee. "A manager's own time is approved by their
            -- reporting manager" is useless in a batch of ten without it.
            IF LENGTH(v_detail) IS NULL OR LENGTH(v_detail) < 2400 THEN
              v_detail := v_detail
                       || CASE WHEN v_detail IS NULL THEN '' ELSE ', ' END
                       || e.emp || ': ' || RTRIM(v_err, CHR(10));
            END IF;
          END;
        END LOOP;

        -- Committed even when some were skipped: the ones that worked are real
        -- decisions and throwing them away helps nobody.
        COMMIT;

        -- 400 only when nothing at all went through. A partial success is a
        -- success with a caveat, and the UI needs the successes to refresh.
        :status_code := CASE WHEN v_done = 0 AND v_skip > 0 THEN 400 ELSE 200 END;
        HTP.P('{"approved":' || v_done ||
              ',"skipped":' || v_skip ||
              CASE WHEN v_detail IS NULL THEN ''
                   ELSE ',"error":"' || v_detail || '"' END || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"approved":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
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
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text, not named binds. A payload carrying a JSON ARRAY cannot be
        -- bound field by field - ORDS has no SQL type for the array, so the
        -- whole request fails with ORA-17004 before any of this runs and the
        -- caller only sees "The request could not be processed for a user
        -- defined resource". Path parameters are unaffected.
        v_body   CLOB := :body_text;
        v_proj    NUMBER;
        v_period  NUMBER;
        v_reason  VARCHAR2(20);
        v_remarks VARCHAR2(1000);
        v_aeid    VARCHAR2(50);
        v_actor   VARCHAR2(100);
        v_trace   VARCHAR2(64);
        v_done    NUMBER := 0;
        -- Same isolation as approve/month: one refused employee must not undo
        -- the rest of the batch. RULE-015 applies to a rejection too, so a
        -- manager rejecting their whole team hit exactly the same wall.
        v_skip    NUMBER := 0;
        v_err     VARCHAR2(500);
        v_detail  VARCHAR2(3000);
      BEGIN
        SELECT proj, per, rsn, rmk, aeid, NVL(act,'VBCS_USER'), tr
          INTO v_proj, v_period, v_reason, v_remarks, v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (proj NUMBER         PATH '$.projectId',
                          per  NUMBER         PATH '$.periodId',
                          rsn  VARCHAR2(20)   PATH '$.reason',
                          rmk  VARCHAR2(1000) PATH '$.remarks',
                          aeid VARCHAR2(50)   PATH '$.actorEmpId',
                          act  VARCHAR2(100)  PATH '$.actor',
                          tr   VARCHAR2(64)   PATH '$.traceId'));

        FOR e IN (SELECT emp FROM JSON_TABLE(v_body, '$.employees[*]'
                                COLUMNS (emp VARCHAR2(50) PATH '$'))) LOOP
          BEGIN
            oc_time_pkg.reject_employee_month(
              p_project_id   => v_proj,
              p_period_id    => v_period,
              p_employee_id  => e.emp,
              p_reason       => v_reason,
              p_remarks      => v_remarks,
              p_actor_emp_id => v_aeid,
              p_actor        => v_actor,
              p_trace_id     => v_trace);
            v_done := v_done + 1;
          EXCEPTION WHEN OTHERS THEN
            v_skip := v_skip + 1;
            -- SUBSTR guards the handler itself: an ORA-06502 raised here would
            -- escape to the outer block and roll the batch back.
            v_err  := SUBSTR(REPLACE(REPLACE(SQLERRM,
                        'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"'),
                        1, 400);
            IF LENGTH(v_detail) IS NULL OR LENGTH(v_detail) < 2400 THEN
              v_detail := v_detail
                       || CASE WHEN v_detail IS NULL THEN '' ELSE ', ' END
                       || e.emp || ': ' || RTRIM(v_err, CHR(10));
            END IF;
          END;
        END LOOP;
        COMMIT;
        :status_code := CASE WHEN v_done = 0 AND v_skip > 0 THEN 400 ELSE 200 END;
        HTP.P('{"rejected":' || v_done ||
              ',"skipped":' || v_skip ||
              CASE WHEN v_detail IS NULL THEN ''
                   ELSE ',"error":"' || v_detail || '"' END || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"rejected":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text, not named binds. A payload carrying a JSON ARRAY cannot be
        -- bound field by field - ORDS has no SQL type for the array, so the
        -- whole request fails with ORA-17004 before any of this runs and the
        -- caller only sees "The request could not be processed for a user
        -- defined resource". Path parameters are unaffected.
        v_body   CLOB := :body_text;
        v_aeid   VARCHAR2(50);
        v_actor  VARCHAR2(100);
        v_trace  VARCHAR2(64);
        v_done   NUMBER := 0;
        v_status VARCHAR2(30);
      BEGIN
        SELECT aeid, NVL(act,'VBCS_USER'), tr
          INTO v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (aeid VARCHAR2(50)  PATH '$.actorEmpId',
                          act  VARCHAR2(100) PATH '$.actor',
                          tr   VARCHAR2(64)  PATH '$.traceId'));

        -- 30 not 10: toApiDate() appends T00:00:00Z; SUBSTR below trims it.
        FOR d IN (SELECT dt FROM JSON_TABLE(v_body, '$.dates[*]'
                                COLUMNS (dt VARCHAR2(30) PATH '$'))) LOOP
          oc_time_pkg.approve_day(:id, TO_DATE(SUBSTR(d.dt,1,10),'YYYY-MM-DD'),
                                  v_aeid, v_actor, v_trace);
          v_done := v_done + 1;
        END LOOP;
        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :id;
        COMMIT; :status_code := 200;
        HTP.P('{"approvedDates":' || v_done || ',"weekStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"approvedDates":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST revoke/week/:id  (undo every decision on a week) ───
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'revoke/week/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'revoke/week/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        v_body   CLOB := :body_text;
        v_aeid   VARCHAR2(50);
        v_actor  VARCHAR2(100);
        v_trace  VARCHAR2(64);
        v_status VARCHAR2(30);
      BEGIN
        SELECT aeid, NVL(act,'VBCS_USER'), tr
          INTO v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (aeid VARCHAR2(50)  PATH '$.actorEmpId',
                          act  VARCHAR2(100) PATH '$.actor',
                          tr   VARCHAR2(64)  PATH '$.traceId'));

        oc_time_pkg.revoke_week_decision(:id, v_aeid, v_actor, v_trace);

        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :id;
        COMMIT; :status_code := 200;
        HTP.P('{"revoked":true,"weekStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"revoked":false,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST revoke/day/:id  (undo a day decision) ────────────
-- Same array-of-dates shape as approve/day and reject/day, because it undoes
-- exactly what those two do and the screen selects dates the same way.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'revoke/day/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'revoke/day/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text, not named binds - a JSON array cannot be bound by name.
        v_body   CLOB := :body_text;
        v_aeid   VARCHAR2(50);
        v_actor  VARCHAR2(100);
        v_trace  VARCHAR2(64);
        v_done   NUMBER := 0;
        v_status VARCHAR2(30);
      BEGIN
        SELECT aeid, NVL(act,'VBCS_USER'), tr
          INTO v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (aeid VARCHAR2(50)  PATH '$.actorEmpId',
                          act  VARCHAR2(100) PATH '$.actor',
                          tr   VARCHAR2(64)  PATH '$.traceId'));

        -- 30 not 10: toApiDate() appends T00:00:00Z; SUBSTR below trims it.
        FOR d IN (SELECT dt FROM JSON_TABLE(v_body, '$.dates[*]'
                                COLUMNS (dt VARCHAR2(30) PATH '$'))) LOOP
          oc_time_pkg.revoke_decision(:id, TO_DATE(SUBSTR(d.dt,1,10),'YYYY-MM-DD'),
                                      v_aeid, v_actor, v_trace);
          v_done := v_done + 1;
        END LOOP;
        SELECT week_status INTO v_status FROM oc_ts_week WHERE ts_week_id = :id;
        COMMIT; :status_code := 200;
        HTP.P('{"revokedDates":' || v_done || ',"weekStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"revokedDates":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval', p_pattern => 'reject/day/:id');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'reject/day/:id',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text, not named binds. A payload carrying a JSON ARRAY cannot be
        -- bound field by field - ORDS has no SQL type for the array, so the
        -- whole request fails with ORA-17004 before any of this runs and the
        -- caller only sees "The request could not be processed for a user
        -- defined resource". Path parameters are unaffected.
        v_body   CLOB := :body_text;
        v_reason  VARCHAR2(20);
        v_remarks VARCHAR2(1000);
        v_aeid    VARCHAR2(50);
        v_actor   VARCHAR2(100);
        v_trace   VARCHAR2(64);
        v_done    NUMBER := 0;
      BEGIN
        SELECT rsn, rmk, aeid, NVL(act,'VBCS_USER'), tr
          INTO v_reason, v_remarks, v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (rsn  VARCHAR2(20)   PATH '$.reason',
                          rmk  VARCHAR2(1000) PATH '$.remarks',
                          aeid VARCHAR2(50)   PATH '$.actorEmpId',
                          act  VARCHAR2(100)  PATH '$.actor',
                          tr   VARCHAR2(64)   PATH '$.traceId'));

        FOR d IN (SELECT dt FROM JSON_TABLE(v_body, '$.dates[*]'
                                COLUMNS (dt VARCHAR2(30) PATH '$'))) LOOP
          oc_time_pkg.reject_day(:id, TO_DATE(SUBSTR(d.dt,1,10),'YYYY-MM-DD'),
                                 v_reason, v_remarks, v_aeid, v_actor, v_trace);
          v_done := v_done + 1;
        END LOOP;
        COMMIT; :status_code := 200;
        HTP.P('{"rejectedDates":' || v_done || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"rejectedDates":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text, not named binds. A payload carrying a JSON ARRAY cannot be
        -- bound field by field - ORDS has no SQL type for the array, so the
        -- whole request fails with ORA-17004 before any of this runs and the
        -- caller only sees "The request could not be processed for a user
        -- defined resource". Path parameters are unaffected.
        v_body   CLOB := :body_text;
        v_proj   NUMBER;
        v_period NUMBER;
        v_aeid   VARCHAR2(50);
        v_actor  VARCHAR2(100);
        v_trace  VARCHAR2(64);
        v_count  NUMBER;
        v_done   NUMBER := 0;
      BEGIN
        SELECT proj, per, aeid, NVL(act,'VBCS_USER'), tr
          INTO v_proj, v_period, v_aeid, v_actor, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (proj NUMBER        PATH '$.projectId',
                          per  NUMBER        PATH '$.periodId',
                          aeid VARCHAR2(50)  PATH '$.actorEmpId',
                          act  VARCHAR2(100) PATH '$.actor',
                          tr   VARCHAR2(64)  PATH '$.traceId'));

        -- "employees omitted" is an empty row set now, not a NULL bind.
        SELECT COUNT(*) INTO v_count
          FROM JSON_TABLE(v_body, '$.employees[*]'
                 COLUMNS (emp VARCHAR2(50) PATH '$'));

        IF v_count = 0 THEN
          -- Whole project month.
          oc_time_pkg.advance_approve_month(
            v_proj, v_period, NULL, v_aeid, v_actor, v_trace);
          v_done := 1;
        ELSE
          FOR e IN (SELECT emp FROM JSON_TABLE(v_body, '$.employees[*]'
                                  COLUMNS (emp VARCHAR2(50) PATH '$'))) LOOP
            oc_time_pkg.advance_approve_month(
              v_proj, v_period, e.emp, v_aeid, v_actor, v_trace);
            v_done := v_done + 1;
          END LOOP;
        END IF;
        COMMIT; :status_code := 200;
        HTP.P('{"advanceApproved":' || v_done || ',"flag":"Advance closure"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"advanceApproved":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
             absence_date, absence_day, absence_type,
             -- BOTH, and they mean different things. ABSENCE_HOURS is the
             -- whole absence as Absence Management recorded it; LOSS_HOURS is
             -- this project's share of it -- allocation x shift x the fraction
             -- of the day the absence took -- which for a 25% allocation on an
             -- 8-hour shift is 2. PAGE-006 is a per-project screen, so it shows
             -- LOSS_HOURS and keeps ABSENCE_HOURS as the sub-line.
             --
             -- SCREEN ONLY. Coverage moves no hours and puts no number on the
             -- invoice; the annexure names people and dates, and the invoice's
             -- hours come from the monthly summary. This tells the manager how
             -- much capacity they are covering, nothing more.
             absence_hours, loss_hours,
             -- 'N' when the absence behind this line has since been withdrawn.
             -- Only an APPROVED line can be in that state: db/96 deletes the
             -- Open and Assigned ones and keeps the approved, because that is a
             -- manager's decision to revoke rather than ours to erase. The
             -- annexure already drops it; the screen has to SAY so, or the
             -- orphan is invisible and nobody revokes anything.
             absence_exists,
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
      DECLARE
        v_n   NUMBER;
        v_rem NUMBER;
        v_orp NUMBER;
      BEGIN
        -- RETRACT FIRST. "Rebuild the absentee list" has to mean both halves:
        -- generate_llc_lines only ever INSERTs, so before db/96 a withdrawn
        -- absence left its coverage line standing -- assignable, and if already
        -- Approved, on the invoice annexure naming somebody as covering a day
        -- nobody was away. Open and Assigned lines go; Approved ones are a
        -- manager's decision and are only counted, having already dropped off
        -- the annexure.
        oc_time_retract_llc(:projectId, :periodId,
                            NVL(:actor,'VBCS_USER'), v_rem, v_orp);

        v_n := oc_time_pkg.generate_llc_lines(:projectId, :periodId,
                                              NVL(:actor,'VBCS_USER'));
        COMMIT; :status_code := 200;
        HTP.P('{"linesCreated":' || v_n
              || ',"linesRemoved":' || v_rem
              || ',"approvedOrphans":' || v_orp || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"linesCreated":0,"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- GET llc/roster/:projectId/:periodId
--
-- WHO THE LIVE HR READ HAS TO ASK ABOUT. PAGE-006's "Refresh absences from HR"
-- used to call llc/generate straight away, which reads OC_TIME_ABSENCE -- our
-- CACHE. So leave applied in Fusion did not appear until either the nightly
-- feed ran or the absent person happened to open their own timesheet, and on
-- 20-Aug a real absence booked for RI2894 was invisible to their manager for
-- exactly that reason. The page now reads Fusion first, the same way PAGE-001
-- does, and this answers the question that read has to start from.
--
-- ANCHORED ON THE ALLOCATION, not on OC_TS_WEEK. V_OC_TS_MONTH_SUMMARY joins
-- through OC_TS_ENTRY, so it can only list people who already have timesheet
-- rows -- and someone newly allocated, or absent before anything was populated
-- for them, is precisely who gets missed. Allocation is the statement that
-- this person is on this project.
--
-- STD_HOURS_PER_DAY travels with each row because a Fusion absence header is
-- measured in DAYS. Turning half a day into hours needs that person's own
-- standard day; several people here are on nine and a global 8 would
-- understate their leave.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'llc/roster/:projectId/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval',
    p_pattern => 'llc/roster/:projectId/:periodId', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT al.employee_id,
             w.employee_name,
             NVL(w.std_hours_per_day, 8) AS std_hours_per_day,
             al.alloc_pct, al.billing_status,
             -- The window travels with the roster so the page needs one call,
             -- not two, and cannot pair this month's people with last month's
             -- dates.
             TO_CHAR(pe.start_date,'YYYY-MM-DD') AS window_from,
             TO_CHAR(pe.end_date,  'YYYY-MM-DD') AS window_to
        FROM oc_time_allocation al
        JOIN oc_time_worker  w  ON w.employee_id = al.employee_id
        JOIN oc_time_period  pe ON pe.period_id  = :periodId
       WHERE al.project_id = :projectId
         AND al.status     = 'Active'
         -- OVERLAP, not containment: an allocation that ended mid-month still
         -- had days in it, and leave taken on those days is still this
         -- project's loss.
         AND al.start_date          <= pe.end_date
         AND NVL(al.end_date, pe.end_date) >= pe.start_date
       ORDER BY w.employee_name
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
        -- OC_TIME_APPROVE_COVER, not OC_TIME_PKG.APPROVE_COVER. The wrapper
        -- adds the one guard PROC-006 states -- coverage is recorded before the
        -- finance cut-off, so a confirmed month refuses.
        --
        -- IT MOVES NO HOURS, and nor does anything else. Between 20-Aug and
        -- 20-Aug this endpoint returned "hoursBilled", read back from a column
        -- db/84 wrote when it shifted the cover's time onto a billable task.
        -- That premise was retracted by the functional owner: the covering
        -- colleague's hours stay unbilled, the absentee's leave stays in the
        -- leave column, and the coverage is a statement of who covered whom in
        -- the invoice annexure. Reporting an hours figure here would invite
        -- exactly the reading that caused the trouble.
        oc_time_approve_cover(:id, :actorEmpId, NVL(:actor,'VBCS_USER'));

        COMMIT; :status_code := 200;
        HTP.P('{"llcId":' || :id || ',"llcStatus":"Approved"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── Salary stopping, day-wise (PROC-007, revised 10-Aug-2026) ─
-- GET salaryhold/queue/:managerId — only corrections waiting on a decision. A
-- queue that lists everything ever held is a report, not a queue, and stops
-- being opened.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'salaryhold/queue/:managerId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval', p_pattern => 'salaryhold/queue/:managerId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT hold_day_id, employee_id, employee_name, worker_type,
             period_id, period_name, work_date, expected_hours,
             corrected_hours, correction_reason, corrected_on, ts_week_id
        FROM v_oc_ts_salary_hold_queue
       WHERE manager_emp_id = :managerId
       ORDER BY employee_name, work_date
    ]');
  COMMIT;
END;
/

-- POST salaryhold/day/:holdDayId/decide — approve or reject one corrected date.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.approval',
                       p_pattern => 'salaryhold/day/:holdDayId/decide');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.approval',
    p_pattern => 'salaryhold/day/:holdDayId/decide', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(20); v_hold NUMBER; v_sal VARCHAR2(20);
      BEGIN
        oc_time_pkg.decide_salary_hold_day(
          p_hold_day_id  => :holdDayId,
          p_approve      => NVL(:approve,'N'),
          p_remarks      => :remarks,
          p_actor_emp_id => :actorEmpId,
          p_actor        => NVL(:actor,'VBCS_USER'));
        SELECT d.day_status, d.hold_id, h.salary_status
          INTO v_status, v_hold, v_sal
          FROM oc_ts_salary_hold_day d
          JOIN oc_ts_salary_hold h ON h.hold_id = d.hold_id
         WHERE d.hold_day_id = :holdDayId;
        COMMIT;
        :status_code := 200;
        HTP.P('{"holdDayId":' || :holdDayId || ',"dayStatus":"' || v_status ||
              '","holdId":' || v_hold || ',"salaryStatus":"' || v_sal || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001 THEN 400 ELSE 500 END;
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
      -- v_oc_ts_week_activity, not v_oc_ts_audit_trail: the audit table records
      -- only changes to VALUES, so approvals and rejections - which change no
      -- value and write to OC_TS_APPROVAL - were invisible here, and a week that
      -- had just been rejected reported that nothing had happened to it.
      -- The view carries ts_week_id, so the EXISTS this used to need is gone.
      SELECT a.activity_id AS audit_id, a.kind, a.scope,
             a.employee_id, a.employee_name, a.entry_date,
             a.change_type,
             a.old_project_name, a.old_task_code, a.old_hours,
             a.new_project_name, a.new_task_code, a.new_hours, a.delta_hours,
             a.change_reason, a.changed_by, a.changed_on
        FROM v_oc_ts_week_activity a
       WHERE a.ts_week_id = :tsWeekId
       ORDER BY a.changed_on DESC, a.activity_id DESC
    ]');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT ORDS module oc.time.approval defined.
PROMPT ============================================================
