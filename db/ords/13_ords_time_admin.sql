--==============================================================
-- time/ords/13_ords_time_admin.sql
-- O2C Timesheet Module — ORDS module oc.time.admin  (ADMIN + ACCRUAL surface)
--
-- Base path: /oc/time/admin/
-- Persona:   PER-004 Finance / Admin, plus the accrual application's pull.
--
-- Two audiences share this module because both are privileged, non-user-facing
-- surfaces:
--   * PAGE-009 Calendar sync, PAGE-010 Sync status, PAGE-011 Accrual
--     integration, PAGE-012 Integration reference;
--   * the hand-off to the main O2C application. Its timesheet -> accrual chain
--     already exists, so on confirmation we PUSH the consolidated month into
--     OC_TIMESHEET_HEADER / OC_TIMESHEET_LINE through its own import API and it
--     generates the accrual. The push/* endpoints below serve exactly the two
--     payloads that API expects. This replaces the RitePulse feed.
--
--   * the older accrual PULL from XX_O2C_TIMESHEET_ACCRUAL_IF, kept because the
--     interface table is now the staging set the push reads from - Reversal rows
--     are stored negative there, so a SUM nets a retro correction with no sign
--     handling - and because a second consumer may still want to pull.
--
-- Period Control is exposed READ-ONLY. PAGE-008 was removed as an admin screen
-- on 29-Jul and is reference data maintained outside the app, but the cut-off
-- dates still drive the employee display and the manager panel, so the app must
-- be able to read them. Writes are deliberately absent.
--
-- Endpoints
--   GET  periods                                 period control (read-only)
--   GET  calendar/layers                         the four layer cards
--   GET  calendar/:layer/:scopeKey/:from/:to     calendar days for a layer
--   POST calendar/sync/:layer                    upsert a layer from Fusion
--   GET  sync/status                             job cards
--   GET  poet/readiness                          what blocks the OTL push
--   GET  sync/failed                             failed-record queue
--   POST sync/retry/:failedId                    retry one failed record
--   POST jobs/populate/:periodId                 run the monthly population job
--   POST jobs/daily                              run the daily action-date job
--   POST jobs/defaulting/:periodId               weekly cut-off  (employee)
--   POST jobs/delivery-defaulting/:periodId      delivery cut-off (manager)
--   GET  accrual/confirmed/:periodId             confirmed months
--   GET  accrual/extract/:confirmId              day-wise extract
--   GET  accrual/annexure/:periodId              leave-loss invoice annexure
--   GET  accrual/pull/:periodYear/:periodMonth   *** accrual PULLS here ***
--   POST accrual/ack/:batchId                    accrual acknowledges a batch
--   GET  push/header/:confirmId                  main O2C hand-off, per employee
--   GET  push/line/:confirmId/:employeeId        main O2C hand-off, per day
--   POST push/ack/:confirmId                     pusher reports the outcome
--   GET  integrations                            PAGE-012 reference catalogue
--   GET  compliance/:periodId                    status dashboard (REP-005)
--   GET  config                                  business configuration
--
-- Depends on: time/01 .. time/10
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

BEGIN ORDS.DELETE_MODULE(p_module_name => 'oc.time.admin'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time.admin',
    p_base_path      => '/oc/time/admin/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'O2C Timesheet - admin surface (calendar, sync, accrual hand-off) + accrual pull.');
  COMMIT;
END;
/

-- ── GET periods  (read-only; PAGE-008 is reference data) ─────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'periods');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'periods', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT period_id, period_name, period_year, period_month, status,
             payroll_country, start_date, end_date, accounting_date,
             ts_cutoff_day, ts_cutoff_time, weekly_cutoff_display,
             delivery_cutoff, finance_cutoff, book_closure, mec_close,
             client_cutoff, payroll_cutoff, advance_close,
             adjustment_months, backdated_months,
             hold_release_days, contractor_resubmit_days
        FROM v_oc_time_cutoffs
       ORDER BY period_year DESC, period_month DESC
    ]');
  COMMIT;
END;
/

-- ── GET calendar/layers  (PAGE-009 cards) ────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'calendar/layers');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'calendar/layers',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT layer, layer_label, source_description, precedence,
             day_count, scope_count, from_date, to_date,
             source_system, last_synced_on, non_working_days
        FROM v_oc_time_calendar_ui
       ORDER BY precedence DESC
    ]');
  COMMIT;
END;
/

-- ── GET calendar/:layer/:scopeKey/:from/:to ──────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'calendar/:layer/:scopeKey/:fromDate/:toDate');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin',
    p_pattern => 'calendar/:layer/:scopeKey/:fromDate/:toDate', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT calendar_id, layer, precedence, scope_key,
             TO_CHAR(cal_date,'YYYY-MM-DD') AS cal_date,
             TO_CHAR(cal_date,'DY')         AS day_name,
             is_working_day, std_hours, holiday_name, shift_code,
             source_system,
             TO_CHAR(synced_on,'YYYY-MM-DD HH24:MI') AS synced_on
        FROM oc_time_calendar
       WHERE layer     = UPPER(:layer)
         AND scope_key = :scopeKey
         AND cal_date BETWEEN TO_DATE(:fromDate,'YYYY-MM-DD')
                          AND TO_DATE(:toDate,'YYYY-MM-DD')
       ORDER BY cal_date
    ]');
  COMMIT;
END;
/

-- ── POST calendar/sync/:layer  (ACT-030) ─────────────────────
-- OIC posts the Fusion-sourced days for one layer as a JSON array. Upsert on
-- (layer, scope_key, cal_date) so a re-sync is idempotent. PRECEDENCE is set by
-- TRG_OC_TC_PRECEDENCE, so callers never supply it and cannot get it wrong.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'calendar/sync/:layer');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'calendar/sync/:layer',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
      DECLARE
        v_job   NUMBER;
        v_n     NUMBER := 0;
        v_layer VARCHAR2(12) := UPPER(:layer);
      BEGIN
        IF v_layer NOT IN ('CORPORATE','PROJECT','CLIENT','SHIFT') THEN
          :status_code := 400;
          HTP.P('{"error":"Layer must be CORPORATE, PROJECT, CLIENT or SHIFT."}');
          RETURN;
        END IF;

        INSERT INTO oc_time_sync_job (
          job_name, job_type, scope_key, job_status, triggered_by, trace_id)
        VALUES ('Calendar Sync - ' || v_layer, 'CalendarSync', v_layer,
                'Running', NVL(:actor,'VBCS_USER'), SYS_GUID())
        RETURNING job_run_id INTO v_job;

        FOR d IN (SELECT scope_key, cal_date, is_working_day, std_hours,
                         holiday_name, shift_code
                    FROM JSON_TABLE(TO_CLOB(:days), '$[*]'
                           COLUMNS (
                             scope_key      VARCHAR2(120) PATH '$.scopeKey',
                             cal_date       VARCHAR2(10)  PATH '$.calDate',
                             is_working_day VARCHAR2(1)   PATH '$.isWorkingDay',
                             std_hours      NUMBER        PATH '$.stdHours',
                             holiday_name   VARCHAR2(200) PATH '$.holidayName',
                             shift_code     VARCHAR2(20)  PATH '$.shiftCode')))
        LOOP
          MERGE INTO oc_time_calendar c
          USING (SELECT v_layer AS layer, d.scope_key AS scope_key,
                        TO_DATE(d.cal_date,'YYYY-MM-DD') AS cal_date FROM dual) s
             ON (c.layer = s.layer AND c.scope_key = s.scope_key
             AND c.cal_date = s.cal_date)
           WHEN MATCHED THEN UPDATE
                SET c.is_working_day = NVL(d.is_working_day,'Y'),
                    c.std_hours      = d.std_hours,
                    c.holiday_name   = d.holiday_name,
                    c.shift_code     = d.shift_code,
                    c.source_system  = 'FUSION',
                    c.synced_on      = SYSTIMESTAMP,
                    c.updated_by     = NVL(:actor,'VBCS_USER')
           WHEN NOT MATCHED THEN
                INSERT (layer, precedence, scope_key, cal_date, is_working_day,
                        std_hours, holiday_name, shift_code, source_system,
                        synced_on, created_by)
                VALUES (v_layer, 1, d.scope_key,
                        TO_DATE(d.cal_date,'YYYY-MM-DD'),
                        NVL(d.is_working_day,'Y'), d.std_hours, d.holiday_name,
                        d.shift_code, 'FUSION', SYSTIMESTAMP,
                        NVL(:actor,'VBCS_USER'));
          v_n := v_n + 1;
        END LOOP;

        UPDATE oc_time_sync_job
           SET job_status = 'Success', finished_on = SYSTIMESTAMP,
               records_read = v_n, records_upserted = v_n,
               message = v_layer || ' layer synced.'
         WHERE job_run_id = v_job;

        COMMIT; :status_code := 200;
        HTP.P('{"layer":"' || v_layer || '","daysSynced":' || v_n ||
              ',"jobRunId":' || v_job || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── GET sync/status  (PAGE-010 job cards) ────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/status');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/status', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT job_run_id, job_name, job_type, scope_key, period_name, action_date,
             job_status, started_on, last_run, duration_ms,
             records_read, records_upserted, records_failed, open_failures,
             message, trace_id, triggered_by
        FROM v_oc_time_sync_status
       ORDER BY started_on DESC
    ]');
  COMMIT;
END;
/

-- ── GET sync/failed ──────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/failed');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/failed', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT failed_id, job_run_id, job_name, job_type,
             entity_type, entity_key, employee_id, employee_name,
             failure_reason, failure_code, retry_count, resolved_flag,
             first_seen_on, last_retry_on, resolved_by, resolved_on, trace_id
        FROM v_oc_time_sync_failed
       WHERE (:resolved IS NULL OR resolved_flag = :resolved)
       ORDER BY resolved_flag, first_seen_on DESC
    ]');
  COMMIT;
END;
/

-- ── POST sync/retry/:failedId  (ACT-032) ─────────────────────
-- Re-runs population for just the failed record's employee. If the underlying
-- cause is fixed (allocation created, shift calendar loaded) the record
-- resolves; otherwise the retry count climbs and it stays in the queue.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/retry/:failedId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/retry/:failedId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE
        v_emp    VARCHAR2(50);
        v_period NUMBER;
        v_job    NUMBER;
        v_still  NUMBER;
      BEGIN
        SELECT employee_id INTO v_emp
          FROM oc_time_sync_failed WHERE failed_id = :failedId;

        UPDATE oc_time_sync_failed
           SET retry_count = retry_count + 1, last_retry_on = SYSTIMESTAMP
         WHERE failed_id = :failedId;

        IF v_emp IS NULL THEN
          COMMIT; :status_code := 200;
          HTP.P('{"failedId":' || :failedId ||
                ',"retried":false,"message":"No employee on this record; resolve at source."}');
          RETURN;
        END IF;

        v_period := oc_time_pkg.get_open_period_id;
        v_job    := oc_time_pkg.populate_month(v_period, v_emp,
                                               NVL(:actor,'VBCS_USER'));

        -- Did the retry produce a fresh failure for the same employee?
        SELECT COUNT(*) INTO v_still
          FROM oc_time_sync_failed
         WHERE job_run_id  = v_job
           AND employee_id = v_emp
           AND resolved_flag = 'N';

        IF v_still = 0 THEN
          UPDATE oc_time_sync_failed
             SET resolved_flag = 'Y', resolved_on = SYSTIMESTAMP,
                 resolved_by   = NVL(:actor,'VBCS_USER')
           WHERE failed_id = :failedId;
        END IF;

        COMMIT; :status_code := 200;
        HTP.P('{"failedId":' || :failedId || ',"jobRunId":' || v_job ||
              ',"resolved":' || CASE WHEN v_still = 0 THEN 'true' ELSE 'false' END || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST jobs/populate/:periodId  (ACT-031) ──────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'jobs/populate/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'jobs/populate/:periodId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_job NUMBER; v_read NUMBER; v_up NUMBER; v_fail NUMBER;
      BEGIN
        v_job := oc_time_pkg.populate_month(:periodId, :employeeId,
                                            NVL(:actor,'VBCS_USER'));
        SELECT records_read, records_upserted, records_failed
          INTO v_read, v_up, v_fail
          FROM oc_time_sync_job WHERE job_run_id = v_job;
        :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"read":' || v_read ||
              ',"upserted":' || v_up || ',"failed":' || v_fail || '}');
      EXCEPTION WHEN OTHERS THEN
        :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST jobs/daily ──────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'jobs/daily');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'jobs/daily', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_job NUMBER;
      BEGIN
        v_job := oc_time_pkg.populate_daily(
                   NVL(TO_DATE(:actionDate,'YYYY-MM-DD'), TRUNC(SYSDATE)),
                   :scopeKey, NVL(:actor,'VBCS_USER'));
        :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || '}');
      EXCEPTION WHEN OTHERS THEN
        :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── POST jobs/defaulting/:periodId  (RULE-006) ───────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'jobs/defaulting/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'jobs/defaulting/:periodId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_job NUMBER; v_up NUMBER;
      BEGIN
        v_job := oc_time_pkg.run_weekly_defaulting(
                   :periodId,
                   NVL(TO_DATE(:asOf,'YYYY-MM-DD'), SYSDATE),
                   NVL(:actor,'VBCS_USER'));
        SELECT records_upserted INTO v_up
          FROM oc_time_sync_job WHERE job_run_id = v_job;
        :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"defaulted":' || v_up || '}');
      EXCEPTION WHEN OTHERS THEN
        :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── GET poet/readiness  (INT-007 prerequisite) ───────────────
-- What is stopping the OTL push, per project. Read-only: fixing a gap means
-- setting an expenditure type or organization in Fusion, not here.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'poet/readiness');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'poet/readiness',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'~
      SELECT project_id, project_number, project_name, project_status,
             tasks_chargeable, tasks_no_exp_type,
             workers_allocated, workers_no_exp_org,
             otl_readiness
        FROM v_oc_time_poet_readiness
       ORDER BY CASE otl_readiness WHEN 'Blocked' THEN 0 ELSE 1 END,
                project_number
    ~');
  COMMIT;
END;
/

-- ── POST jobs/delivery-defaulting/:periodId  (RULE-007) ──────
-- The manager side of the pair. Kept as its own endpoint rather than a flag on
-- the one above because the two run on different schedules — weekly, against
-- each week's own cut-off, versus once when the month's delivery cut-off passes
-- — and because they must be separately re-runnable when one of them fails.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'jobs/delivery-defaulting/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin',
    p_pattern => 'jobs/delivery-defaulting/:periodId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
      DECLARE v_job NUMBER; v_up NUMBER;
      BEGIN
        v_job := oc_time_pkg.run_delivery_defaulting(
                   :periodId,
                   NVL(TO_DATE(:asOf,'YYYY-MM-DD'), SYSDATE),
                   NVL(:actor,'VBCS_USER'));
        SELECT records_upserted INTO v_up
          FROM oc_time_sync_job WHERE job_run_id = v_job;
        :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"defaulted":' || v_up || '}');
      EXCEPTION WHEN OTHERS THEN
        :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST jobs/accrual/:periodId  (ACT-033) ───────────────────
-- Posts retro adjustments approved after their month was confirmed. Safe to
-- run repeatedly: the insert guards on (confirm_id, source_ts_id, entry_type),
-- so a second run posts nothing.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'jobs/accrual/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'jobs/accrual/:periodId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
      DECLARE v_job NUMBER; v_rows NUMBER; v_read NUMBER;
      BEGIN
        v_job := oc_time_pkg.run_accrual_top_up(
                   :periodId, NVL(:actor,'VBCS_USER'), :traceId);
        SELECT records_read, records_upserted INTO v_read, v_rows
          FROM oc_time_sync_job WHERE job_run_id = v_job;
        :status_code := 200;
        HTP.P('{"jobRunId":' || v_job ||
              ',"monthsChecked":' || v_read ||
              ',"rowsPosted":'    || v_rows || '}');
      EXCEPTION WHEN OTHERS THEN
        :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── GET accrual/confirmed/:periodId  (PAGE-011) ──────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'accrual/confirmed/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'accrual/confirmed/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT confirm_id, project_id, project_number, project_name, customer_name,
             revenue_model, period_id, period_name, period_year, period_month,
             employee_count, billable_hours, non_billable_hours, leave_hours,
             adjustment_hours, confirm_type, confirmed_by, confirmed_on,
             otl_status, otl_pushed_on, otl_message,
             accrual_status, accrual_rows, accrual_pushed_on, accrual_message,
             partner_status, rows_pulled, rows_pending, trace_id
        FROM v_oc_ts_confirmed_months
       WHERE period_id = :periodId
       ORDER BY project_name
    ]');
  COMMIT;
END;
/

-- ── GET accrual/extract/:confirmId  (REP-001 day-wise) ───────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'accrual/extract/:confirmId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'accrual/extract/:confirmId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT if_id, period, employee_id, employee_name, worker_type,
             project_number, project_name, wbs_task, wbs_task_name, wbs_date,
             work_date, billed, unbilled, leave_hours, unbilled_reason,
             entry_type, approval, flag, action_date,
             batch_id, processed_flag, pulled_on, source_ts_id, source_adj_id
        FROM v_oc_ts_accrual_extract
       WHERE confirm_id = :confirmId
       ORDER BY employee_name, work_date, wbs_task, entry_type
    ]');
  COMMIT;
END;
/

-- ── GET accrual/annexure/:periodId  (REP-002) ────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'accrual/annexure/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'accrual/annexure/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT llc_id, project_number, project_name, customer_name, revenue_model,
             period_name, absent_employee_id, absent_employee_name,
             absence_date, absence_type, covered_billed_hours,
             cover_employee_id, cover_employee_name,
             llc_status, billed_flag, approved_by, approved_on
        FROM v_oc_ts_llc_annexure
       WHERE period_id = :periodId
       ORDER BY project_name, absence_date, absent_employee_name
    ]');
  COMMIT;
END;
/

-- ══════════════════════════════════════════════════════════════
-- THE ACCRUAL PULL
-- ══════════════════════════════════════════════════════════════

-- ── GET accrual/pull/:periodYear/:periodMonth ────────────────
-- The O2C accrual application calls this after month-end manager approval to
-- take the consolidated timesheet + day-wise adjustments. Only unprocessed rows
-- are served, so the pull is naturally resumable and never double-counts. The
-- consumer then POSTs accrual/ack/:batchId for each batch it has stored.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin',
                       p_pattern => 'accrual/pull/:periodYear/:periodMonth');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin',
    p_pattern => 'accrual/pull/:periodYear/:periodMonth', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT i.if_id,
             i.batch_id,
             i.period,
             i.period_year,
             i.period_month,
             i.confirm_id,
             i.employee_id,
             i.employee_name,
             i.worker_type,
             i.project_number,
             i.project_name,
             i.customer_name,
             i.revenue_model,
             i.wbs_task,
             i.wbs_task_name,
             TO_CHAR(i.work_date,'YYYY-MM-DD')   AS work_date,
             i.billable_hours,
             i.non_billable_hours,
             i.leave_hours,
             i.unbilled_reason,
             i.entry_type,
             i.flag,
             TO_CHAR(i.action_date,'YYYY-MM-DD') AS action_date,
             i.source_ts_id,
             i.source_adj_id,
             i.source_system,
             i.trace_id
        FROM xx_o2c_timesheet_accrual_if i
       WHERE i.period_year   = :periodYear
         AND i.period_month  = :periodMonth
         AND i.processed_flag = 'N'
         -- Belt and braces: only rows whose month confirmation actually
         -- succeeded are ever visible to the consumer.
         AND EXISTS (SELECT 1 FROM oc_ts_month_confirm c
                      WHERE c.confirm_id     = i.confirm_id
                        AND c.accrual_status = 'Success')
       ORDER BY i.batch_id, i.employee_id, i.work_date, i.wbs_task, i.entry_type
    ]');
  COMMIT;
END;
/

-- ── POST accrual/ack/:batchId ────────────────────────────────
-- status 'Y' = stored successfully, 'E' = the consumer rejected the batch (which
-- flips the confirmation's ACCRUAL_STATUS to Failed so OBS-005 alerts).
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'accrual/ack/:batchId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'accrual/ack/:batchId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_n NUMBER;
      BEGIN
        IF NVL(:status,'Y') NOT IN ('Y','E') THEN
          :status_code := 400;
          HTP.P('{"error":"status must be Y (stored) or E (rejected)."}');
          RETURN;
        END IF;

        oc_time_pkg.mark_accrual_pulled(
          p_batch_id => :batchId,
          p_status   => NVL(:status,'Y'),
          p_message  => :message,
          p_actor    => NVL(:actor,'ACCRUAL'));

        SELECT COUNT(*) INTO v_n
          FROM xx_o2c_timesheet_accrual_if
         WHERE batch_id = :batchId AND processed_flag <> 'N';

        COMMIT; :status_code := 200;
        HTP.P('{"batchId":"' || :batchId || '","rowsAcknowledged":' || v_n || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ]');
  COMMIT;
END;
/

-- ── GET integrations  (PAGE-012) ─────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'integrations');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'integrations', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT integration_id, area, fusion_source, object_usage,
             rest_resource, load_pattern, notes
        FROM v_oc_time_integration
       ORDER BY sort_order
    ]');
  COMMIT;
END;
/

-- ── GET compliance/:periodId  (REP-005) ──────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'compliance/:periodId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'compliance/:periodId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      -- Columns follow the 30-Jul-2026 revision (7 statuses / 6 flags):
      -- 'corrections' and 'contractor_unbilled' were dropped with the
      -- CORRECTION_FLAG and CONTRACTOR_UNBILLED_FLAG columns, and the split of
      -- Defaulted by DEFAULTED_BY replaced the old 'Manager Defaulted' status.
      SELECT period_name, period_year, period_month, week_index, week_start,
             manager_emp_id, employees,
             not_submitted, submitted, approved, rejected, defaulted, late,
             employee_defaulted, manager_defaulted, closed,
             overridden, advance_closed
        FROM v_oc_ts_compliance
       WHERE period_id = :periodId
       ORDER BY week_index, manager_emp_id
    ]');
  COMMIT;
END;
/

-- ── GET config ───────────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'config');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'config', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT config_id, config_name, config_type, config_value, scope_key, description
        FROM oc_time_config
       ORDER BY config_type, config_name
    ]');
  COMMIT;
END;
/

-- ── GET push/header/:confirmId  (main O2C hand-off) ──────────
-- What the pusher POSTs to /oc/accrual/timesheet/import, one row per employee.
-- PUSH_STATE is READY or BLOCKED: a project with no MAIN_PROJECT_ID is returned
-- rather than filtered out, so a month that cannot be handed over is visible.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'push/header/:confirmId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'push/header/:confirmId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT project_id, project_number, employee_id, employee_name,
             billing_status, period_year, period_month,
             billable_hours, non_billable_hours, leave_hours,
             working_days, status, push_state
        FROM v_oc_ts_o2c_push_header
       WHERE confirm_id = :confirmId
       ORDER BY employee_id
    ]');
  COMMIT;
END;
/

-- ── GET push/line/:confirmId/:employeeId ─────────────────────
-- The day rows for one employee, POSTed to
-- /oc/accrual/timesheet/lines/import/{tsHeaderId} once the header returns its id.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'push/line/:confirmId/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'push/line/:confirmId/:employeeId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT entry_date, billable_hours, non_billable_hours, is_leave, remarks
        FROM v_oc_ts_o2c_push_line
       WHERE confirm_id = :confirmId
         AND employee_id = :employeeId
       ORDER BY entry_date
    ]');
  COMMIT;
END;
/

-- ── POST push/ack/:confirmId ─────────────────────────────────
-- The pusher reports the outcome so PAGE-011 can show whether a confirmed month
-- actually reached the main application. PARTNER_STATUS is reused for this: it
-- was reserved for exactly this second hand-off.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'push/ack/:confirmId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'push/ack/:confirmId',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'[
      DECLARE
        v_status VARCHAR2(20) := NVL(:status, 'Failed');
        v_msg    VARCHAR2(2000) := :message;
      BEGIN
        IF v_status NOT IN ('Pending','Success','Failed','Skipped') THEN
          :status_code := 400;
          HTP.P('{"error":"status must be Pending, Success, Failed or Skipped"}');
          RETURN;
        END IF;
        UPDATE oc_ts_month_confirm
           SET partner_status    = v_status,
               partner_pushed_on = SYSTIMESTAMP
         WHERE confirm_id = :confirmId;
        IF SQL%ROWCOUNT = 0 THEN
          ROLLBACK; :status_code := 404;
          HTP.P('{"error":"No confirmation with that id"}');
          RETURN;
        END IF;
        COMMIT;
        :status_code := 200;
        HTP.P('{"confirmId":' || :confirmId || ',"partnerStatus":"' || v_status || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ]');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT ORDS module oc.time.admin defined.
PROMPT ============================================================
