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
PROMPT [1/11] OC_TIME_WORKER — HCM worker / assignment cache
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
PROMPT [2/11] OC_TIME_PROJECT — PPM project cache
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
PROMPT [3/11] OC_TIME_TASK — WBS tasks + common non-billable tasks
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
PROMPT [4/11] OC_TIME_ALLOCATION — PPM resource assignment cache
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
PROMPT [5/11] OC_TIME_ABSENCE — HCM absence cache
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
PROMPT [6/11] Master-data audit triggers
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
PROMPT [7/11] Master caches — sync provenance columns
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
PROMPT [8/11] OC_TIME_PROJECT — main O2C application project id
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

PROMPT ============================================================
PROMPT [9/11] POET — expenditure type and organization (INT-007)
PROMPT ============================================================

-- An OTL time card is keyed on POET: Project / Organization / Expenditure type
-- / Task. This module had P and T and neither O nor E, so INT-007 could not be
-- built at all. These are the missing two.
--
-- WHERE EACH ONE LIVES, and why
--
-- EXPENDITURE_TYPE on OC_TIME_TASK. It classifies the work ("Professional
-- Labor", "Travel"), and in Fusion PPM it is a property of the WBS task, which
-- is also the grain the employee charges against. Putting it anywhere else
-- would mean deriving it, and a derivation that is wrong sends cost to the
-- wrong account.
--
-- EXPENDITURE_ORG on OC_TIME_WORKER, with an optional override on
-- OC_TIME_ALLOCATION. This is the organization that INCURS the cost, which is
-- normally the person's own — one value per person, not per line. But a person
-- lent to another delivery unit can have their cost booked there instead, so
-- the allocation carries a nullable override.
--
-- Resolution is NVL(allocation, worker), the same override shape
-- V_OC_TIME_SIGNIN already uses for the role. One rule, applied the same way
-- twice, rather than two different ideas of what an override means.
--
-- NOTE. LEGAL_EMPLOYER already on OC_TIME_WORKER is NOT this. That is the legal
-- entity that employs the person; the expenditure organization is the costing
-- unit the work is booked to. They are frequently different and Fusion treats
-- them as different things.
--
-- Both are left NULL. Nothing populates them yet — that needs either a BIP
-- extract change or a Fusion REST read, and until then V_OC_TIME_POET_READINESS
-- reports exactly what is missing rather than the push failing row by row.
DECLARE
  v_n PLS_INTEGER := 0;

  PROCEDURE add_col(p_table IN VARCHAR2, p_col IN VARCHAR2, p_type IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' ADD ' || p_col || ' ' || p_type;
    v_n := v_n + 1;
  EXCEPTION WHEN OTHERS THEN
    -- ORA-01430: already there. The whole point of a re-runnable script.
    IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
  END;
BEGIN
  add_col('oc_time_task',       'expenditure_type', 'VARCHAR2(80 CHAR)');
  add_col('oc_time_worker',     'expenditure_org',  'VARCHAR2(240 CHAR)');
  add_col('oc_time_allocation', 'expenditure_org',  'VARCHAR2(240 CHAR)');

  DBMS_OUTPUT.PUT_LINE('POET columns added: ' || v_n || ' (0 = already present)');
END;
/

PROMPT ============================================================
PROMPT [10/11] Inbound guards — time-entry filter, contractor PO
PROMPT ============================================================

-- Two columns the real Fusion sync needs and the twelve-row test seed never
-- exposed. Both from doc/CrewRite_Reuse_Assessment.md, where they are recorded
-- as verified-absent gaps.
--
-- TIME_ENTRY_ENABLED (§2.4) — WITHOUT THIS THE PROJECT PICKER IS UNUSABLE.
-- We filter projects on status = 'Active' alone. In a real instance that is
-- every active project in the enterprise: this pod has 423, against the four in
-- the seed. All of them would reach V_OC_TS_TASK_LOV and the employee's project
-- picker, including projects nobody charges time to. CrewRite solved it with a
-- 'Crew Time Entry Enabled' flag (CR-B-BR08) and the same shape works here.
--
-- Defaults to 'N', deliberately. A project appears for time entry only when
-- something says it should, so a newly synced project cannot silently widen
-- what employees can charge to. That does mean the sync must set it — which is
-- exactly the point of a default that fails closed.
--
-- PO_NUMBER / PO_LINE_NUMBER / PRICE_TYPE (§2.5) — contingent workers.
-- We model contractors and RULE-021 gives their unbilled hours an exception
-- path, but we hold no purchase-order reference. CrewRite makes PO mandatory
-- when the system person type is CWK, because that time creates AP receipts by
-- pass-through. This also gives RA-012 something concrete: contractors are
-- excluded from salary stopping precisely because their pay is invoice-driven,
-- and a PO is what makes invoice-driven time actionable.
--
-- Nullable, and not constrained to Contractor here: the check belongs in
-- OC_TIME_PKG with the other rules, not in the DDL, so it can carry a message.
DECLARE
  v_n PLS_INTEGER := 0;

  PROCEDURE add_col(p_table IN VARCHAR2, p_col IN VARCHAR2, p_type IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' ADD ' || p_col || ' ' || p_type;
    v_n := v_n + 1;
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
  END;
BEGIN
  add_col('oc_time_project',    'time_entry_enabled', 'CHAR(1) DEFAULT ''N''');
  add_col('oc_time_allocation', 'po_number',          'VARCHAR2(60 CHAR)');
  add_col('oc_time_allocation', 'po_line_number',     'VARCHAR2(30 CHAR)');
  add_col('oc_time_allocation', 'price_type',         'VARCHAR2(30 CHAR)');

  DBMS_OUTPUT.PUT_LINE('inbound guard columns added: ' || v_n);
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_time_project ADD CONSTRAINT ' ||
    'chk_oc_tprj_tee CHECK (time_entry_enabled IN (''Y'',''N''))';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-2264, -2275, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/

-- The seeded test projects predate the flag and would vanish from the picker
-- the moment it starts being enforced. Only the four PRJ-% rows the test seed
-- created — a real synced project stays 'N' until the sync says otherwise.
UPDATE oc_time_project
   SET time_entry_enabled = 'Y'
 WHERE project_number LIKE 'PRJ-%'
   AND NVL(time_entry_enabled,'N') = 'N';
COMMIT;

PROMPT ============================================================
PROMPT [11/11] POET readiness view
PROMPT ============================================================

-- What is stopping the OTL push, per project.
--
-- Built as a view rather than left to fail at push time because the answer is
-- an administrator's to act on, not a developer's to read out of a log: a task
-- with no expenditure type needs someone to set one in Fusion, and they need to
-- know which tasks before they start.
--
-- Deliberately counts only what would ACTUALLY be pushed. A non-chargeable task
-- nobody books to does not block anything, and neither does leave — absences
-- reach OTL from Absence Management already, so INT-007 filters IS_LEAVE = 'Y'
-- and re-sending them would double-count.
CREATE OR REPLACE VIEW v_oc_time_poet_readiness AS
SELECT p.project_id,
       p.project_number,
       p.project_name,
       p.status                                            AS project_status,
       COUNT(DISTINCT t.task_id)                           AS tasks_chargeable,
       COUNT(DISTINCT CASE WHEN t.expenditure_type IS NULL
                           THEN t.task_id END)             AS tasks_no_exp_type,
       COUNT(DISTINCT a.employee_id)                       AS workers_allocated,
       COUNT(DISTINCT CASE WHEN NVL(a.expenditure_org, w.expenditure_org) IS NULL
                           THEN a.employee_id END)         AS workers_no_exp_org,
       CASE
         WHEN COUNT(DISTINCT CASE WHEN t.expenditure_type IS NULL
                                  THEN t.task_id END) > 0
           OR COUNT(DISTINCT CASE WHEN NVL(a.expenditure_org, w.expenditure_org) IS NULL
                                  THEN a.employee_id END) > 0
         THEN 'Blocked'
         ELSE 'Ready'
       END                                                 AS otl_readiness
  FROM oc_time_project    p
  LEFT JOIN oc_time_task  t ON t.project_id  = p.project_id
                           AND t.status      = 'Active'
                           AND t.chargeable_flag = 'Y'
  LEFT JOIN oc_time_allocation a ON a.project_id = p.project_id
                                AND a.status     = 'Active'
  LEFT JOIN oc_time_worker w ON w.employee_id = a.employee_id
 WHERE p.status = 'Active'
 GROUP BY p.project_id, p.project_number, p.project_name, p.status;

PROMPT
PROMPT ============================================================
PROMPT time/02_time_master complete.
PROMPT ============================================================
