--==============================================================
-- time/02_time_master.sql
-- O2C Timesheet Module — Master data cached from Oracle Fusion
--
-- This module is a STANDALONE application. It owns its own schema and does
-- not read the O2C main application's tables. Everything below is an
-- idempotent local cache of Fusion master data, keyed on the Fusion id so the
-- sync jobs can upsert safely (PROC-014).
--
--   OC_TIME_WORKER      <- HCM /workers + assignments            (INT-001)
--   OC_TIME_PROJECT     <- PPM /projects                         (INT-002)
--   OC_TIME_TASK        <- PPM /projects/{id}/child/Tasks        (INT-002)
--                          + the common non-billable tasks
--   OC_TIME_ALLOCATION  <- PPM /projectResourceAssignments       (INT-003)
--   OC_TIME_ABSENCE     <- HCM /absences                         (INT-006)
--
-- Requirement refs: PROC-001, PROC-014, FLD-006..FLD-008, FLD-014, FLD-026,
--                   FLD-038..FLD-040, FLD-045, RULE-001, RULE-008, RULE-010,
--                   RULE-011, Data_Dictionaries (common_task, project_type)
-- Idempotent. Depends on: time/01_time_reference.sql
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/6] OC_TIME_WORKER — HCM worker / assignment cache
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_worker (
      WORKER_ID          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EMPLOYEE_ID        VARCHAR2(50 CHAR)  NOT NULL,   -- HCM PersonNumber
      FUSION_PERSON_ID   VARCHAR2(50 CHAR),             -- HCM PersonId
      EMPLOYEE_NAME      VARCHAR2(200 CHAR) NOT NULL,
      EMAIL              VARCHAR2(200 CHAR),
      WORKER_TYPE        VARCHAR2(20 CHAR)  DEFAULT 'Employee' NOT NULL,
      APP_ROLE           VARCHAR2(30 CHAR)  DEFAULT 'ROLE_TIME_EMPLOYEE' NOT NULL,
      BASE_COUNTRY       VARCHAR2(60 CHAR),             -- drives cut-off local time
      DEPUTED_COUNTRY    VARCHAR2(60 CHAR),             -- PROC-001 deputation
      STD_HOURS_PER_DAY  NUMBER(4,2) DEFAULT 8,         -- FLD-011 / CFG-013
      MANAGER_EMP_ID     VARCHAR2(50 CHAR),             -- RULE-015 reports-to
      LEGAL_EMPLOYER     VARCHAR2(200 CHAR),
      HIRE_DATE          DATE,
      TERMINATION_DATE   DATE,
      STATUS             VARCHAR2(20 CHAR) DEFAULT 'Active' NOT NULL,
      FUSION_SYNCED_ON   TIMESTAMP,
      CREATED_BY         VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY         VARCHAR2(100),
      UPDATED_ON         TIMESTAMP,
      CONSTRAINT chk_oc_tw_type   CHECK (worker_type IN ('Employee','Contractor')),
      CONSTRAINT chk_oc_tw_status CHECK (status IN ('Active','Inactive','Terminated')),
      CONSTRAINT chk_oc_tw_role   CHECK (app_role IN
        ('ROLE_TIME_EMPLOYEE','ROLE_TIME_CONTRACTOR','ROLE_TIME_MANAGER',
         'ROLE_TIME_ADMIN','ROLE_TIME_NONE')),
      CONSTRAINT chk_oc_tw_std    CHECK (std_hours_per_day BETWEEN 0 AND 24),
      CONSTRAINT uk_oc_tw_emp     UNIQUE (employee_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_WORKER created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_WORKER already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tw_mgr ON oc_time_worker(manager_emp_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tw_role ON oc_time_worker(app_role, status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/6] OC_TIME_PROJECT — PPM project cache
PROMPT ============================================================

-- PROJECT_TYPE (Data_Dictionaries project_type):
--   'Billable'          normal delivery project
--   'Organization'      the Organization (Non-Billable) project, PRJ-ORG,
--                       implicitly assigned to ALL employees (FLD-006)
-- REVENUE_MODEL: T&M / FCP / Milestone. LEAVE_LOSS_FLAG only has meaning for
-- FCP (Fixed Capacity) projects — PROC-006 / RULE-014 gate on both.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_project (
      PROJECT_ID         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      FUSION_PROJECT_ID  VARCHAR2(50 CHAR),
      PROJECT_NUMBER     VARCHAR2(60 CHAR)  NOT NULL,
      PROJECT_NAME       VARCHAR2(240 CHAR) NOT NULL,
      CUSTOMER_ID        VARCHAR2(50 CHAR),
      CUSTOMER_NAME      VARCHAR2(240 CHAR),
      PROJECT_TYPE       VARCHAR2(20 CHAR) DEFAULT 'Billable' NOT NULL,
      REVENUE_MODEL      VARCHAR2(20 CHAR),
      LEAVE_LOSS_FLAG    CHAR(1) DEFAULT 'N' NOT NULL,
      PROJECT_MANAGER_ID VARCHAR2(50 CHAR),
      COUNTRY            VARCHAR2(60 CHAR),
      PROJECT_START_DATE DATE,
      PROJECT_END_DATE   DATE,
      CURRENCY_CODE      VARCHAR2(3 CHAR),
      STATUS             VARCHAR2(20 CHAR) DEFAULT 'Active' NOT NULL,
      FUSION_SYNCED_ON   TIMESTAMP,
      CREATED_BY         VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY         VARCHAR2(100),
      UPDATED_ON         TIMESTAMP,
      CONSTRAINT chk_oc_tprj_type  CHECK (project_type IN ('Billable','Organization')),
      CONSTRAINT chk_oc_tprj_model CHECK (revenue_model IS NULL OR
        revenue_model IN ('T&M','FCP','Milestone')),
      CONSTRAINT chk_oc_tprj_ll    CHECK (leave_loss_flag IN ('Y','N')),
      CONSTRAINT chk_oc_tprj_stat  CHECK (status IN ('Active','Closed','On Hold')),
      CONSTRAINT uk_oc_tprj_number UNIQUE (project_number)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_PROJECT created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_PROJECT already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tprj_mgr ON oc_time_project(project_manager_id, status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tprj_fusion ON oc_time_project(fusion_project_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/6] OC_TIME_TASK — WBS tasks + common non-billable tasks
PROMPT ============================================================

-- RULE-010: a charged task must be in the project's WBS OR be a common task.
--   TASK_TYPE 'WBS'    — project-specific, PROJECT_ID mandatory
--   TASK_TYPE 'COMMON' — PROJECT_ID NULL. The four common non-billable tasks
--                        (Onboarding / Training / Travel / Client Holiday)
--                        appear in EVERY project and in the Org project.
--   SELECTABLE_FLAG 'N' — Leave and Billing Loss are system-sourced and must
--                        never appear in the employee task LOV (RULE-008,
--                        RULE-009, Data_Dictionaries common_task 'Leave').
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_task (
      TASK_ID          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      PROJECT_ID       NUMBER,
      FUSION_TASK_ID   VARCHAR2(50 CHAR),
      TASK_CODE        VARCHAR2(60 CHAR)  NOT NULL,
      TASK_NAME        VARCHAR2(240 CHAR) NOT NULL,
      TASK_TYPE        VARCHAR2(10 CHAR)  DEFAULT 'WBS' NOT NULL,
      BILLABLE_TYPE    VARCHAR2(20 CHAR)  DEFAULT 'Billable' NOT NULL,
      UNBILLED_REASON  VARCHAR2(60 CHAR),
      CHARGEABLE_FLAG  CHAR(1) DEFAULT 'Y' NOT NULL,
      SELECTABLE_FLAG  CHAR(1) DEFAULT 'Y' NOT NULL,
      SORT_ORDER       NUMBER(4) DEFAULT 100 NOT NULL,
      STATUS           VARCHAR2(20 CHAR) DEFAULT 'Active' NOT NULL,
      FUSION_SYNCED_ON TIMESTAMP,
      CREATED_BY       VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY       VARCHAR2(100),
      UPDATED_ON       TIMESTAMP,
      CONSTRAINT chk_oc_ttsk_type   CHECK (task_type IN ('WBS','COMMON')),
      CONSTRAINT chk_oc_ttsk_bill   CHECK (billable_type IN ('Billable','Non-billable')),
      CONSTRAINT chk_oc_ttsk_charge CHECK (chargeable_flag IN ('Y','N')),
      CONSTRAINT chk_oc_ttsk_sel    CHECK (selectable_flag  IN ('Y','N')),
      CONSTRAINT chk_oc_ttsk_scope  CHECK (
        (task_type = 'WBS'    AND project_id IS NOT NULL) OR
        (task_type = 'COMMON' AND project_id IS NULL)),
      CONSTRAINT fk_oc_ttsk_proj    FOREIGN KEY (project_id)
        REFERENCES oc_time_project(project_id) ON DELETE CASCADE
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_TASK created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_TASK already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- WBS task codes are unique inside a project; common task codes are globally
-- unique. Two partial unique indexes, because PROJECT_ID is NULL for COMMON.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE UNIQUE INDEX uk_oc_ttsk_wbs
      ON oc_time_task (project_id, UPPER(task_code))
  ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE UNIQUE INDEX uk_oc_ttsk_common
      ON oc_time_task (CASE WHEN task_type = 'COMMON' THEN UPPER(task_code) END)
  ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [4/6] OC_TIME_ALLOCATION — PPM resource assignment cache
PROMPT ============================================================

-- INT-003. Drives (a) which projects appear in the employee's grid (FLD-006),
-- (b) the allocation pop-up (FLD-005 / ACT-008), (c) the approving manager per
-- project line (ACT-002 routes per project line), (d) the unbilled pool for
-- leave-loss coverage (RULE-014), (e) Cap type/hours shown to the manager
-- (FLD-045, info only — no validation).
-- RULE-001: allocation across projects should total 100% — a WARNING, so it is
-- validated in OC_TIME_PKG, not as a table constraint (an employee legitimately
-- exceeds 100% mid-transfer).
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_allocation (
      ALLOCATION_ID       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      FUSION_ASSIGNMENT_ID VARCHAR2(50 CHAR),
      PROJECT_ID          NUMBER            NOT NULL,
      EMPLOYEE_ID         VARCHAR2(50 CHAR) NOT NULL,
      ALLOC_PCT           NUMBER(5,2) DEFAULT 100 NOT NULL,
      BILLING_STATUS      VARCHAR2(20 CHAR) DEFAULT 'Billable' NOT NULL,
      CLIENT_ROLE         VARCHAR2(120 CHAR),
      APPROVING_MANAGER_ID VARCHAR2(50 CHAR),
      CAP_TYPE            VARCHAR2(20 CHAR),
      CAP_HOURS           NUMBER(10,2),
      START_DATE          DATE              NOT NULL,
      END_DATE            DATE,
      STATUS              VARCHAR2(20 CHAR) DEFAULT 'Active' NOT NULL,
      FUSION_SYNCED_ON    TIMESTAMP,
      CREATED_BY          VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON          TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY          VARCHAR2(100),
      UPDATED_ON          TIMESTAMP,
      CONSTRAINT chk_oc_tal_billing CHECK (billing_status IN ('Billable','Unbilled')),
      CONSTRAINT chk_oc_tal_pct     CHECK (alloc_pct > 0 AND alloc_pct <= 100),
      CONSTRAINT chk_oc_tal_status  CHECK (status IN ('Active','Ended')),
      CONSTRAINT chk_oc_tal_dates   CHECK (end_date IS NULL OR end_date >= start_date),
      CONSTRAINT uk_oc_tal_assign   UNIQUE (project_id, employee_id, start_date),
      CONSTRAINT fk_oc_tal_proj     FOREIGN KEY (project_id)
        REFERENCES oc_time_project(project_id) ON DELETE CASCADE,
      CONSTRAINT fk_oc_tal_emp      FOREIGN KEY (employee_id)
        REFERENCES oc_time_worker(employee_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_ALLOCATION created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_ALLOCATION already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tal_emp ON oc_time_allocation(employee_id, status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tal_mgr ON oc_time_allocation(approving_manager_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [5/6] OC_TIME_ABSENCE — HCM absence cache
PROMPT ============================================================

-- INT-006. Leave is HR-sourced and NOT selectable by the employee (RULE-008):
-- these rows generate the read-only Leave row (FLD-014) and the absentee list
-- for leave-loss coverage (PAGE-006).
-- IS_LOP / maternity rows are excluded from the leave-loss absentee list
-- (RULE-014) and from billing-loss numerator/denominator (RULE-008).
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_absence (
      ABSENCE_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      FUSION_ABSENCE_ID VARCHAR2(50 CHAR),
      EMPLOYEE_ID       VARCHAR2(50 CHAR) NOT NULL,
      ABSENCE_DATE      DATE              NOT NULL,
      ABSENCE_TYPE      VARCHAR2(100 CHAR) NOT NULL,
      ABSENCE_HOURS     NUMBER(5,2) DEFAULT 0 NOT NULL,
      IS_LOP            CHAR(1) DEFAULT 'N' NOT NULL,
      IS_MATERNITY      CHAR(1) DEFAULT 'N' NOT NULL,
      APPROVAL_STATUS   VARCHAR2(30 CHAR) DEFAULT 'Approved' NOT NULL,
      FUSION_SYNCED_ON  TIMESTAMP,
      CREATED_BY        VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON        TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY        VARCHAR2(100),
      UPDATED_ON        TIMESTAMP,
      CONSTRAINT chk_oc_tabs_lop  CHECK (is_lop       IN ('Y','N')),
      CONSTRAINT chk_oc_tabs_mat  CHECK (is_maternity IN ('Y','N')),
      CONSTRAINT chk_oc_tabs_hrs  CHECK (absence_hours BETWEEN 0 AND 24),
      CONSTRAINT uk_oc_tabs_day   UNIQUE (employee_id, absence_date, absence_type),
      CONSTRAINT fk_oc_tabs_emp   FOREIGN KEY (employee_id)
        REFERENCES oc_time_worker(employee_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_ABSENCE created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_ABSENCE already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tabs_date ON oc_time_absence(absence_date, employee_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [6/6] Master-data audit triggers
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tw_audit
BEFORE INSERT OR UPDATE ON oc_time_worker
FOR EACH ROW
BEGIN
  IF INSERTING THEN :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE :NEW.updated_on := SYSTIMESTAMP;
       :NEW.created_on := :OLD.created_on; :NEW.created_by := :OLD.created_by; END IF;
END;
/
CREATE OR REPLACE TRIGGER trg_oc_tprj_audit
BEFORE INSERT OR UPDATE ON oc_time_project
FOR EACH ROW
BEGIN
  IF INSERTING THEN :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE :NEW.updated_on := SYSTIMESTAMP;
       :NEW.created_on := :OLD.created_on; :NEW.created_by := :OLD.created_by; END IF;
END;
/
CREATE OR REPLACE TRIGGER trg_oc_ttsk_audit
BEFORE INSERT OR UPDATE ON oc_time_task
FOR EACH ROW
BEGIN
  -- A non-billable task always carries its unbilled reason: the reason IS the
  -- task (RULE-002 note). Keeps FLD-013 populated without employee input.
  IF :NEW.billable_type = 'Non-billable' AND :NEW.unbilled_reason IS NULL THEN
    :NEW.unbilled_reason := :NEW.task_name;
  END IF;
  IF INSERTING THEN :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE :NEW.updated_on := SYSTIMESTAMP;
       :NEW.created_on := :OLD.created_on; :NEW.created_by := :OLD.created_by; END IF;
END;
/
CREATE OR REPLACE TRIGGER trg_oc_tal_audit
BEFORE INSERT OR UPDATE ON oc_time_allocation
FOR EACH ROW
BEGIN
  IF INSERTING THEN :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE :NEW.updated_on := SYSTIMESTAMP;
       :NEW.created_on := :OLD.created_on; :NEW.created_by := :OLD.created_by; END IF;
END;
/
CREATE OR REPLACE TRIGGER trg_oc_tabs_audit
BEFORE INSERT OR UPDATE ON oc_time_absence
FOR EACH ROW
BEGIN
  IF INSERTING THEN :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE :NEW.updated_on := SYSTIMESTAMP;
       :NEW.created_on := :OLD.created_on; :NEW.created_by := :OLD.created_by; END IF;
END;
/

PROMPT ============================================================
PROMPT [7/7] Master caches — sync provenance columns
PROMPT ============================================================

-- Which transport last wrote each cached row, and on which run.
--
-- FUSION_SYNCED_ON already recorded *when*. With master data arriving by two
-- routes -- a monthly BIP bulk extract and a daily REST delta (RA-007) -- the
-- *how* and *which run* are what make a stale or wrong row diagnosable. Without
-- them "this allocation looks wrong" has no audit trail back to a job.
--
-- SYNC_JOB_RUN_ID is deliberately a soft reference, not a foreign key:
--   * OC_TIME_SYNC_JOB is created later (06), so an FK would force a reordering
--     of the installer for no functional gain;
--   * job telemetry is purgeable. An FK would either block a purge or null out
--     provenance across millions of master rows when one ran.
--
-- Idempotent: ORA-01430 is "column already exists", so a re-run is a no-op.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(30);
  v_tables t_tab := t_tab('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                          'OC_TIME_ALLOCATION','OC_TIME_ABSENCE');
  TYPE t_col IS RECORD (name VARCHAR2(30), defn VARCHAR2(60));
  TYPE t_cols IS TABLE OF t_col;
  v_cols t_cols := t_cols(
    t_col('SOURCE_SYSTEM',   'VARCHAR2(30 CHAR)'),
    t_col('SOURCE_METHOD',   'VARCHAR2(10 CHAR)'),
    t_col('SYNC_JOB_RUN_ID', 'NUMBER'));
  v_added PLS_INTEGER := 0;
BEGIN
  FOR t IN 1 .. v_tables.COUNT LOOP
    FOR c IN 1 .. v_cols.COUNT LOOP
      BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || v_tables(t) ||
                          ' ADD ' || v_cols(c).name || ' ' || v_cols(c).defn;
        v_added := v_added + 1;
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
      END;
    END LOOP;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('provenance columns added: ' || v_added);
END;
/

-- Constrain the transport to the two we actually use, so a typo in an OIC
-- mapping fails loudly instead of quietly producing an un-groupable value.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(30);
  v_tables t_tab := t_tab('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                          'OC_TIME_ALLOCATION','OC_TIME_ABSENCE');
BEGIN
  FOR t IN 1 .. v_tables.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE ' || v_tables(t) ||
        ' ADD CONSTRAINT chk_' || LOWER(SUBSTR(v_tables(t), 4, 24)) || '_method' ||
        ' CHECK (source_method IN (''BIP'',''REST''))';
    EXCEPTION WHEN OTHERS THEN
      -- 2264/2275 = constraint name already used; 1430 handled above
      IF SQLCODE IN (-2264, -2275, -2261) THEN NULL; ELSE RAISE; END IF;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('source_method checks in place.');
END;
/

-- Reporting index: which rows did a given sync run touch?
BEGIN EXECUTE IMMEDIATE
  'CREATE INDEX ix_oc_tw_sync ON oc_time_worker(sync_job_run_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE
  'CREATE INDEX ix_oc_tal_sync ON oc_time_allocation(sync_job_run_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [8/8] OC_TIME_PROJECT — main O2C application project id
PROMPT ============================================================

-- MAIN_PROJECT_ID is OC_PROJECT.PROJECT_ID in the main O2C application.
--
-- It has to be stored because the two systems have completely separate id
-- spaces: ours is Fusion's PJF_PROJECTS_ALL_B.PROJECT_ID, theirs is an identity
-- column in their schema. The only thing common to both is the project NUMBER
-- (Fusion SEGMENT1 = OC_PROJECT.PROJECT_NUMBER, unique on both sides), so that
-- is the join, resolved once and cached here rather than looked up per push.
--
-- Left NULL until resolved. A project with no MAIN_PROJECT_ID cannot be pushed,
-- and V_OC_TS_O2C_PUSH_HEADER surfaces that as a blocked row rather than
-- silently dropping the month.
DECLARE
  v_n PLS_INTEGER := 0;
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE oc_time_project ADD main_project_id NUMBER';
    v_n := v_n + 1;
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
  END;
  BEGIN
    EXECUTE IMMEDIATE
      'ALTER TABLE oc_time_project ADD main_project_synced_on TIMESTAMP';
    v_n := v_n + 1;
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
  END;
  DBMS_OUTPUT.PUT_LINE('main O2C mapping columns added: ' || v_n);
END;
/

BEGIN EXECUTE IMMEDIATE
  'CREATE INDEX ix_oc_tprj_main ON oc_time_project(main_project_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT
PROMPT ============================================================
PROMPT time/02_time_master complete.
PROMPT ============================================================
