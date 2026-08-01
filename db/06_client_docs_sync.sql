--==============================================================
-- time/06_client_docs_sync.sql
-- O2C Timesheet Module — Client timesheet attachments & sync telemetry
--
--   OC_TS_CLIENT_DOC    = customer-approved (signed) timesheets, per Project +
--                         Billing Period. Deliberately NOT linked to the billing
--                         close date: signed sheets often arrive 1-2 weeks after
--                         close, there are multiple documents, and there is no
--                         approval step (PROC-011 / BRD 4.3).
--   OC_TIME_SYNC_JOB    = one row per run of the monthly population job and the
--                         daily action-date process (PROC-001, PROC-014).
--   OC_TIME_SYNC_FAILED = the failed-record queue surfaced on PAGE-010 with a
--                         retry action (ACT-032) — e.g. new hire without an
--                         allocation, missing shift calendar.
--
-- Requirement refs: PROC-011, PROC-014, PAGE-002, PAGE-010,
--                   FLD-019..FLD-025, FLD-097..FLD-101,
--                   ACT-010, ACT-031, ACT-032, OBS-003, OBS-004, REP-006
-- Idempotent. Depends on: time/01, time/02
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/6] OC_TS_CLIENT_DOC — signed client timesheets
PROMPT ============================================================

-- Security sheet PAGE-002: confidential, attachment policy PDF/doc/xls/img up
-- to 25MB. The size ceiling is enforced here as well as in the UI so an ORDS
-- caller cannot bypass it.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_client_doc (
      DOC_ID       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      PROJECT_ID   NUMBER            NOT NULL,   -- FLD-019
      PERIOD_ID    NUMBER            NOT NULL,   -- FLD-020 billing period
      DISPLAY_MODE VARCHAR2(20 CHAR) DEFAULT 'Whole month' NOT NULL, -- FLD-021
      WEEK_INDEX   NUMBER(2),                    -- set when DISPLAY_MODE='Week-wise'
      DOC_NAME     VARCHAR2(400 CHAR) NOT NULL,  -- FLD-023
      MIME_TYPE    VARCHAR2(120 CHAR),
      DOC_SIZE     NUMBER(12)         NOT NULL,  -- FLD-024, bytes
      DOC_CONTENT  BLOB,                         -- FLD-022
      UPLOADED_BY  VARCHAR2(100 CHAR) NOT NULL,
      UPLOADED_ON  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL, -- FLD-025
      REMARKS      VARCHAR2(1000 CHAR),
      CONSTRAINT chk_oc_tscd_mode CHECK (display_mode IN ('Week-wise','Whole month')),
      CONSTRAINT chk_oc_tscd_week CHECK (
        (display_mode = 'Week-wise' AND week_index IS NOT NULL) OR
        (display_mode = 'Whole month')),
      CONSTRAINT chk_oc_tscd_size CHECK (doc_size > 0 AND doc_size <= 26214400),
      CONSTRAINT chk_oc_tscd_mime CHECK (mime_type IS NULL OR mime_type IN (
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'image/png','image/jpeg','image/gif')),
      CONSTRAINT fk_oc_tscd_proj   FOREIGN KEY (project_id)
        REFERENCES oc_time_project(project_id),
      CONSTRAINT fk_oc_tscd_period FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_CLIENT_DOC created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_CLIENT_DOC already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tscd_proj ON oc_ts_client_doc(project_id, period_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [1b/6] OC_TIME_B64_TO_BLOB — base64 CLOB -> BLOB
PROMPT ============================================================

-- The VBCS page sends the attachment as base64 text. UTL_ENCODE.BASE64_DECODE
-- works on RAW and is capped at 32k, so a 25MB upload must be decoded in
-- chunks. Base64 encodes 3 bytes as 4 characters, so the chunk size must be a
-- multiple of 4 to avoid splitting a quantum across iterations.
CREATE OR REPLACE FUNCTION oc_time_b64_to_blob(p_b64 IN CLOB) RETURN BLOB IS
  v_blob    BLOB;
  v_chunk   CONSTANT PLS_INTEGER := 22800;   -- multiple of 4, under the 32k cap
  v_offset  PLS_INTEGER := 1;
  v_len     PLS_INTEGER;
  v_piece   VARCHAR2(32767);
BEGIN
  IF p_b64 IS NULL THEN
    RETURN NULL;
  END IF;

  DBMS_LOB.CREATETEMPORARY(v_blob, TRUE);
  v_len := DBMS_LOB.GETLENGTH(p_b64);

  WHILE v_offset <= v_len LOOP
    v_piece := DBMS_LOB.SUBSTR(p_b64, v_chunk, v_offset);
    EXIT WHEN v_piece IS NULL;
    -- Strip any whitespace the encoder wrapped in; it is not part of the data.
    v_piece := REPLACE(REPLACE(REPLACE(v_piece, CHR(13)), CHR(10)), ' ');
    IF LENGTH(v_piece) > 0 THEN
      DBMS_LOB.APPEND(v_blob,
        TO_BLOB(UTL_ENCODE.BASE64_DECODE(UTL_RAW.CAST_TO_RAW(v_piece))));
    END IF;
    v_offset := v_offset + v_chunk;
  END LOOP;

  RETURN v_blob;
END oc_time_b64_to_blob;
/

PROMPT ============================================================
PROMPT [2/6] OC_TIME_SYNC_JOB — job telemetry
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_sync_job (
      JOB_RUN_ID     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      JOB_NAME       VARCHAR2(60 CHAR) NOT NULL,   -- FLD-097
      JOB_TYPE       VARCHAR2(20 CHAR) NOT NULL,
      PERIOD_ID      NUMBER,
      ACTION_DATE    DATE,                         -- daily process action date
      SCOPE_KEY      VARCHAR2(120 CHAR),           -- base/deputed country, project
      JOB_STATUS     VARCHAR2(20 CHAR) DEFAULT 'Running' NOT NULL, -- FLD-099
      STARTED_ON     TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      FINISHED_ON    TIMESTAMP,                    -- FLD-098 last run
      DURATION_MS    NUMBER(12),
      RECORDS_READ      NUMBER(10) DEFAULT 0 NOT NULL,
      RECORDS_UPSERTED  NUMBER(10) DEFAULT 0 NOT NULL,
      RECORDS_FAILED    NUMBER(10) DEFAULT 0 NOT NULL, -- FLD-100
      MESSAGE        VARCHAR2(2000 CHAR),
      TRACE_ID       VARCHAR2(64 CHAR),            -- OBS-003 / OBS-004
      TRIGGERED_BY   VARCHAR2(100 CHAR) DEFAULT 'SCHEDULER' NOT NULL,
      -- DeliveryDefaulting is the manager-side twin of WeeklyDefaulting, and
      -- AccrualTopUp posts adjustments approved after a month was confirmed.
      -- Both are separate job types rather than reusing the neighbouring one
      -- because the telemetry has to tell them apart: they run on different
      -- schedules and a failure in each means something different.
      CONSTRAINT chk_oc_tsj_type   CHECK (job_type IN
        ('MonthlyPopulation','DailyActionDate','CalendarSync','MasterSync',
         'WeeklyDefaulting','DeliveryDefaulting','SalaryStopping',
         'AccrualHandoff','AccrualTopUp','OtlPush')),
      CONSTRAINT chk_oc_tsj_status CHECK (job_status IN
        ('Running','Success','Failed','Partial')),
      CONSTRAINT fk_oc_tsj_period  FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_JOB created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_JOB already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- The CREATE above is skipped on a schema that already has the table, so a
-- widened CHECK never reaches an installed environment through it. This
-- re-states the constraint every run: the file has to be re-runnable, and a job
-- type the constraint does not know about fails at INSERT with ORA-02290 —
-- which reads as a broken job rather than a stale constraint.
--
-- Rebuilt rather than altered because Oracle has no ALTER ... MODIFY CONSTRAINT
-- for a CHECK condition. Nothing is dropped but the constraint itself, and it
-- is recreated in the same statement block.
DECLARE
  v_n PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSJ_TYPE';

  IF v_n > 0 THEN
    EXECUTE IMMEDIATE
      'ALTER TABLE oc_time_sync_job DROP CONSTRAINT chk_oc_tsj_type';
  END IF;

  EXECUTE IMMEDIATE q'~
    ALTER TABLE oc_time_sync_job ADD CONSTRAINT chk_oc_tsj_type CHECK (job_type IN
      ('MonthlyPopulation','DailyActionDate','CalendarSync','MasterSync',
       'WeeklyDefaulting','DeliveryDefaulting','SalaryStopping',
       'AccrualHandoff','AccrualTopUp','OtlPush'))~';

  DBMS_OUTPUT.PUT_LINE('CHK_OC_TSJ_TYPE refreshed (10 job types).');
EXCEPTION WHEN OTHERS THEN
  -- ORA-02293: an existing row holds a job type not in the new list. Report it
  -- rather than leaving the table with no type constraint at all.
  DBMS_OUTPUT.PUT_LINE('WARNING: could not refresh CHK_OC_TSJ_TYPE - ' ||
                       SUBSTR(SQLERRM, 1, 200));
  RAISE;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsj_name ON oc_time_sync_job(job_name, started_on DESC)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsj_status ON oc_time_sync_job(job_status, started_on DESC)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/6] OC_TIME_SYNC_FAILED — failed-record queue
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_sync_failed (
      FAILED_ID      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      JOB_RUN_ID     NUMBER            NOT NULL,
      ENTITY_TYPE    VARCHAR2(40 CHAR) NOT NULL,   -- WORKER | PROJECT | TASK | ALLOCATION | ABSENCE | CALENDAR
      ENTITY_KEY     VARCHAR2(200 CHAR) NOT NULL,
      EMPLOYEE_ID    VARCHAR2(50 CHAR),
      FAILURE_REASON VARCHAR2(1000 CHAR) NOT NULL, -- FLD-101
      FAILURE_CODE   VARCHAR2(40 CHAR),
      PAYLOAD_REF    VARCHAR2(400 CHAR),           -- pointer only; never the body (Security)
      RETRY_COUNT    NUMBER(3) DEFAULT 0 NOT NULL,
      RESOLVED_FLAG  CHAR(1)   DEFAULT 'N' NOT NULL,
      RESOLVED_ON    TIMESTAMP,
      RESOLVED_BY    VARCHAR2(100 CHAR),
      FIRST_SEEN_ON  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      LAST_RETRY_ON  TIMESTAMP,
      TRACE_ID       VARCHAR2(64 CHAR),
      CONSTRAINT chk_oc_tsf_resolved CHECK (resolved_flag IN ('Y','N')),
      CONSTRAINT fk_oc_tsf_job FOREIGN KEY (job_run_id)
        REFERENCES oc_time_sync_job(job_run_id) ON DELETE CASCADE
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_FAILED created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_FAILED already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsf_open ON oc_time_sync_failed(resolved_flag, first_seen_on DESC)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [4/6] OC_TIME_SYNC_JOB — duration + rollup trigger
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tsj_duration
BEFORE UPDATE OF finished_on, job_status ON oc_time_sync_job
FOR EACH ROW
BEGIN
  IF :NEW.finished_on IS NOT NULL THEN
    :NEW.duration_ms := ROUND(
      EXTRACT(DAY    FROM (:NEW.finished_on - :NEW.started_on)) * 86400000 +
      EXTRACT(HOUR   FROM (:NEW.finished_on - :NEW.started_on)) * 3600000 +
      EXTRACT(MINUTE FROM (:NEW.finished_on - :NEW.started_on)) * 60000 +
      EXTRACT(SECOND FROM (:NEW.finished_on - :NEW.started_on)) * 1000);
  END IF;

  -- OBS-003 / OBS-004 alert thresholds fire on failure_count > 0, so a run that
  -- completed with failures must not report a clean 'Success'.
  IF :NEW.job_status = 'Success' AND NVL(:NEW.records_failed,0) > 0 THEN
    :NEW.job_status := 'Partial';
  END IF;
END;
/

PROMPT ============================================================
PROMPT [5/6] V_OC_TIME_SYNC_STATUS — job cards (PAGE-010)
PROMPT ============================================================

-- Latest run per job name for the job cards, plus the still-open failure count
-- so the card and the failed-records table below it agree.
CREATE OR REPLACE VIEW v_oc_time_sync_status AS
SELECT j.job_run_id,
       j.job_name,
       j.job_type,
       j.scope_key,
       p.period_name,
       TO_CHAR(j.action_date, 'YYYY-MM-DD')          AS action_date,
       j.job_status,
       TO_CHAR(j.started_on,  'YYYY-MM-DD HH24:MI')  AS started_on,
       TO_CHAR(j.finished_on, 'YYYY-MM-DD HH24:MI')  AS last_run,
       j.duration_ms,
       j.records_read,
       j.records_upserted,
       j.records_failed,
       (SELECT COUNT(*) FROM oc_time_sync_failed f
         WHERE f.job_run_id = j.job_run_id
           AND f.resolved_flag = 'N')                AS open_failures,
       j.message,
       j.trace_id,
       j.triggered_by
  FROM oc_time_sync_job j
  LEFT JOIN oc_time_period p ON p.period_id = j.period_id
 WHERE j.job_run_id IN (
         SELECT MAX(job_run_id) FROM oc_time_sync_job GROUP BY job_name);

PROMPT ============================================================
PROMPT [6/6] V_OC_TIME_SYNC_FAILED — failed records with retry context
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_time_sync_failed AS
SELECT f.failed_id,
       f.job_run_id,
       j.job_name,
       j.job_type,
       f.entity_type,
       f.entity_key,
       f.employee_id,
       w.employee_name,
       f.failure_reason,
       f.failure_code,
       f.retry_count,
       f.resolved_flag,
       TO_CHAR(f.first_seen_on, 'YYYY-MM-DD HH24:MI') AS first_seen_on,
       TO_CHAR(f.last_retry_on, 'YYYY-MM-DD HH24:MI') AS last_retry_on,
       f.resolved_by,
       TO_CHAR(f.resolved_on,   'YYYY-MM-DD HH24:MI') AS resolved_on,
       f.trace_id
  FROM oc_time_sync_failed f
  JOIN oc_time_sync_job    j ON j.job_run_id = f.job_run_id
  LEFT JOIN oc_time_worker w ON w.employee_id = f.employee_id;

PROMPT
PROMPT ============================================================
PROMPT time/06_client_docs_sync complete.
PROMPT ============================================================
