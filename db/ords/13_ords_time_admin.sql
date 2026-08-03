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
--   POST sync/worker                             INT-001 master upsert
--   POST sync/project                            INT-002 master upsert
--   POST sync/task                               INT-002 master upsert (POET E)
--   POST sync/allocation                         INT-003 master upsert
--   POST sync/absence                            INT-006 master upsert
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
        -- Same ORA-17004 fix as the sync/* handlers below: :days is a JSON
        -- array and cannot be bound by name.
        v_body  CLOB := :body_text;
        v_actor VARCHAR2(100);
        v_job   NUMBER;
        v_n     NUMBER := 0;
        v_layer VARCHAR2(12) := UPPER(:layer);
      BEGIN
        SELECT NVL(actor,'VBCS_USER') INTO v_actor
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (actor VARCHAR2(100) PATH '$.actor'));
        IF v_layer NOT IN ('CORPORATE','PROJECT','CLIENT','SHIFT') THEN
          :status_code := 400;
          HTP.P('{"error":"Layer must be CORPORATE, PROJECT, CLIENT or SHIFT."}');
          RETURN;
        END IF;

        INSERT INTO oc_time_sync_job (
          job_name, job_type, scope_key, job_status, triggered_by, trace_id)
        VALUES ('Calendar Sync - ' || v_layer, 'CalendarSync', v_layer,
                'Running', v_actor, SYS_GUID())
        RETURNING job_run_id INTO v_job;

        FOR d IN (SELECT scope_key, cal_date, is_working_day, std_hours,
                         holiday_name, shift_code
                    FROM JSON_TABLE(v_body, '$.days[*]'
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
                    c.updated_by     = v_actor
           WHEN NOT MATCHED THEN
                INSERT (layer, precedence, scope_key, cal_date, is_working_day,
                        std_hours, holiday_name, shift_code, source_system,
                        synced_on, created_by)
                VALUES (v_layer, 1, d.scope_key,
                        TO_DATE(d.cal_date,'YYYY-MM-DD'),
                        NVL(d.is_working_day,'Y'), d.std_hours, d.holiday_name,
                        d.shift_code, 'FUSION', SYSTIMESTAMP,
                        v_actor);
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

-- ══════════════════════════════════════════════════════════════
-- INBOUND MASTER-DATA SYNC  (INT-001 .. INT-003, INT-006)
--
-- The loader half of integration/bip. Until these existed the extracts wrote a
-- CSV and stopped: nothing carried a row into the cache, so the whole inbound
-- path ended at a file on someone's disk.
--
-- Same shape as calendar/sync/:layer above, which is the working precedent:
-- POST a JSON array, MERGE server-side, record a job. Doing the MERGE here
-- rather than in Python keeps the upsert next to the constraints it has to
-- satisfy, and means any caller — BIP loader, OIC, a manual repair — gets
-- identical behaviour.
--
-- Common contract for all five:
--   :rows      JSON array of records
--   :jobRunId  optional. Omit on the first chunk to open a job; pass the id
--              back on later chunks so a 6,000-row load is ONE job row, not
--              twelve. That is what makes the Sync Status page readable.
--   :final     'Y' on the last chunk, which closes the job.
--
-- ORDER MATTERS: worker -> project -> task -> allocation -> absence.
-- OC_TIME_ALLOCATION has foreign keys to both project and worker, and
-- OC_TIME_TASK to project. Load allocations first and every row fails.
--
-- Rows that fail land in OC_TIME_SYNC_FAILED rather than aborting the chunk —
-- one worker with a missing manager must not cost the other 5,975. The
-- existing POST sync/retry/:failedId then works on them unchanged.
-- ══════════════════════════════════════════════════════════════

-- ── POST sync/worker  (INT-001) ──────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/worker');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/worker',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text is ORDS's implicit CLOB of the whole payload. The
        -- scalars are read out of it with JSON_TABLE rather than bound by name
        -- because a payload carrying a JSON ARRAY cannot be bound field by
        -- field at all - ORDS has no SQL type for the array and the whole
        -- request fails with ORA-17004 before any of this runs.
        v_body  CLOB := :body_text;
        v_job   NUMBER;
        v_actor VARCHAR2(100);
        v_final VARCHAR2(1);
        v_trace VARCHAR2(64);
        v_ok   NUMBER := 0;
        v_fail NUMBER := 0;
        -- 1000, matching OC_TIME_SYNC_FAILED.FAILURE_REASON. Capturing 2000
        -- would raise ORA-12899 while trying to record a failure — losing the
        -- diagnostic at the exact moment it is needed.
        v_err  VARCHAR2(1000);
        -- SQLCODE is PL/SQL-only and cannot appear inside a SQL statement
        -- (ORA-00984 "column not allowed here"). Captured into a local, the
        -- same way SQLERRM already is directly below.
        v_code NUMBER;
      BEGIN
        SELECT job_run_id, NVL(actor,'BIP_LOADER'), NVL(fin,'N'), trace
          INTO v_job, v_actor, v_final, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (job_run_id NUMBER        PATH '$.jobRunId',
                          actor      VARCHAR2(100) PATH '$.actor',
                          fin        VARCHAR2(1)   PATH '$.final',
                          trace      VARCHAR2(64)  PATH '$.traceId'));

        IF v_job IS NULL THEN
          INSERT INTO oc_time_sync_job (job_name, job_type, scope_key,
                                        job_status, triggered_by, trace_id)
          VALUES ('Master Sync - WORKERS', 'MasterSync', 'WORKER',
                  'Running', v_actor, NVL(v_trace, SYS_GUID()))
          RETURNING job_run_id INTO v_job;
        END IF;

        FOR r IN (SELECT * FROM JSON_TABLE(v_body, '$.rows[*]'
                    COLUMNS (
                      employee_id       VARCHAR2(50)  PATH '$.EMPLOYEE_ID',
                      employee_name     VARCHAR2(200) PATH '$.EMPLOYEE_NAME',
                      email             VARCHAR2(200) PATH '$.EMAIL',
                      worker_type       VARCHAR2(20)  PATH '$.WORKER_TYPE',
                      base_country      VARCHAR2(60)  PATH '$.BASE_COUNTRY',
                      std_hours_per_day NUMBER        PATH '$.STD_HOURS_PER_DAY',
                      manager_emp_id    VARCHAR2(50)  PATH '$.MANAGER_EMP_ID',
                      legal_employer    VARCHAR2(200) PATH '$.LEGAL_EMPLOYER',
                      expenditure_org   VARCHAR2(240) PATH '$.EXPENDITURE_ORG',
                      hire_date         VARCHAR2(10)  PATH '$.HIRE_DATE',
                      termination_date  VARCHAR2(10)  PATH '$.TERMINATION_DATE',
                      status            VARCHAR2(20)  PATH '$.STATUS')))
        LOOP
          BEGIN
            MERGE INTO oc_time_worker w
            USING (SELECT r.employee_id AS eid FROM dual) s
               ON (w.employee_id = s.eid)
             WHEN MATCHED THEN UPDATE
                  -- NVL(incoming, existing) on every nullable field: a null from
                  -- the source means "no value here", not "delete what you have".
                  --
                  -- Learned the hard way. The first real load blanked EMAIL and
                  -- MANAGER_EMP_ID for every seeded worker, because those people
                  -- exist in Fusion with no work email and no line manager set.
                  -- RULE-015 routes approval through MANAGER_EMP_ID, so one sync
                  -- silently left every timesheet with nobody to approve it.
                  --
                  -- The same reasoning already protected APP_ROLE; it simply was
                  -- not carried to the other columns.
                  SET w.employee_name     = NVL(r.employee_name, w.employee_name),
                      w.email             = NVL(LOWER(r.email), w.email),
                      w.worker_type       = NVL(r.worker_type, w.worker_type),
                      w.base_country      = NVL(r.base_country, w.base_country),
                      w.std_hours_per_day = NVL(r.std_hours_per_day, w.std_hours_per_day),
                      w.manager_emp_id    = NVL(r.manager_emp_id, w.manager_emp_id),
                      w.legal_employer    = NVL(r.legal_employer, w.legal_employer),
                      w.expenditure_org   = NVL(r.expenditure_org, w.expenditure_org),
                      w.hire_date         = NVL(TO_DATE(r.hire_date,'YYYY-MM-DD'), w.hire_date),
                      -- TERMINATION_DATE is the exception and is NOT NVL'd: a
                      -- null here genuinely means "not terminated", so keeping
                      -- an old date would leave a rehired worker terminated.
                      w.termination_date  = TO_DATE(r.termination_date,'YYYY-MM-DD'),
                      w.status            = NVL(r.status, w.status),
                      w.fusion_synced_on  = SYSTIMESTAMP,
                      w.source_system     = 'FUSION',
                      w.source_method     = 'BIP',
                      w.sync_job_run_id   = v_job,
                      w.updated_by        = v_actor
                  -- APP_ROLE is deliberately NOT touched. It is the app's own
                  -- entitlement, set here and not present in HCM; overwriting it
                  -- from an extract would silently demote every manager on the
                  -- next sync.
             WHEN NOT MATCHED THEN
                  INSERT (employee_id, employee_name, email, worker_type,
                          base_country, std_hours_per_day, manager_emp_id,
                          legal_employer, expenditure_org, hire_date,
                          termination_date, status, fusion_synced_on,
                          source_system, source_method, sync_job_run_id, created_by)
                  VALUES (r.employee_id, r.employee_name, LOWER(r.email),
                          NVL(r.worker_type,'Employee'), r.base_country,
                          NVL(r.std_hours_per_day, 8), r.manager_emp_id,
                          r.legal_employer, r.expenditure_org,
                          TO_DATE(r.hire_date,'YYYY-MM-DD'),
                          TO_DATE(r.termination_date,'YYYY-MM-DD'),
                          NVL(r.status,'Active'), SYSTIMESTAMP,
                          'FUSION', 'BIP', v_job, v_actor);
            v_ok := v_ok + 1;
          EXCEPTION WHEN OTHERS THEN
            v_err  := SUBSTR(SQLERRM, 1, 1000);
            v_code := SQLCODE;
            INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                             employee_id, failure_reason,
                                             failure_code, trace_id)
            VALUES (v_job, 'WORKER', r.employee_id, r.employee_id,
                    v_err, v_code, NVL(v_trace,'BIP'));
            v_fail := v_fail + 1;
          END;
        END LOOP;

        UPDATE oc_time_sync_job
           SET records_read     = NVL(records_read,0)     + v_ok + v_fail,
               records_upserted = NVL(records_upserted,0) + v_ok,
               records_failed   = NVL(records_failed,0)   + v_fail,
               job_status  = CASE WHEN v_final = 'Y'
                                  THEN CASE WHEN NVL(records_failed,0) + v_fail > 0
                                            THEN 'Partial' ELSE 'Success' END
                                  ELSE 'Running' END,
               finished_on = CASE WHEN v_final = 'Y'
                                  THEN SYSTIMESTAMP END,
               message     = 'WORKERS upserted ' ||
                             (NVL(records_upserted,0) + v_ok)
         WHERE job_run_id = v_job;

        COMMIT; :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"upserted":' || v_ok ||
              ',"failed":' || v_fail || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST sync/project  (INT-002) ─────────────────────────────
-- TIME_ENTRY_ENABLED is set from the payload and defaults to 'N'. That is what
-- keeps this pod's 423 projects out of the employee picker: a project appears
-- for time entry only when the extract says it should.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/project');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/project',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text is ORDS's implicit CLOB of the whole payload. The
        -- scalars are read out of it with JSON_TABLE rather than bound by name
        -- because a payload carrying a JSON ARRAY cannot be bound field by
        -- field at all - ORDS has no SQL type for the array and the whole
        -- request fails with ORA-17004 before any of this runs.
        v_body  CLOB := :body_text;
        v_job   NUMBER;
        v_actor VARCHAR2(100);
        v_final VARCHAR2(1);
        v_trace VARCHAR2(64);
        v_ok   NUMBER := 0;
        v_fail NUMBER := 0;
        -- 1000, matching OC_TIME_SYNC_FAILED.FAILURE_REASON. Capturing 2000
        -- would raise ORA-12899 while trying to record a failure — losing the
        -- diagnostic at the exact moment it is needed.
        v_err  VARCHAR2(1000);
        -- SQLCODE is PL/SQL-only and cannot appear inside a SQL statement
        -- (ORA-00984 "column not allowed here"). Captured into a local, the
        -- same way SQLERRM already is directly below.
        v_code NUMBER;
      BEGIN
        SELECT job_run_id, NVL(actor,'BIP_LOADER'), NVL(fin,'N'), trace
          INTO v_job, v_actor, v_final, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (job_run_id NUMBER        PATH '$.jobRunId',
                          actor      VARCHAR2(100) PATH '$.actor',
                          fin        VARCHAR2(1)   PATH '$.final',
                          trace      VARCHAR2(64)  PATH '$.traceId'));

        IF v_job IS NULL THEN
          INSERT INTO oc_time_sync_job (job_name, job_type, scope_key,
                                        job_status, triggered_by, trace_id)
          VALUES ('Master Sync - PROJECTS', 'MasterSync', 'PROJECT',
                  'Running', v_actor, NVL(v_trace, SYS_GUID()))
          RETURNING job_run_id INTO v_job;
        END IF;

        FOR r IN (SELECT * FROM JSON_TABLE(v_body, '$.rows[*]'
                    COLUMNS (
                      project_number     VARCHAR2(60)  PATH '$.PROJECT_NUMBER',
                      project_name       VARCHAR2(240) PATH '$.PROJECT_NAME',
                      fusion_project_id  VARCHAR2(50)  PATH '$.PROJECT_ID',
                      customer_name      VARCHAR2(240) PATH '$.CUSTOMER_NAME',
                      project_manager_id VARCHAR2(50)  PATH '$.PROJECT_MANAGER_ID',
                      time_entry_enabled VARCHAR2(1)   PATH '$.TIME_ENTRY_ENABLED',
                      start_date         VARCHAR2(10)  PATH '$.START_DATE',
                      end_date           VARCHAR2(10)  PATH '$.END_DATE',
                      status             VARCHAR2(20)  PATH '$.STATUS')))
        LOOP
          BEGIN
            MERGE INTO oc_time_project p
            USING (SELECT r.project_number AS pn FROM dual) s
               ON (p.project_number = s.pn)
             WHEN MATCHED THEN UPDATE
                  -- NVL(incoming, existing) as in sync/worker above.
                  -- PROJECT_MANAGER_ID especially: RULE-015 has nothing to route
                  -- to without it, and 237 of 424 projects on this pod carry no
                  -- manager party at all.
                  --
                  -- TIME_ENTRY_ENABLED is deliberately NOT NVL'd. It has to be
                  -- able to go back to 'N' when a project stops tracking time,
                  -- and the close-out below depends on that.
                  SET p.project_name       = NVL(r.project_name, p.project_name),
                      p.fusion_project_id  = NVL(r.fusion_project_id, p.fusion_project_id),
                      p.customer_name      = NVL(r.customer_name, p.customer_name),
                      p.project_manager_id = NVL(r.project_manager_id, p.project_manager_id),
                      p.time_entry_enabled = NVL(r.time_entry_enabled,'N'),
                      p.project_start_date = NVL(TO_DATE(r.start_date,'YYYY-MM-DD'), p.project_start_date),
                      p.project_end_date   = TO_DATE(r.end_date,'YYYY-MM-DD'),
                      p.status             = NVL(r.status, p.status),
                      p.fusion_synced_on   = SYSTIMESTAMP,
                      p.source_system      = 'FUSION',
                      p.source_method      = 'BIP',
                      p.sync_job_run_id    = v_job,
                      p.updated_by         = v_actor
                  -- REVENUE_MODEL and LEAVE_LOSS_FLAG are NOT synced: they are
                  -- commercial attributes this module owns, not Fusion's.
             WHEN NOT MATCHED THEN
                  INSERT (project_number, project_name, fusion_project_id,
                          customer_name, project_type, project_manager_id,
                          time_entry_enabled, project_start_date, project_end_date,
                          status, fusion_synced_on, source_system, source_method,
                          sync_job_run_id, created_by)
                  -- PROJECT_TYPE is NOT synced. Fusion's project type is an
                  -- implementation label ('UK Billable no Burden', 'PRGUK
                  -- Funded with Burden', 'Max_Project Type' - 26 distinct
                  -- values on this pod). Ours is a two-value domain where
                  -- 'Organization' specifically means the PRJ-ORG project
                  -- implicitly assigned to every employee (FLD-006). They are
                  -- different concepts, and mapping one onto the other violated
                  -- CHK_OC_TPRJ_TYPE on 26 projects.
                  --
                  -- Every synced project is 'Billable'. 'Organization' is set
                  -- locally for PRJ-ORG, and the sync must not overwrite it -
                  -- which the MATCHED branch already honours by never touching
                  -- the column.
                  VALUES (r.project_number, r.project_name, r.fusion_project_id,
                          r.customer_name, 'Billable',
                          r.project_manager_id, NVL(r.time_entry_enabled,'N'),
                          TO_DATE(r.start_date,'YYYY-MM-DD'),
                          TO_DATE(r.end_date,'YYYY-MM-DD'),
                          NVL(r.status,'Active'), SYSTIMESTAMP,
                          'FUSION', 'BIP', v_job, v_actor);
            v_ok := v_ok + 1;
          EXCEPTION WHEN OTHERS THEN
            v_err  := SUBSTR(SQLERRM, 1, 1000);
            v_code := SQLCODE;
            INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                             failure_reason, failure_code, trace_id)
            VALUES (v_job, 'PROJECT', r.project_number, v_err, v_code,
                    NVL(v_trace,'BIP'));
            v_fail := v_fail + 1;
          END;
        END LOOP;

        UPDATE oc_time_sync_job
           SET records_read     = NVL(records_read,0)     + v_ok + v_fail,
               records_upserted = NVL(records_upserted,0) + v_ok,
               records_failed   = NVL(records_failed,0)   + v_fail,
               job_status  = CASE WHEN v_final = 'Y'
                                  THEN CASE WHEN NVL(records_failed,0) + v_fail > 0
                                            THEN 'Partial' ELSE 'Success' END
                                  ELSE 'Running' END,
               finished_on = CASE WHEN v_final = 'Y' THEN SYSTIMESTAMP END,
               message     = 'PROJECTS upserted ' ||
                             (NVL(records_upserted,0) + v_ok)
         WHERE job_run_id = v_job;

        -- Close out projects this run did not see.
        --
        -- Without this the filter accumulates instead of converging: a project
        -- that WAS in scope last month and is not this month keeps its stale
        -- 'Y' forever, because a MERGE only touches rows it matches. That
        -- happened for real - an earlier derivation admitted 327 projects, and
        -- re-running with the corrected one would have left every one of them
        -- enabled.
        --
        -- Deliberately narrow. Only Fusion-sourced rows, so the locally created
        -- Organization project and the seeded test projects are untouched; and
        -- only on the final chunk, so a load that fails halfway cannot disable
        -- projects it simply had not reached yet.
        IF v_final = 'Y' THEN
          UPDATE oc_time_project
             SET time_entry_enabled = 'N',
                 updated_by         = v_actor
           WHERE source_system      = 'FUSION'
             AND time_entry_enabled = 'Y'
             AND NVL(sync_job_run_id, -1) <> v_job;
        END IF;

        COMMIT; :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"upserted":' || v_ok ||
              ',"failed":' || v_fail || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST sync/task  (INT-002) ────────────────────────────────
-- Keyed on (project, task code) rather than the Fusion task id, because
-- UK_OC_TTSK_WBS is what the table actually enforces. EXPENDITURE_TYPE is
-- carried here — it is POET's E and the reason the OTL push is blocked.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/task');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/task',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text is ORDS's implicit CLOB of the whole payload. The
        -- scalars are read out of it with JSON_TABLE rather than bound by name
        -- because a payload carrying a JSON ARRAY cannot be bound field by
        -- field at all - ORDS has no SQL type for the array and the whole
        -- request fails with ORA-17004 before any of this runs.
        v_body  CLOB := :body_text;
        v_job   NUMBER;
        v_actor VARCHAR2(100);
        v_final VARCHAR2(1);
        v_trace VARCHAR2(64);
        v_ok   NUMBER := 0;
        v_fail NUMBER := 0;
        v_pid  NUMBER;
        -- 1000, matching OC_TIME_SYNC_FAILED.FAILURE_REASON. Capturing 2000
        -- would raise ORA-12899 while trying to record a failure — losing the
        -- diagnostic at the exact moment it is needed.
        v_err  VARCHAR2(1000);
        -- SQLCODE is PL/SQL-only and cannot appear inside a SQL statement
        -- (ORA-00984 "column not allowed here"). Captured into a local, the
        -- same way SQLERRM already is directly below.
        v_code NUMBER;
      BEGIN
        SELECT job_run_id, NVL(actor,'BIP_LOADER'), NVL(fin,'N'), trace
          INTO v_job, v_actor, v_final, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (job_run_id NUMBER        PATH '$.jobRunId',
                          actor      VARCHAR2(100) PATH '$.actor',
                          fin        VARCHAR2(1)   PATH '$.final',
                          trace      VARCHAR2(64)  PATH '$.traceId'));

        IF v_job IS NULL THEN
          INSERT INTO oc_time_sync_job (job_name, job_type, scope_key,
                                        job_status, triggered_by, trace_id)
          VALUES ('Master Sync - TASKS', 'MasterSync', 'TASK',
                  'Running', v_actor, NVL(v_trace, SYS_GUID()))
          RETURNING job_run_id INTO v_job;
        END IF;

        FOR r IN (SELECT * FROM JSON_TABLE(v_body, '$.rows[*]'
                    COLUMNS (
                      project_number    VARCHAR2(60)  PATH '$.PROJECT_NUMBER',
                      fusion_task_id    VARCHAR2(50)  PATH '$.TASK_ID',
                      task_code         VARCHAR2(60)  PATH '$.TASK_NUMBER',
                      task_name         VARCHAR2(240) PATH '$.TASK_NAME',
                      chargeable_flag   VARCHAR2(1)   PATH '$.CHARGEABLE_FLAG',
                      billable_flag     VARCHAR2(1)   PATH '$.BILLABLE_FLAG',
                      expenditure_type  VARCHAR2(80)  PATH '$.EXPENDITURE_TYPE')))
        LOOP
          BEGIN
            SELECT project_id INTO v_pid
              FROM oc_time_project WHERE project_number = r.project_number;

            MERGE INTO oc_time_task t
            USING (SELECT v_pid AS pid, UPPER(r.task_code) AS tc FROM dual) s
               ON (t.project_id = s.pid AND UPPER(t.task_code) = s.tc)
             WHEN MATCHED THEN UPDATE
                  SET t.task_name        = NVL(r.task_name, t.task_name),
                      t.fusion_task_id   = NVL(r.fusion_task_id, t.fusion_task_id),
                      t.chargeable_flag  = NVL(r.chargeable_flag,'Y'),
                      t.billable_type    = CASE WHEN NVL(r.billable_flag,'Y') = 'Y'
                                                THEN 'Billable' ELSE 'Non-billable' END,
                      t.expenditure_type = NVL(r.expenditure_type, t.expenditure_type),
                      t.fusion_synced_on = SYSTIMESTAMP,
                      t.source_system    = 'FUSION',
                      t.source_method    = 'BIP',
                      t.sync_job_run_id  = v_job,
                      t.updated_by       = v_actor
             WHEN NOT MATCHED THEN
                  INSERT (project_id, fusion_task_id, task_code, task_name,
                          task_type, billable_type, chargeable_flag,
                          expenditure_type, fusion_synced_on, source_system,
                          source_method, sync_job_run_id, created_by)
                  VALUES (v_pid, r.fusion_task_id, r.task_code, r.task_name,
                          'WBS',
                          CASE WHEN NVL(r.billable_flag,'Y') = 'Y'
                               THEN 'Billable' ELSE 'Non-billable' END,
                          NVL(r.chargeable_flag,'Y'), r.expenditure_type,
                          SYSTIMESTAMP, 'FUSION', 'BIP', v_job,
                          v_actor);
            v_ok := v_ok + 1;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
              -- The project is not in the cache. Almost always ordering: the
              -- PROJECTS chunk has not been loaded yet, or that project was
              -- filtered out of it.
              INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                               failure_reason, failure_code, trace_id)
              VALUES (v_job, 'TASK', r.project_number || '/' || r.task_code,
                      'No project ' || r.project_number ||
                      ' in the cache - load PROJECTS before TASKS.',
                      100, NVL(v_trace,'BIP'));
              v_fail := v_fail + 1;
            WHEN OTHERS THEN
              v_err  := SUBSTR(SQLERRM, 1, 1000);
            v_code := SQLCODE;
              INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                               failure_reason, failure_code, trace_id)
              VALUES (v_job, 'TASK', r.project_number || '/' || r.task_code,
                      v_err, v_code, NVL(v_trace,'BIP'));
              v_fail := v_fail + 1;
          END;
        END LOOP;

        UPDATE oc_time_sync_job
           SET records_read     = NVL(records_read,0)     + v_ok + v_fail,
               records_upserted = NVL(records_upserted,0) + v_ok,
               records_failed   = NVL(records_failed,0)   + v_fail,
               job_status  = CASE WHEN v_final = 'Y'
                                  THEN CASE WHEN NVL(records_failed,0) + v_fail > 0
                                            THEN 'Partial' ELSE 'Success' END
                                  ELSE 'Running' END,
               finished_on = CASE WHEN v_final = 'Y' THEN SYSTIMESTAMP END,
               message     = 'TASKS upserted ' || (NVL(records_upserted,0) + v_ok)
         WHERE job_run_id = v_job;

        COMMIT; :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"upserted":' || v_ok ||
              ',"failed":' || v_fail || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST sync/allocation  (INT-003) ──────────────────────────
-- The project resource assignment: what each employee may charge to. Carries
-- the EXPENDITURE_ORG override and the contractor PO reference.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/allocation');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/allocation',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text is ORDS's implicit CLOB of the whole payload. The
        -- scalars are read out of it with JSON_TABLE rather than bound by name
        -- because a payload carrying a JSON ARRAY cannot be bound field by
        -- field at all - ORDS has no SQL type for the array and the whole
        -- request fails with ORA-17004 before any of this runs.
        v_body  CLOB := :body_text;
        v_job   NUMBER;
        v_actor VARCHAR2(100);
        v_final VARCHAR2(1);
        v_trace VARCHAR2(64);
        v_ok   NUMBER := 0;
        v_fail NUMBER := 0;
        v_pid  NUMBER;
        v_n    NUMBER;
        -- 1000, matching OC_TIME_SYNC_FAILED.FAILURE_REASON. Capturing 2000
        -- would raise ORA-12899 while trying to record a failure — losing the
        -- diagnostic at the exact moment it is needed.
        v_err  VARCHAR2(1000);
        -- SQLCODE is PL/SQL-only and cannot appear inside a SQL statement
        -- (ORA-00984 "column not allowed here"). Captured into a local, the
        -- same way SQLERRM already is directly below.
        v_code NUMBER;
      BEGIN
        SELECT job_run_id, NVL(actor,'BIP_LOADER'), NVL(fin,'N'), trace
          INTO v_job, v_actor, v_final, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (job_run_id NUMBER        PATH '$.jobRunId',
                          actor      VARCHAR2(100) PATH '$.actor',
                          fin        VARCHAR2(1)   PATH '$.final',
                          trace      VARCHAR2(64)  PATH '$.traceId'));

        IF v_job IS NULL THEN
          INSERT INTO oc_time_sync_job (job_name, job_type, scope_key,
                                        job_status, triggered_by, trace_id)
          VALUES ('Master Sync - ALLOCATIONS', 'MasterSync', 'ALLOCATION',
                  'Running', v_actor, NVL(v_trace, SYS_GUID()))
          RETURNING job_run_id INTO v_job;
        END IF;

        FOR r IN (SELECT * FROM JSON_TABLE(v_body, '$.rows[*]'
                    COLUMNS (
                      project_number   VARCHAR2(60)  PATH '$.PROJECT_NUMBER',
                      employee_id      VARCHAR2(50)  PATH '$.EMPLOYEE_ID',
                      alloc_pct        NUMBER        PATH '$.ALLOC_PCT',
                      client_role      VARCHAR2(120) PATH '$.CLIENT_ROLE',
                      expenditure_org  VARCHAR2(240) PATH '$.EXPENDITURE_ORG',
                      po_number        VARCHAR2(60)  PATH '$.PO_NUMBER',
                      po_line_number   VARCHAR2(30)  PATH '$.PO_LINE_NUMBER',
                      price_type       VARCHAR2(30)  PATH '$.PRICE_TYPE',
                      start_date       VARCHAR2(10)  PATH '$.START_DATE',
                      end_date         VARCHAR2(10)  PATH '$.END_DATE')))
        LOOP
          BEGIN
            SELECT project_id INTO v_pid
              FROM oc_time_project WHERE project_number = r.project_number;

            SELECT COUNT(*) INTO v_n
              FROM oc_time_worker WHERE employee_id = r.employee_id;
            IF v_n = 0 THEN
              RAISE_APPLICATION_ERROR(-20001,
                'No worker ' || r.employee_id ||
                ' in the cache - load WORKERS before ALLOCATIONS.');
            END IF;

            -- UK_OC_TAL_ASSIGN is (project, employee, start_date), but the
            -- extract already collapses each pair to ONE span, so matching on
            -- the pair alone is right here: a changed start date is the same
            -- assignment moving, not a second one.
            MERGE INTO oc_time_allocation a
            USING (SELECT v_pid AS pid, r.employee_id AS eid FROM dual) s
               ON (a.project_id = s.pid AND a.employee_id = s.eid)
             WHEN MATCHED THEN UPDATE
                  SET a.alloc_pct        = NVL(r.alloc_pct, a.alloc_pct),
                      a.client_role      = NVL(r.client_role, a.client_role),
                      a.expenditure_org  = NVL(r.expenditure_org, a.expenditure_org),
                      a.po_number        = NVL(r.po_number, a.po_number),
                      a.po_line_number   = NVL(r.po_line_number, a.po_line_number),
                      a.price_type       = NVL(r.price_type, a.price_type),
                      a.end_date         = TO_DATE(r.end_date,'YYYY-MM-DD'),
                      a.fusion_synced_on = SYSTIMESTAMP,
                      a.source_system    = 'FUSION',
                      a.source_method    = 'BIP',
                      a.sync_job_run_id  = v_job,
                      a.updated_by       = v_actor
                  -- BILLING_STATUS and APPROVING_MANAGER_ID stay: the first is
                  -- this module's own commercial classification, the second is
                  -- resolved from the project manager, not the assignment.
             WHEN NOT MATCHED THEN
                  INSERT (project_id, employee_id, alloc_pct, client_role,
                          expenditure_org, po_number, po_line_number, price_type,
                          start_date, end_date, fusion_synced_on, source_system,
                          source_method, sync_job_run_id, created_by)
                  VALUES (v_pid, r.employee_id, NVL(r.alloc_pct,100),
                          r.client_role, r.expenditure_org, r.po_number,
                          r.po_line_number, r.price_type,
                          NVL(TO_DATE(r.start_date,'YYYY-MM-DD'), TRUNC(SYSDATE)),
                          TO_DATE(r.end_date,'YYYY-MM-DD'), SYSTIMESTAMP,
                          'FUSION', 'BIP', v_job, v_actor);
            v_ok := v_ok + 1;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
              INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                               employee_id, failure_reason,
                                               failure_code, trace_id)
              VALUES (v_job, 'ALLOCATION',
                      r.project_number || '/' || r.employee_id, r.employee_id,
                      'No project ' || r.project_number ||
                      ' in the cache - load PROJECTS before ALLOCATIONS.',
                      100, NVL(v_trace,'BIP'));
              v_fail := v_fail + 1;
            WHEN OTHERS THEN
              v_err  := SUBSTR(SQLERRM, 1, 1000);
            v_code := SQLCODE;
              INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                               employee_id, failure_reason,
                                               failure_code, trace_id)
              VALUES (v_job, 'ALLOCATION',
                      r.project_number || '/' || r.employee_id, r.employee_id,
                      v_err, v_code, NVL(v_trace,'BIP'));
              v_fail := v_fail + 1;
          END;
        END LOOP;

        UPDATE oc_time_sync_job
           SET records_read     = NVL(records_read,0)     + v_ok + v_fail,
               records_upserted = NVL(records_upserted,0) + v_ok,
               records_failed   = NVL(records_failed,0)   + v_fail,
               job_status  = CASE WHEN v_final = 'Y'
                                  THEN CASE WHEN NVL(records_failed,0) + v_fail > 0
                                            THEN 'Partial' ELSE 'Success' END
                                  ELSE 'Running' END,
               finished_on = CASE WHEN v_final = 'Y' THEN SYSTIMESTAMP END,
               message     = 'ALLOCATIONS upserted ' ||
                             (NVL(records_upserted,0) + v_ok)
         WHERE job_run_id = v_job;

        COMMIT; :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"upserted":' || v_ok ||
              ',"failed":' || v_fail || '}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 400;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST sync/absence  (INT-006) ─────────────────────────────
-- Read-only in this app: absences generate the Leave row and the leave-loss
-- absentee list, and are never re-sent downstream (RULE-008).
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'sync/absence');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'sync/absence',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text is ORDS's implicit CLOB of the whole payload. The
        -- scalars are read out of it with JSON_TABLE rather than bound by name
        -- because a payload carrying a JSON ARRAY cannot be bound field by
        -- field at all - ORDS has no SQL type for the array and the whole
        -- request fails with ORA-17004 before any of this runs.
        v_body  CLOB := :body_text;
        v_job   NUMBER;
        v_actor VARCHAR2(100);
        v_final VARCHAR2(1);
        v_trace VARCHAR2(64);
        v_ok   NUMBER := 0;
        v_fail NUMBER := 0;
        -- 1000, matching OC_TIME_SYNC_FAILED.FAILURE_REASON. Capturing 2000
        -- would raise ORA-12899 while trying to record a failure — losing the
        -- diagnostic at the exact moment it is needed.
        v_err  VARCHAR2(1000);
        -- SQLCODE is PL/SQL-only and cannot appear inside a SQL statement
        -- (ORA-00984 "column not allowed here"). Captured into a local, the
        -- same way SQLERRM already is directly below.
        v_code NUMBER;
      BEGIN
        SELECT job_run_id, NVL(actor,'BIP_LOADER'), NVL(fin,'N'), trace
          INTO v_job, v_actor, v_final, v_trace
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (job_run_id NUMBER        PATH '$.jobRunId',
                          actor      VARCHAR2(100) PATH '$.actor',
                          fin        VARCHAR2(1)   PATH '$.final',
                          trace      VARCHAR2(64)  PATH '$.traceId'));

        IF v_job IS NULL THEN
          INSERT INTO oc_time_sync_job (job_name, job_type, scope_key,
                                        job_status, triggered_by, trace_id)
          VALUES ('Master Sync - ABSENCES', 'MasterSync', 'ABSENCE',
                  'Running', v_actor, NVL(v_trace, SYS_GUID()))
          RETURNING job_run_id INTO v_job;
        END IF;

        FOR r IN (SELECT * FROM JSON_TABLE(v_body, '$.rows[*]'
                    COLUMNS (
                      employee_id     VARCHAR2(50)  PATH '$.EMPLOYEE_ID',
                      absence_date    VARCHAR2(10)  PATH '$.ABSENCE_DATE',
                      absence_type    VARCHAR2(100) PATH '$.ABSENCE_TYPE',
                      absence_hours   NUMBER        PATH '$.DURATION_HOURS',
                      approval_status VARCHAR2(30)  PATH '$.APPROVAL_STATUS')))
        LOOP
          BEGIN
            MERGE INTO oc_time_absence ab
            USING (SELECT r.employee_id AS eid,
                          TO_DATE(r.absence_date,'YYYY-MM-DD') AS ad,
                          r.absence_type AS at FROM dual) s
               ON (ab.employee_id = s.eid AND ab.absence_date = s.ad
               AND ab.absence_type = s.at)
             WHEN MATCHED THEN UPDATE
                  SET ab.absence_hours    = NVL(r.absence_hours, 0),
                      ab.approval_status  = NVL(r.approval_status,'Approved'),
                      ab.fusion_synced_on = SYSTIMESTAMP,
                      ab.source_system    = 'FUSION',
                      ab.source_method    = 'BIP',
                      ab.sync_job_run_id  = v_job,
                      ab.updated_by       = v_actor
             WHEN NOT MATCHED THEN
                  INSERT (employee_id, absence_date, absence_type, absence_hours,
                          approval_status, fusion_synced_on, source_system,
                          source_method, sync_job_run_id, created_by)
                  VALUES (r.employee_id, TO_DATE(r.absence_date,'YYYY-MM-DD'),
                          r.absence_type, NVL(r.absence_hours,0),
                          NVL(r.approval_status,'Approved'), SYSTIMESTAMP,
                          'FUSION', 'BIP', v_job, v_actor);
            v_ok := v_ok + 1;
          EXCEPTION WHEN OTHERS THEN
            v_err  := SUBSTR(SQLERRM, 1, 1000);
            v_code := SQLCODE;
            INSERT INTO oc_time_sync_failed (job_run_id, entity_type, entity_key,
                                             employee_id, failure_reason,
                                             failure_code, trace_id)
            VALUES (v_job, 'ABSENCE',
                    r.employee_id || '/' || r.absence_date, r.employee_id,
                    v_err, v_code, NVL(v_trace,'BIP'));
            v_fail := v_fail + 1;
          END;
        END LOOP;

        UPDATE oc_time_sync_job
           SET records_read     = NVL(records_read,0)     + v_ok + v_fail,
               records_upserted = NVL(records_upserted,0) + v_ok,
               records_failed   = NVL(records_failed,0)   + v_fail,
               job_status  = CASE WHEN v_final = 'Y'
                                  THEN CASE WHEN NVL(records_failed,0) + v_fail > 0
                                            THEN 'Partial' ELSE 'Success' END
                                  ELSE 'Running' END,
               finished_on = CASE WHEN v_final = 'Y' THEN SYSTIMESTAMP END,
               message     = 'ABSENCES upserted ' ||
                             (NVL(records_upserted,0) + v_ok)
         WHERE job_run_id = v_job;

        COMMIT; :status_code := 200;
        HTP.P('{"jobRunId":' || v_job || ',"upserted":' || v_ok ||
              ',"failed":' || v_fail || '}');
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
             tasks_chargeable, tasks_no_exp_type, tasks_unresolvable,
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
