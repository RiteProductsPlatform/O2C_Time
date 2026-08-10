--==============================================================
-- install_time_ALL.sql
--
-- GENERATED FILE - DO NOT EDIT.
-- Produced by db/build_install_all.py from install_time.sql and the 25
-- scripts it includes. Edit those and re-run the generator.
--
-- This is install_time.sql with every @@include expanded inline, so it runs
-- anywhere: SQL Developer (opened or pasted), SQLcl, or SQL*Plus. The include
-- form is fragile in SQL Developer when the path contains a space, and this
-- repository lives under "OneDrive - RITE/.../Time Module/".
--
-- RUNNING IT IN SQL DEVELOPER
--   1. Open this file, or paste the whole thing into a worksheet.
--   2. Connect as the O2C_TIME schema owner.
--   3. Press F5 - "Run Script". NOT Ctrl+Enter, which executes one statement
--      and will look like it worked.
--   4. Watch the Script Output pane. The verification block at the end lists
--      every object and its status; nothing should be INVALID.
--
--   WHENEVER SQLERROR EXIT FAILURE ROLLBACK is left in on purpose: an installer
--   should stop at the first real failure rather than carry on and leave a
--   half-built schema. In SQL Developer that also DISCONNECTS the worksheet,
--   which looks alarming and is not damage - reconnect and read the last error
--   in the output. Every script is idempotent, so re-running after a fix is
--   safe and is the intended way to recover.
--==============================================================

--==============================================================
-- install_time.sql
-- O2C Timesheet Module — full install, in dependency order
--
-- Run from THIS directory as the O2C Time schema owner:
--     sqlplus o2c_time/<pwd>@<tns> @install_time.sql
--
-- Every script is idempotent, so re-running the installer is safe and is the
-- normal way to apply changes. Nothing is dropped.
--
-- ── Prerequisites, all run as ADMIN (not as O2C_TIME) ────────
--
-- 1. Privileges. RESOURCE does NOT include CREATE VIEW, and this module builds
--    24 of them — without the explicit grant the install dies at 01 step [7/8]
--    with ORA-01031 after the tables have already succeeded.
--
--     GRANT CONNECT, RESOURCE TO O2C_TIME;
--     GRANT CREATE VIEW       TO O2C_TIME;
--     ALTER USER O2C_TIME QUOTA UNLIMITED ON DATA;   -- ADB tablespace is DATA
--
--    No DBMS_CRYPTO grant is needed. Sign-in hashes with STANDARD_HASH, a SQL
--    built-in that produces byte-identical SHA-256, and mints session tokens
--    with oc_time_new_token. The token generator is weaker than
--    DBMS_CRYPTO.RANDOMBYTES and says so in 11_auth.sql — restore it before
--    PROD (one line, plus the grant).
--
-- 2. REST-enable the schema, or the ORDS modules in 12..15 cannot publish and
--    every endpoint 404s. On Autonomous Database use ORDS_ADMIN as ADMIN —
--    the classic ORDS.ENABLE_SCHEMA cannot enable a schema other than the
--    caller's own unless the caller holds ORDS_ADMINISTRATOR_ROLE, which is
--    why it raises ORA-01031 there.
--
--     BEGIN
--       ORDS_ADMIN.ENABLE_SCHEMA(p_enabled => TRUE,
--                                p_schema  => 'O2C_TIME',
--                                p_url_mapping_type    => 'BASE_PATH',
--                                p_url_mapping_pattern => 'o2c_time',
--                                p_auto_rest_auth      => FALSE);
--       COMMIT;
--     END;
--     /
--
--    On a non-Autonomous ORDS install the equivalent is ORDS.ENABLE_SCHEMA,
--    run either as the schema owner or by a caller with ORDS_ADMINISTRATOR_ROLE.
--
-- RA-002: p_auto_rest_auth FALSE plus anonymous access is acceptable in lower
-- environments only. Harden to https + API key / OAuth2 before PROD.
--==============================================================
--==============================================================
-- RUNNING THIS IN SQL DEVELOPER — use install_time_ALL.sql instead
--==============================================================
-- The @@ includes below are resolved by SQL*Plus relative to this file. SQL
-- Developer only does the same when the script has been OPENED FROM A FILE and
-- run with F5 (Run Script) — and it does not quote the path it builds, so a
-- directory containing a space breaks the include. This repository lives under
-- "OneDrive - RITE/O2C/Time Module/...", which has two. The failure is quiet:
-- the includes are skipped, the run reports success, and nothing is created.
--
-- db/install_time_ALL.sql is this file with all 18 scripts expanded inline. It
-- has no includes, so it runs the same opened, pasted, or through SQLcl, on any
-- path. Regenerate it with `python db/build_install_all.py` after changing the
-- install order or any script in it.
--
-- Either way: F5 (Run Script), never Ctrl+Enter — Run Statement executes a
-- single statement and will look like it worked.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET FEEDBACK ON
-- Stops at the first real failure rather than leaving a half-built schema. In
-- SQL Developer this also disconnects the worksheet, which looks alarming and
-- is not damage: reconnect, read the last error, fix it, re-run. Every script
-- is idempotent, so re-running is the intended way to recover.
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT
PROMPT ##############################################################
PROMPT #  O2C TIMESHEET MODULE - INSTALL
PROMPT ##############################################################
PROMPT

-- ── Pre-flight: privileges ───────────────────────────────────
-- Reported up front because the failure is otherwise misleading: RESOURCE
-- grants CREATE TABLE but not CREATE VIEW, so scripts 01 and 02 build their
-- tables, then 01 step [7/8] dies on the first view with a bare ORA-01031 — by
-- which point it looks like the DDL is at fault rather than the grant.
--
-- A WARNING, NOT A GATE — and that is deliberate (01-Aug-2026).
--
-- This block used to RAISE, and it stopped a perfectly good install dead. The
-- tell was that it named CREATE TABLE / SEQUENCE / TRIGGER / PROCEDURE but not
-- CREATE VIEW: the first four come from the RESOURCE role, CREATE VIEW had been
-- granted directly. SESSION_PRIVS shows only what is enabled in the CURRENT
-- session, so wherever roles are not enabled — some tool connections, and any
-- definer's-rights context — every role-derived privilege reads as missing
-- while direct grants read as present.
--
-- So the query below also looks through the roles granted to the user. But a
-- pre-flight that cannot be trusted must not be able to block: if it is wrong
-- again, the real DDL fails immediately afterwards with a specific ORA-01031 on
-- the exact object, which is a better diagnostic than a guess made up front.
DECLARE
  v_missing VARCHAR2(400);

  PROCEDURE need(p_priv IN VARCHAR2) IS
    v_cnt PLS_INTEGER;
  BEGIN
    -- Three sources: the session, privileges granted directly to the user, and
    -- privileges reachable through any role granted to them. The last is what
    -- SESSION_PRIVS alone misses when roles are not enabled.
    SELECT COUNT(*) INTO v_cnt FROM (
      SELECT privilege FROM session_privs
      UNION
      SELECT privilege FROM user_sys_privs
      UNION
      SELECT rsp.privilege
        FROM role_sys_privs  rsp
        JOIN user_role_privs urp ON urp.granted_role = rsp.role
    ) WHERE privilege = p_priv;

    IF v_cnt = 0 THEN v_missing := v_missing || p_priv || ', '; END IF;
  END;
BEGIN
  need('CREATE TABLE');
  need('CREATE VIEW');
  need('CREATE SEQUENCE');
  need('CREATE TRIGGER');
  need('CREATE PROCEDURE');

  -- DBMS_CRYPTO is deliberately NOT required. Sign-in uses STANDARD_HASH for
  -- passwords and oc_time_new_token for session tokens, both of which need no
  -- grant. See the security note in 11_auth.sql: the hash side is an exact
  -- substitution, the token side is weaker and is recorded as debt.

  IF v_missing IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('WARNING: could not confirm ' ||
      RTRIM(v_missing, ', ') || ' for ' || USER || '.');
    DBMS_OUTPUT.PUT_LINE(
      '         The install continues. If a privilege really is missing the');
    DBMS_OUTPUT.PUT_LINE(
      '         next script fails with ORA-01031 naming the object. To grant:');
    DBMS_OUTPUT.PUT_LINE('           GRANT CONNECT, RESOURCE TO ' || USER || ';');
    DBMS_OUTPUT.PUT_LINE('           GRANT CREATE VIEW       TO ' || USER || ';');
    DBMS_OUTPUT.PUT_LINE('           ALTER USER ' || USER ||
                         ' QUOTA UNLIMITED ON DATA;');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Privileges OK for ' || USER || '.');
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Even the check failing must not stop the install.
  DBMS_OUTPUT.PUT_LINE('NOTE: privilege pre-flight could not run - ' ||
                       SUBSTR(SQLERRM, 1, 150));
END;
/

-- ── Pre-flight: REST enablement ──────────────────────────────
-- A warning, not a failure. The schema objects install perfectly well without
-- ORDS; only the modules in 11..13 need it, and they are the last thing to run.
DECLARE
  v_n PLS_INTEGER := 0;
BEGIN
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_ords_schemas' INTO v_n;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'WARNING: ' || USER || ' is not REST-enabled, so the ORDS modules will '
      || 'not publish and every endpoint will return 404.');
    DBMS_OUTPUT.PUT_LINE(
      '         As ADMIN: ORDS_ADMIN.ENABLE_SCHEMA(p_schema => ''' || USER
      || ''', ...) — see the header.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Schema is REST-enabled.');
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- USER_ORDS_SCHEMAS is absent when ORDS is not installed at all. Not fatal.
  DBMS_OUTPUT.PUT_LINE(
    'NOTE: could not read USER_ORDS_SCHEMAS — REST enablement unverified.');
END;
/

-- ── Schema objects ───────────────────────────────────────────
PROMPT >>> 01 reference (lookup, period, calendar, config)

--==============================================================
-- BEGIN 01_time_reference.sql
--==============================================================
--==============================================================
-- time/01_time_reference.sql
-- O2C Timesheet Module — Reference data
--
--   OC_TIME_LOOKUP   = code/value dictionary (Data_Dictionaries sheet):
--                      9 timesheet statuses, 8 workflow flags, rejection
--                      reasons, unbilled reasons, shift types, entry types.
--   OC_TIME_PERIOD   = Period Control (PAGE-008). REFERENCE DATA ONLY — the
--                      module has no admin screen for it (removed 29-Jul), but
--                      its cut-off dates drive the employee cut-off display
--                      (FLD-003) and the manager all-cut-offs panel (FLD-036).
--   OC_TIME_CALENDAR = the four calendar layers with precedence
--                      Shift > Client > Project > Corporate (PROC-013).
--
-- Requirement refs: PROC-012, PROC-013, PAGE-008, PAGE-009,
--                   FLD-075..FLD-096, RULE-017, RULE-018
-- Idempotent. No dependencies.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/8] OC_TIME_LOOKUP — code/value dictionary
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_lookup (
      LOOKUP_ID     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      LOOKUP_TYPE   VARCHAR2(40 CHAR)  NOT NULL,
      LOOKUP_CODE   VARCHAR2(60 CHAR)  NOT NULL,
      MEANING       VARCHAR2(200 CHAR) NOT NULL,
      USAGE_NOTE    VARCHAR2(400 CHAR),
      SORT_ORDER    NUMBER(4)          DEFAULT 100 NOT NULL,
      SELECTABLE    CHAR(1)            DEFAULT 'Y' NOT NULL,
      ACTIVE_FLAG   CHAR(1)            DEFAULT 'Y' NOT NULL,
      CREATED_BY    VARCHAR2(100)      DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON    TIMESTAMP          DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY    VARCHAR2(100),
      UPDATED_ON    TIMESTAMP,
      CONSTRAINT chk_oc_tl_selectable CHECK (selectable  IN ('Y','N')),
      CONSTRAINT chk_oc_tl_active     CHECK (active_flag IN ('Y','N')),
      CONSTRAINT uk_oc_tl_type_code   UNIQUE (lookup_type, lookup_code)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_LOOKUP created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_LOOKUP already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tl_type ON oc_time_lookup(lookup_type, active_flag, sort_order)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/8] OC_TIME_PERIOD — Period Control (reference data)
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_period (
      PERIOD_ID                NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      PERIOD_NAME              VARCHAR2(30 CHAR) NOT NULL,   -- FLD-075 'JUL-2026'
      PERIOD_YEAR              NUMBER(4)         NOT NULL,
      PERIOD_MONTH             NUMBER(2)         NOT NULL,
      STATUS                   VARCHAR2(10 CHAR) DEFAULT 'Closed' NOT NULL, -- FLD-076
      START_DATE               DATE              NOT NULL,   -- FLD-077
      END_DATE                 DATE              NOT NULL,   -- FLD-078
      ACCOUNTING_DATE          DATE              NOT NULL,   -- FLD-079
      -- Cut-offs (FLD-080..FLD-086, FLD-089) — cutoff_type dictionary:
      -- Weekly / Delivery / Finance / Book / MEC / Payroll / Client
      TS_CUTOFF_DAY            VARCHAR2(10 CHAR),            -- FLD-086 e.g. 'Monday'
      TS_CUTOFF_TIME           VARCHAR2(5 CHAR),             -- FLD-086 e.g. '17:00'
      DELIVERY_CUTOFF          DATE,                         -- FLD-080
      FINANCE_CUTOFF           DATE,                         -- FLD-081
      BOOK_CLOSURE             DATE,                         -- FLD-082
      MEC_CLOSE                DATE,                         -- FLD-083
      CLIENT_CUTOFF            DATE,                         -- FLD-085
      PAYROLL_COUNTRY          VARCHAR2(60 CHAR),            -- FLD-088
      PAYROLL_CUTOFF           DATE,                         -- FLD-089
      -- Flags & windows
      ADVANCE_CLOSE            CHAR(1)   DEFAULT 'N' NOT NULL, -- FLD-084
      CONTRACTOR_RESUBMIT_DAYS NUMBER(4) DEFAULT 60,           -- FLD-087
      HOLD_RELEASE_DAYS        NUMBER(4) DEFAULT 60,           -- FLD-090 / CFG-012
      ADJUSTMENT_MONTHS        NUMBER(2) DEFAULT 3  NOT NULL,  -- FLD-091 / CFG-011
      BACKDATED_MONTHS         NUMBER(2) DEFAULT 3  NOT NULL,  -- FLD-092
      CREATED_BY               VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON               TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY               VARCHAR2(100),
      UPDATED_ON               TIMESTAMP,
      CONSTRAINT chk_oc_tp_status   CHECK (status IN ('Open','Closed')),
      CONSTRAINT chk_oc_tp_month    CHECK (period_month BETWEEN 1 AND 12),
      CONSTRAINT chk_oc_tp_advclose CHECK (advance_close IN ('Y','N')),
      CONSTRAINT chk_oc_tp_dates    CHECK (end_date >= start_date),
      CONSTRAINT uk_oc_tp_name      UNIQUE (period_name),
      CONSTRAINT uk_oc_tp_ym        UNIQUE (period_year, period_month, payroll_country)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_PERIOD created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_PERIOD already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- RULE-017 ("only one period may be Open at a time") was RELAXED on
-- 04-Aug-2026, by decision: July and August are held open together.
--
-- UK_OC_TP_SINGLE_OPEN used to enforce it — a function-based unique index where
-- 'OPEN' was indexed only for Open rows, so a second Open row raised
-- DUP_VAL_ON_INDEX. It is NOT created any more, and db/13_open_periods.sql
-- drops it where it already exists. Re-creating it here would silently undo the
-- decision the next time this script runs, which is why it is commented out
-- rather than deleted.
--
--   BEGIN
--     EXECUTE IMMEDIATE q'[
--       CREATE UNIQUE INDEX uk_oc_tp_single_open
--         ON oc_time_period (CASE WHEN status = 'Open' THEN 'OPEN' END)
--     ]';
--   EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
--   /
--
-- With the rule gone, "the open period" is a choice: get_open_period_id takes
-- the open month containing today, else the earliest open one, and
-- get_period_for_date is preferred wherever the caller knows its date.

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tp_ym ON oc_time_period(period_year, period_month)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/8] OC_TIME_PERIOD — no-overlap + audit trigger (RULE-018)
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tp_audit
BEFORE INSERT OR UPDATE ON oc_time_period
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE
    :NEW.updated_on := SYSTIMESTAMP;
    :NEW.created_on := :OLD.created_on;
    :NEW.created_by := :OLD.created_by;
  END IF;
END;
/

-- RULE-018: periods cannot overlap. Statement-level check over the rows just
-- touched, so it can query the table without ORA-04091 (mutating table).
CREATE OR REPLACE TRIGGER trg_oc_tp_no_overlap
FOR INSERT OR UPDATE OF start_date, end_date, payroll_country ON oc_time_period
COMPOUND TRIGGER
  TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  g_ids t_ids;

AFTER EACH ROW IS
BEGIN
  g_ids(:NEW.period_id) := :NEW.period_id;
END AFTER EACH ROW;

AFTER STATEMENT IS
  v_id  NUMBER;
  v_cnt NUMBER;
BEGIN
  v_id := g_ids.FIRST;
  WHILE v_id IS NOT NULL LOOP
    SELECT COUNT(*)
      INTO v_cnt
      FROM oc_time_period a
      JOIN oc_time_period b
        ON b.period_id <> a.period_id
       AND NVL(b.payroll_country,'~') = NVL(a.payroll_country,'~')
       AND b.start_date <= a.end_date
       AND b.end_date   >= a.start_date
     WHERE a.period_id = v_id;

    IF v_cnt > 0 THEN
      RAISE_APPLICATION_ERROR(-20018,
        'Period dates overlap an existing period.');   -- RULE-018 error_message
    END IF;
    v_id := g_ids.NEXT(v_id);
  END LOOP;
END AFTER STATEMENT;
END trg_oc_tp_no_overlap;
/

PROMPT ============================================================
PROMPT [4/8] OC_TIME_CALENDAR — four layers with precedence
PROMPT ============================================================

-- PROC-013 / PAGE-009. One row per (layer, scope, date).
--   LAYER      CORPORATE | PROJECT | CLIENT | SHIFT
--   PRECEDENCE 1=Corporate (lowest) .. 4=Shift (highest)
--   SCOPE_KEY  CORPORATE -> country or country|city   (FLD-093)
--              CLIENT    -> customer id/name          (FLD-094)
--              PROJECT   -> project_id + country      (FLD-095)
--              SHIFT     -> employee_id               (FLD-096)
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_calendar (
      CALENDAR_ID    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      LAYER          VARCHAR2(12 CHAR)  NOT NULL,
      PRECEDENCE     NUMBER(1)          NOT NULL,
      SCOPE_KEY      VARCHAR2(120 CHAR) NOT NULL,
      CAL_DATE       DATE               NOT NULL,
      IS_WORKING_DAY CHAR(1)            DEFAULT 'Y' NOT NULL,
      STD_HOURS      NUMBER(4,2),
      HOLIDAY_NAME   VARCHAR2(200 CHAR),
      SHIFT_CODE     VARCHAR2(20 CHAR),
      SOURCE_SYSTEM  VARCHAR2(30 CHAR),
      SOURCE_METHOD  VARCHAR2(10 CHAR),             -- BIP | REST
      SYNC_JOB_RUN_ID NUMBER,                       -- soft ref: OC_TIME_SYNC_JOB
      SYNCED_ON      TIMESTAMP,
      CREATED_BY     VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY     VARCHAR2(100),
      UPDATED_ON     TIMESTAMP,
      CONSTRAINT chk_oc_tc_layer   CHECK (layer IN ('CORPORATE','PROJECT','CLIENT','SHIFT')),
      CONSTRAINT chk_oc_tc_prec    CHECK (precedence BETWEEN 1 AND 4),
      CONSTRAINT chk_oc_tc_working CHECK (is_working_day IN ('Y','N')),
      CONSTRAINT chk_oc_tc_hours   CHECK (std_hours IS NULL OR std_hours BETWEEN 0 AND 24),
      CONSTRAINT uk_oc_tc_scope    UNIQUE (layer, scope_key, cal_date)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_CALENDAR created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_CALENDAR already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tc_date ON oc_time_calendar(cal_date, layer)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [5/8] OC_TIME_CALENDAR — precedence defaulting trigger
PROMPT ============================================================

-- Keeps PRECEDENCE consistent with LAYER so V_OC_TIME_CALENDAR_EFF can resolve
-- the effective day with a single ORDER BY (Shift > Client > Project > Corporate).
CREATE OR REPLACE TRIGGER trg_oc_tc_precedence
BEFORE INSERT OR UPDATE ON oc_time_calendar
FOR EACH ROW
BEGIN
  :NEW.precedence := CASE :NEW.layer
                       WHEN 'SHIFT'     THEN 4
                       WHEN 'CLIENT'    THEN 3
                       WHEN 'PROJECT'   THEN 2
                       ELSE 1                       -- CORPORATE
                     END;
  IF INSERTING THEN
    :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE
    :NEW.updated_on := SYSTIMESTAMP;
    :NEW.created_on := :OLD.created_on;
    :NEW.created_by := :OLD.created_by;
  END IF;
END;
/

PROMPT ============================================================
PROMPT [6/8] OC_TIME_CONFIG — environment / business config
PROMPT ============================================================

-- Environment_Config sheet (CFG-010..CFG-015). Business values only; secrets
-- stay in OCI Vault and are never stored here.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_time_config (
      CONFIG_ID    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      CONFIG_NAME  VARCHAR2(60 CHAR)  NOT NULL,
      CONFIG_TYPE  VARCHAR2(20 CHAR)  DEFAULT 'business' NOT NULL,
      CONFIG_VALUE VARCHAR2(400 CHAR),
      SCOPE_KEY    VARCHAR2(60 CHAR)  DEFAULT 'GLOBAL' NOT NULL,
      DESCRIPTION  VARCHAR2(400 CHAR),
      CREATED_BY   VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY   VARCHAR2(100),
      UPDATED_ON   TIMESTAMP,
      CONSTRAINT chk_oc_tcfg_type CHECK (config_type IN
        ('business','feature_flag','timeout','endpoint')),
      CONSTRAINT uk_oc_tcfg_name  UNIQUE (config_name, scope_key)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_CONFIG created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_CONFIG already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [7/8] V_OC_TIME_CALENDAR_EFF — effective calendar day
PROMPT ============================================================

-- Resolves the four layers into one effective day per (employee scope, date)
-- using precedence Shift > Client > Project > Corporate (PROC-013 / SC-21).
-- Callers pass the scope keys they know; the highest-precedence matching row
-- wins. Consumed by OC_TIME_PKG.resolve_day and the population job.
CREATE OR REPLACE VIEW v_oc_time_calendar_eff AS
SELECT scope_key,
       cal_date,
       layer,
       precedence,
       is_working_day,
       std_hours,
       holiday_name,
       shift_code,
       ROW_NUMBER() OVER (PARTITION BY scope_key, cal_date
                              ORDER BY precedence DESC) AS rn
  FROM oc_time_calendar;

PROMPT ============================================================
PROMPT [8/8] V_OC_TIME_CUTOFFS — cut-off panel projection
PROMPT ============================================================

-- FLD-003 (employee weekly cut-off) and FLD-036 (manager all-cut-offs panel).
-- One row per period with every cut-off the Period Definition doc defines.
CREATE OR REPLACE VIEW v_oc_time_cutoffs AS
SELECT p.period_id,
       p.period_name,
       p.period_year,
       p.period_month,
       p.status,
       p.payroll_country,
       TO_CHAR(p.start_date,      'YYYY-MM-DD') AS start_date,
       TO_CHAR(p.end_date,        'YYYY-MM-DD') AS end_date,
       TO_CHAR(p.accounting_date, 'YYYY-MM-DD') AS accounting_date,
       p.ts_cutoff_day,
       p.ts_cutoff_time,
       p.ts_cutoff_day || ' ' || p.ts_cutoff_time AS weekly_cutoff_display,
       TO_CHAR(p.delivery_cutoff, 'YYYY-MM-DD') AS delivery_cutoff,
       TO_CHAR(p.finance_cutoff,  'YYYY-MM-DD') AS finance_cutoff,
       TO_CHAR(p.book_closure,    'YYYY-MM-DD') AS book_closure,
       TO_CHAR(p.mec_close,       'YYYY-MM-DD') AS mec_close,
       TO_CHAR(p.client_cutoff,   'YYYY-MM-DD') AS client_cutoff,
       TO_CHAR(p.payroll_cutoff,  'YYYY-MM-DD') AS payroll_cutoff,
       p.advance_close,
       p.adjustment_months,
       p.backdated_months,
       p.hold_release_days,
       p.contractor_resubmit_days
  FROM oc_time_period p;

PROMPT
PROMPT ============================================================
PROMPT time/01_time_reference complete.
PROMPT ============================================================
--== END 01_time_reference.sql ==

PROMPT >>> 02 master (worker, project, task, allocation, absence)

--==============================================================
-- BEGIN 02_time_master.sql
--==============================================================
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
--
-- And only projects in scope for time entry. Without that gate this reported on
-- 428 projects of which 350 were 'Blocked' — every one of them a project nobody
-- tracks time against, so nothing about them was ever going to be pushed. A
-- readiness list is only useful if every row on it is worth acting on.
CREATE OR REPLACE VIEW v_oc_time_poet_readiness AS
WITH cfg AS (
  -- The configured fallback. Verified 02-Aug-2026 that this pod has no
  -- transaction controls, so expenditure type is NOT a per-task attribute here
  -- and OC_TIME_TASK.EXPENDITURE_TYPE is null for every row. Counting that as
  -- 'Blocked' made the panel report 49 of 50 projects blocked by a column that
  -- is never going to be populated — which is precisely the noise a readiness
  -- list exists to avoid.
  --
  -- A task is only really blocked when NEITHER the task NOR the config supplies
  -- one. The OTL push must resolve it the same way, NVL(task, config), or the
  -- panel and the push will disagree about what is ready.
  SELECT MAX(config_value) AS default_exp_type
    FROM oc_time_config
   WHERE config_name = 'defaultExpenditureType'
)
SELECT p.project_id,
       p.project_number,
       p.project_name,
       p.status                                            AS project_status,
       COUNT(DISTINCT t.task_id)                           AS tasks_chargeable,
       -- Reported so the gap stays visible even when config covers it: an
       -- administrator who wants per-task coding needs to see how much is
       -- riding on the default.
       COUNT(DISTINCT CASE WHEN t.expenditure_type IS NULL
                           THEN t.task_id END)             AS tasks_no_exp_type,
       COUNT(DISTINCT CASE WHEN NVL(t.expenditure_type,
                                    (SELECT default_exp_type FROM cfg)) IS NULL
                           THEN t.task_id END)             AS tasks_unresolvable,
       COUNT(DISTINCT a.employee_id)                       AS workers_allocated,
       COUNT(DISTINCT CASE WHEN NVL(a.expenditure_org, w.expenditure_org) IS NULL
                           THEN a.employee_id END)         AS workers_no_exp_org,
       CASE
         WHEN COUNT(DISTINCT CASE WHEN NVL(t.expenditure_type,
                                           (SELECT default_exp_type FROM cfg)) IS NULL
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
   AND (p.time_entry_enabled = 'Y' OR p.project_type = 'Organization')
 GROUP BY p.project_id, p.project_number, p.project_name, p.status;

PROMPT
PROMPT ============================================================
PROMPT time/02_time_master complete.
PROMPT ============================================================
--== END 02_time_master.sql ==

PROMPT >>> 03 timesheet (week, entry, grid views)

--==============================================================
-- BEGIN 03_timesheet.sql
--==============================================================
--==============================================================
-- time/03_timesheet.sql
-- O2C Timesheet Module — Transactional core
--
--   OC_TS_WEEK  = one row per employee per week. Carries the week status
--                 (7-value dictionary) and the 5 workflow flags.
--   OC_TS_ENTRY = the grid cell: employee x project x task x calendar day.
--                 One row per day per project-task line, so multi-line /
--                 multi-task per day works (ACT-003, SC-03) and day-level
--                 approval/rejection has somewhere to live (ACT-017).
--
-- Why the week is the header: the employee submits weekly (PROC-002) and the
-- manager approves at day, week or month granularity (PROC-003). Month is
-- derived by aggregating weeks, so nothing is stored twice.
--
-- Requirement refs: PROC-002, PROC-004, PROC-005, PAGE-001, PAGE-005,
--                   FLD-004, FLD-009..FLD-015, FLD-048..FLD-059,
--                   RULE-003, RULE-005, RULE-009, RULE-012,
--                   Data_Dictionaries timesheet_status (7) + flag (5)
--                   — revised 30-Jul-2026, see the WEEK_STATUS note below
-- Idempotent. Depends on: time/01, time/02
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/8] OC_TS_WEEK — weekly header
PROMPT ============================================================

-- WEEK_STATUS — 7 statuses (revised 30-Jul-2026, down from 9):
--   'Not yet submitted' | 'Submitted' | 'Approved' | 'Rejected'
--   'Defaulted'         | 'Overridden and approved' | 'Closed'
--
-- Two statuses were removed in that revision, for different reasons:
--
--   * 'Late submission'  -> became a FLAG, not a status. A week submitted after
--     the weekly cut-off is still 'Submitted', because the manager has to act on
--     it either way; LATE_SUBMISSION_FLAG records the SLA miss.
--
--   * 'Manager Defaulted'-> folded into 'Defaulted'. Only two cut-offs matter to
--     a timesheet — Weekly (the employee's) and Delivery (the manager's) — and
--     missing either, or both, flags the week Defaulted. DEFAULTED_BY records
--     which party caused it.
--
-- And one flag was dropped:
--   * 'Correction'       -> a resubmission after rejection is simply 'Submitted'.
--     The fact that it WAS a correction lives in OC_TS_APPROVAL as a 'Resubmit'
--     action, which is the audit trail.
--
-- Consequence worth stating: 'Defaulted' is now set ONLY by the two defaulting
-- jobs. submit_week never produces it, so an employee action can no longer put
-- their own week into a defaulted state — submitting late gets them 'Submitted'
-- plus a flag.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_week (
      TS_WEEK_ID       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EMPLOYEE_ID      VARCHAR2(50 CHAR) NOT NULL,
      PERIOD_ID        NUMBER            NOT NULL,
      PERIOD_YEAR      NUMBER(4)         NOT NULL,
      PERIOD_MONTH     NUMBER(2)         NOT NULL,
      WEEK_INDEX       NUMBER(2)         NOT NULL,   -- FLD-002 / FLD-049
      WEEK_START       DATE              NOT NULL,   -- Monday
      WEEK_END         DATE              NOT NULL,   -- Sunday
      WEEK_STATUS      VARCHAR2(30 CHAR) DEFAULT 'Not yet submitted' NOT NULL,
      -- Rolled up from OC_TS_ENTRY by TRG_OC_TSW_TOTALS
      BILLABLE_HOURS     NUMBER(8,2) DEFAULT 0 NOT NULL,
      NON_BILLABLE_HOURS NUMBER(8,2) DEFAULT 0 NOT NULL,
      LEAVE_HOURS        NUMBER(8,2) DEFAULT 0 NOT NULL,
      BILLING_LOSS_HOURS NUMBER(8,2) DEFAULT 0 NOT NULL, -- FLD-015 / RULE-009
      TOTAL_HOURS        NUMBER(8,2) DEFAULT 0 NOT NULL,
      STANDARD_HOURS     NUMBER(8,2) DEFAULT 0 NOT NULL, -- corporate std for the week
      -- The 6 workflow flags (revised 30-Jul-2026, down from 8: Correction and
      -- Contractor Unbilled hours were dropped, and Cancel was renamed Reversal).
      DEFAULTED_FLAG           CHAR(1) DEFAULT 'N' NOT NULL,
      -- Late submission stays a FLAG, never a status: a week submitted after the
      -- weekly cut-off is still 'Submitted' (the manager must still act on it),
      -- but the SLA miss is recorded here.
      LATE_SUBMISSION_FLAG     CHAR(1) DEFAULT 'N' NOT NULL,
      -- Which cut-off was missed. The STATUS is 'Defaulted' either way, but
      -- salary stopping must only act on an EMPLOYEE default: holding someone's
      -- pay because their MANAGER approved late would invert RULE-016, whose
      -- whole point is that 'awaiting approval' never stops salary.
      DEFAULTED_BY             VARCHAR2(10 CHAR),
      ADVANCE_CLOSURE_FLAG     CHAR(1) DEFAULT 'N' NOT NULL,
      OVERRIDDEN_FLAG          CHAR(1) DEFAULT 'N' NOT NULL,
      HAS_REVERSAL_FLAG        CHAR(1) DEFAULT 'N' NOT NULL,
      HAS_ADJUSTMENT_FLAG      CHAR(1) DEFAULT 'N' NOT NULL,
      -- Workflow stamps
      SUBMITTED_BY     VARCHAR2(100 CHAR),
      SUBMITTED_ON     TIMESTAMP,
      APPROVED_BY      VARCHAR2(100 CHAR),
      APPROVED_ON      TIMESTAMP,
      REJECT_REASON    VARCHAR2(20 CHAR),            -- FLD-057 Manager/Client/Absence
      REJECT_REMARKS   VARCHAR2(1000 CHAR),          -- FLD-058
      LOCKED_FLAG      CHAR(1) DEFAULT 'N' NOT NULL, -- defaulted weeks lock (RULE-006)
      CREATED_BY       VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY       VARCHAR2(100),
      UPDATED_ON       TIMESTAMP,
      CONSTRAINT chk_oc_tsw_status CHECK (week_status IN
        ('Not yet submitted','Submitted','Approved','Rejected','Defaulted',
         'Overridden and approved','Closed')),
      CONSTRAINT chk_oc_tsw_reason CHECK (reject_reason IS NULL OR
        reject_reason IN ('Manager','Client','Absence')),   -- RULE-013
      CONSTRAINT chk_oc_tsw_month  CHECK (period_month BETWEEN 1 AND 12),
      CONSTRAINT chk_oc_tsw_dates  CHECK (week_end >= week_start),
      CONSTRAINT chk_oc_tsw_f1  CHECK (defaulted_flag       IN ('Y','N')),
      CONSTRAINT chk_oc_tsw_f2  CHECK (late_submission_flag IN ('Y','N')),
      CONSTRAINT chk_oc_tsw_f5  CHECK (advance_closure_flag IN ('Y','N')),
      CONSTRAINT chk_oc_tsw_f6  CHECK (overridden_flag      IN ('Y','N')),
      CONSTRAINT chk_oc_tsw_f7  CHECK (has_reversal_flag    IN ('Y','N')),
      CONSTRAINT chk_oc_tsw_f8  CHECK (has_adjustment_flag  IN ('Y','N')),
      CONSTRAINT chk_oc_tsw_defby CHECK (defaulted_by IS NULL
                                     OR defaulted_by IN ('EMPLOYEE','MANAGER')),
      -- A defaulted week must say who caused it, and only a defaulted week may.
      CONSTRAINT chk_oc_tsw_defby_req CHECK (
        (week_status = 'Defaulted' AND defaulted_by IS NOT NULL)
        OR (week_status <> 'Defaulted')),
      CONSTRAINT chk_oc_tsw_lock CHECK (locked_flag             IN ('Y','N')),
      CONSTRAINT uk_oc_tsw_emp_week UNIQUE (employee_id, week_start),
      CONSTRAINT fk_oc_tsw_emp    FOREIGN KEY (employee_id)
        REFERENCES oc_time_worker(employee_id),
      CONSTRAINT fk_oc_tsw_period FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_WEEK created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_WEEK already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- ── Migration: DEFAULTED_BY on an already-installed schema ───
--
-- The CREATE above is skipped when the table exists, so a column added to it
-- later never reaches an environment that was installed before. DEFAULTED_BY
-- was added with the revision-2 status model; without this block, OC_TIME_PKG
-- fails to compile on those schemas with ORA-00904 the moment anything writes
-- it, which reads as a broken package rather than a missing column.
--
-- Nothing is dropped. The column is nullable, so it is safe to add to a table
-- with rows in it; the two CHECKs are added after, and only once the existing
-- rows have been back-filled.
DECLARE
  v_n PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TS_WEEK' AND column_name = 'DEFAULTED_BY';

  IF v_n = 0 THEN
    EXECUTE IMMEDIATE
      'ALTER TABLE oc_ts_week ADD (defaulted_by VARCHAR2(10 CHAR))';
    DBMS_OUTPUT.PUT_LINE('OC_TS_WEEK.DEFAULTED_BY added.');
  END IF;

  -- Any week already sitting at 'Defaulted' predates the distinction. It got
  -- there through run_weekly_defaulting, which is the employee cut-off, so
  -- EMPLOYEE is the correct reading rather than a guess. Doing this before the
  -- CHECK goes on is the point: chk_oc_tsw_defby_req would reject those rows.
  --
  -- EXECUTE IMMEDIATE, not a plain UPDATE: static SQL is resolved when this
  -- block compiles, which is before the ALTER above has run on a schema that
  -- lacks the column. A literal UPDATE here would fail with PLS-00904 on
  -- exactly the schemas this migration exists to fix.
  EXECUTE IMMEDIATE q'~
    UPDATE oc_ts_week SET defaulted_by = 'EMPLOYEE'
     WHERE week_status = 'Defaulted' AND defaulted_by IS NULL~';

  IF SQL%ROWCOUNT > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  back-filled ' || SQL%ROWCOUNT ||
                         ' existing Defaulted week(s) as EMPLOYEE.');
  END IF;
  COMMIT;
END;
/

DECLARE
  v_n PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSW_DEFBY';
  IF v_n = 0 THEN
    EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_week ADD CONSTRAINT chk_oc_tsw_defby
      CHECK (defaulted_by IS NULL OR defaulted_by IN ('EMPLOYEE','MANAGER'))~';
  END IF;

  SELECT COUNT(*) INTO v_n FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSW_DEFBY_REQ';
  IF v_n = 0 THEN
    EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_week ADD CONSTRAINT chk_oc_tsw_defby_req
      CHECK ((week_status = 'Defaulted' AND defaulted_by IS NOT NULL)
             OR (week_status <> 'Defaulted'))~';
  END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsw_period ON oc_ts_week(period_id, week_status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsw_emp_ym ON oc_ts_week(employee_id, period_year, period_month)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsw_status ON oc_ts_week(week_status, period_year, period_month)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/8] OC_TS_ENTRY — day x project x task grid cell
PROMPT ============================================================

-- ENTRY_TYPE (Data_Dictionaries accrual_entry_type) — the same four values the
-- accrual interface uses, so no translation is needed at hand-off:
--   'Actual'     employee-entered / manager-corrected hours
--   'Default'    auto-populated at cut-off for a non-submitter (RULE-006)
--   'Reversal'   reversal (-) of a prior entry (retro or default correction)
--   'Adjustment' re-post (+) to the corrected project/task/day
--
-- 'Reversal' was called 'Reversal' until 30-Jul-2026. Renamed because "cancel"
-- reads like an action a user takes on a dialog, whereas this is an accounting
-- reversal that nets off against its Adjustment pair.
--
-- Reversal rows carry NEGATIVE hours; Adjustment rows POSITIVE. The pair nets off
-- (PROC-008 JV logic), which is why HOURS is signed and the 0..24 ceiling is
-- enforced per DAY in OC_TIME_PKG rather than per row (RULE-003).
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_entry (
      TS_ENTRY_ID     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      TS_WEEK_ID      NUMBER            NOT NULL,
      PROJECT_ID      NUMBER            NOT NULL,
      TASK_ID         NUMBER            NOT NULL,
      ENTRY_DATE      DATE              NOT NULL,
      HOURS           NUMBER(6,2) DEFAULT 0 NOT NULL,
      ENTRY_TYPE      VARCHAR2(12 CHAR) DEFAULT 'Actual' NOT NULL,
      BILLABLE_TYPE   VARCHAR2(20 CHAR) DEFAULT 'Billable' NOT NULL, -- FLD-012 / FLD-054
      UNBILLED_REASON VARCHAR2(60 CHAR),                             -- FLD-013 / FLD-055
      SHIFT_CODE      VARCHAR2(20 CHAR),                             -- FLD-008 read-only, HCM
      STANDARD_HOURS  NUMBER(4,2),                                   -- FLD-011 std/day
      IS_LEAVE        CHAR(1) DEFAULT 'N' NOT NULL,                  -- FLD-014, HR-sourced
      ABSENCE_TYPE    VARCHAR2(100 CHAR),
      DAY_STATUS      VARCHAR2(12 CHAR) DEFAULT 'Pending' NOT NULL,  -- FLD-056
      REJECT_REASON   VARCHAR2(20 CHAR),
      REJECT_REMARKS  VARCHAR2(1000 CHAR),
      APPROVED_BY     VARCHAR2(100 CHAR),
      APPROVED_ON     TIMESTAMP,
      SOURCE          VARCHAR2(20 CHAR) DEFAULT 'Employee' NOT NULL,
      ADJUSTMENT_ID   NUMBER,     -- set on Reversal/Adjustment rows (FK added in time/05)
      CREATED_BY      VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY      VARCHAR2(100),
      UPDATED_ON      TIMESTAMP,
      CONSTRAINT chk_oc_tse_etype  CHECK (entry_type IN
        ('Actual','Default','Reversal','Adjustment')),
      CONSTRAINT chk_oc_tse_bill   CHECK (billable_type IN ('Billable','Non-billable')),
      CONSTRAINT chk_oc_tse_dstat  CHECK (day_status IN ('Pending','Approved','Rejected')),
      CONSTRAINT chk_oc_tse_leave  CHECK (is_leave IN ('Y','N')),
      CONSTRAINT chk_oc_tse_source CHECK (source IN
        ('Prepopulated','Employee','Manager','Job','Import')),
      CONSTRAINT chk_oc_tse_reason CHECK (reject_reason IS NULL OR
        reject_reason IN ('Manager','Client','Absence')),
      -- RULE-005: 15-minute blocks. MOD on the absolute value so Reversal rows
      -- (negative) are validated identically.
      CONSTRAINT chk_oc_tse_quarter CHECK (MOD(ABS(hours) * 100, 25) = 0),
      -- A single row can never exceed a day; the 24h DAILY total across all
      -- lines is enforced in OC_TIME_PKG.validate_day (RULE-003).
      CONSTRAINT chk_oc_tse_hours   CHECK (hours BETWEEN -24 AND 24),
      -- RULE-002: non-billable hours must carry an unbilled reason.
      CONSTRAINT chk_oc_tse_unbilled CHECK (
        billable_type <> 'Non-billable' OR hours = 0 OR unbilled_reason IS NOT NULL),
      CONSTRAINT uk_oc_tse_cell UNIQUE
        (ts_week_id, project_id, task_id, entry_date, entry_type),
      CONSTRAINT fk_oc_tse_week FOREIGN KEY (ts_week_id)
        REFERENCES oc_ts_week(ts_week_id) ON DELETE CASCADE,
      CONSTRAINT fk_oc_tse_proj FOREIGN KEY (project_id)
        REFERENCES oc_time_project(project_id),
      CONSTRAINT fk_oc_tse_task FOREIGN KEY (task_id)
        REFERENCES oc_time_task(task_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_ENTRY created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_ENTRY already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tse_date ON oc_ts_entry(entry_date, project_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tse_week ON oc_ts_entry(ts_week_id, entry_date)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tse_proj ON oc_ts_entry(project_id, entry_date, day_status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tse_adj ON oc_ts_entry(adjustment_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/8] OC_TS_ENTRY — derive billable type & reason from task
PROMPT ============================================================

-- FLD-012 is hidden from the employee and derived, never typed: the task
-- decides billable type, and for a non-billable task the reason IS the task
-- (RULE-002 / ACT-007 "special task => non-billable + reason auto").
-- The manager may override UNBILLED_REASON at day level (FLD-055), so an
-- explicitly supplied reason is respected.
CREATE OR REPLACE TRIGGER trg_oc_tse_derive
BEFORE INSERT OR UPDATE ON oc_ts_entry
FOR EACH ROW
DECLARE
  v_bill   oc_time_task.billable_type%TYPE;
  v_reason oc_time_task.unbilled_reason%TYPE;
BEGIN
  SELECT billable_type, unbilled_reason
    INTO v_bill, v_reason
    FROM oc_time_task
   WHERE task_id = :NEW.task_id;

  :NEW.billable_type := v_bill;

  IF v_bill = 'Non-billable' THEN
    :NEW.unbilled_reason := NVL(:NEW.unbilled_reason, v_reason);
  ELSE
    :NEW.unbilled_reason := NULL;
  END IF;

  IF INSERTING THEN
    :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE
    :NEW.updated_on := SYSTIMESTAMP;
    :NEW.created_on := :OLD.created_on;
    :NEW.created_by := :OLD.created_by;
  END IF;
END;
/

PROMPT ============================================================
PROMPT [4/8] OC_TS_WEEK — audit trigger
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tsw_audit
BEFORE INSERT OR UPDATE ON oc_ts_week
FOR EACH ROW
BEGIN
  :NEW.total_hours := NVL(:NEW.billable_hours,0)
                    + NVL(:NEW.non_billable_hours,0)
                    + NVL(:NEW.leave_hours,0);
  IF INSERTING THEN
    :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE
    :NEW.updated_on := SYSTIMESTAMP;
    :NEW.created_on := :OLD.created_on;
    :NEW.created_by := :OLD.created_by;
  END IF;
END;
/

PROMPT ============================================================
PROMPT [5/8] OC_TS_ENTRY — roll hours up to the week
PROMPT ============================================================

-- Recomputes the week totals from its entries after any line change, and
-- derives BILLING_LOSS_HOURS per RULE-009:
--   billing_loss = max(0, corporate standard - billable entered - absence)
-- Statement-level over the affected weeks to avoid ORA-04091.
CREATE OR REPLACE TRIGGER trg_oc_tsw_totals
FOR INSERT OR UPDATE OR DELETE ON oc_ts_entry
COMPOUND TRIGGER
  TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  g_ids t_ids;

  PROCEDURE remember(p_id NUMBER) IS
  BEGIN
    IF p_id IS NOT NULL THEN g_ids(p_id) := p_id; END IF;
  END;

AFTER EACH ROW IS
BEGIN
  IF INSERTING OR UPDATING THEN remember(:NEW.ts_week_id); END IF;
  IF UPDATING  OR DELETING  THEN remember(:OLD.ts_week_id); END IF;
END AFTER EACH ROW;

AFTER STATEMENT IS
  v_id NUMBER;
BEGIN
  v_id := g_ids.FIRST;
  WHILE v_id IS NOT NULL LOOP
    -- Two statements, not one, and that is required rather than tidy.
    --
    -- These used to be a single UPDATE whose select list held five aggregates
    -- AND a correlated scalar subquery for STANDARD_HOURS. Oracle rejects that
    -- with ORA-00937 "not a single-group group function": with no GROUP BY,
    -- every item has to be an aggregate, and the subquery is not one.
    --
    -- It failed at runtime rather than on compile, so populate_month returned
    -- ORA-00937 the first time it was ever asked to build a real month, having
    -- looked healthy in every install up to then.
    UPDATE oc_ts_week w
       SET (w.billable_hours, w.non_billable_hours, w.leave_hours,
            w.has_reversal_flag, w.has_adjustment_flag) =
           (SELECT NVL(SUM(CASE WHEN e.billable_type = 'Billable'
                                 AND e.is_leave = 'N' THEN e.hours END), 0),
                   NVL(SUM(CASE WHEN e.billable_type = 'Non-billable'
                                 AND e.is_leave = 'N' THEN e.hours END), 0),
                   NVL(SUM(CASE WHEN e.is_leave = 'Y'  THEN e.hours END), 0),
                   NVL(MAX(CASE WHEN e.entry_type = 'Reversal'   THEN 'Y' END), 'N'),
                   NVL(MAX(CASE WHEN e.entry_type = 'Adjustment' THEN 'Y' END), 'N')
              FROM oc_ts_entry e
             WHERE e.ts_week_id = w.ts_week_id)
     WHERE w.ts_week_id = v_id;

    -- Standard hours for the week: ONE value per day, not per line. A day with
    -- three project lines still has one standard day, so take the max per date
    -- and then sum across dates — summing the lines directly would treble it.
    UPDATE oc_ts_week w
       SET w.standard_hours =
             NVL((SELECT SUM(d.std_day)
                    FROM (SELECT e2.entry_date,
                                 MAX(e2.standard_hours) AS std_day
                            FROM oc_ts_entry e2
                           WHERE e2.ts_week_id = w.ts_week_id
                           GROUP BY e2.entry_date) d), 0)
     WHERE w.ts_week_id = v_id;

    -- RULE-009: billing loss is automatic and non-editable.
    UPDATE oc_ts_week w
       SET w.billing_loss_hours =
             GREATEST(0, NVL(w.standard_hours,0)
                       - NVL(w.billable_hours,0)
                       - NVL(w.leave_hours,0))
     WHERE w.ts_week_id = v_id;

    v_id := g_ids.NEXT(v_id);
  END LOOP;
END AFTER STATEMENT;
END trg_oc_tsw_totals;
/

PROMPT ============================================================
PROMPT [6/8] V_OC_TS_WEEK_GRID — employee weekly grid (PAGE-001)
PROMPT ============================================================

-- One row per project-task line per week, hours pivoted Mon..Sun so the VBCS
-- editable grid binds directly (FLD-009 "Hours (Mon-Sun)"). Only 'Actual' and
-- 'Default' rows form the grid; Reversal/Adjustment rows live on the retro card.
CREATE OR REPLACE VIEW v_oc_ts_week_grid AS
SELECT w.ts_week_id,
       w.employee_id,
       w.period_id,
       w.period_year,
       w.period_month,
       w.week_index,
       TO_CHAR(w.week_start,'YYYY-MM-DD') AS week_start,
       TO_CHAR(w.week_end,  'YYYY-MM-DD') AS week_end,
       w.week_status,
       w.locked_flag,
       e.project_id,
       p.project_number,
       p.project_name,
       p.project_type,
       e.task_id,
       t.task_code,
       t.task_name,
       t.task_type,
       MAX(e.billable_type)   AS billable_type,
       MAX(e.unbilled_reason) AS unbilled_reason,
       MAX(e.is_leave)        AS is_leave,
       -- Mon..Sun pivot on day-of-week offset from week_start
       NVL(SUM(CASE WHEN e.entry_date = w.week_start     THEN e.hours END),0) AS mon_hours,
       NVL(SUM(CASE WHEN e.entry_date = w.week_start + 1 THEN e.hours END),0) AS tue_hours,
       NVL(SUM(CASE WHEN e.entry_date = w.week_start + 2 THEN e.hours END),0) AS wed_hours,
       NVL(SUM(CASE WHEN e.entry_date = w.week_start + 3 THEN e.hours END),0) AS thu_hours,
       NVL(SUM(CASE WHEN e.entry_date = w.week_start + 4 THEN e.hours END),0) AS fri_hours,
       NVL(SUM(CASE WHEN e.entry_date = w.week_start + 5 THEN e.hours END),0) AS sat_hours,
       NVL(SUM(CASE WHEN e.entry_date = w.week_start + 6 THEN e.hours END),0) AS sun_hours,
       NVL(SUM(e.hours),0) AS line_total,           -- FLD-010
       MIN(e.day_status)   AS line_status
  FROM oc_ts_week w
  JOIN oc_ts_entry e   ON e.ts_week_id = w.ts_week_id
                      AND e.entry_type IN ('Actual','Default')
  JOIN oc_time_project p ON p.project_id = e.project_id
  JOIN oc_time_task    t ON t.task_id    = e.task_id
 GROUP BY w.ts_week_id, w.employee_id, w.period_id, w.period_year, w.period_month,
          w.week_index, w.week_start, w.week_end, w.week_status, w.locked_flag,
          e.project_id, p.project_number, p.project_name, p.project_type,
          e.task_id, t.task_code, t.task_name, t.task_type;

PROMPT ============================================================
PROMPT [7/8] V_OC_TS_DAY_SHIFT — per-day shift & standard row (PAGE-001)
PROMPT ============================================================

-- FLD-008 / FLD-011 / RULE-011: the day-wise shift row above the grid. Shift is
-- read-only from HCM and there is exactly one per employee per day, so MAX()
-- collapses the per-line duplicates without changing the value.
CREATE OR REPLACE VIEW v_oc_ts_day_shift AS
SELECT e.ts_week_id,
       w.employee_id,
       TO_CHAR(e.entry_date,'YYYY-MM-DD') AS entry_date,
       TO_CHAR(e.entry_date,'DY')         AS day_name,
       MAX(e.shift_code)                  AS shift_code,
       MAX(e.standard_hours)              AS standard_hours,
       NVL(SUM(CASE WHEN e.entry_type IN ('Actual','Default')
                    THEN e.hours END),0)  AS day_total,
       MAX(e.is_leave)                    AS is_leave,
       MIN(e.day_status)                  AS day_status
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
 GROUP BY e.ts_week_id, w.employee_id, e.entry_date;

PROMPT ============================================================
PROMPT [8/8] OC_TS_ENTRY — POET carried onto the entry
PROMPT ============================================================

-- doc/CrewRite_Reuse_Assessment.md §2.1: "carry both onto OC_TS_ENTRY at
-- population time so the entry is self-describing".
--
-- The values could be joined from OC_TIME_TASK and OC_TIME_WORKER whenever they
-- are needed, so this is denormalisation and it needs a reason. It has two.
--
-- 1. AN ENTRY IS AN ACCOUNTING FACT AND MUST NOT DRIFT. An expenditure type
--    changed in Fusion next quarter would silently rewrite what last quarter's
--    approved, confirmed, pushed hours were costed as. Stamping the value at
--    population makes the entry say what it was actually charged under — the
--    same argument that put names beside ids on XX_O2C_TIMESHEET_ACCRUAL_IF.
--
-- 2. The OTL push reads at employee x day x WBS. Joining back through task and
--    allocation for every row, to reach values that were fixed months earlier,
--    is work done repeatedly to get an answer that cannot change.
--
-- NULL on existing rows, and correctly so: nothing knew these values when those
-- entries were made. V_OC_TIME_POET_READINESS reports on the master data, which
-- is where the gap is fixed; back-filling entries would invent history.
DECLARE
  v_n PLS_INTEGER := 0;

  PROCEDURE add_col(p_col IN VARCHAR2, p_type IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_entry ADD ' || p_col || ' ' || p_type;
    v_n := v_n + 1;
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
  END;
BEGIN
  add_col('expenditure_type', 'VARCHAR2(80 CHAR)');
  add_col('expenditure_org',  'VARCHAR2(240 CHAR)');
  DBMS_OUTPUT.PUT_LINE('OC_TS_ENTRY POET columns added: ' || v_n);
END;
/

-- Stamp them as the row is written, so no caller has to remember to.
--
-- A trigger rather than a change to populate_daily / populate_month because
-- entries are created from several places — population, the employee's own
-- add-line, adjustment reversal pairs — and a rule enforced in one of them is a
-- rule missing from the others. Only fills what the caller left NULL, so an
-- explicit value (a correction, a back-dated adjustment carrying the original
-- coding) still wins.
CREATE OR REPLACE TRIGGER trg_oc_tse_poet
BEFORE INSERT ON oc_ts_entry
FOR EACH ROW
WHEN (NEW.expenditure_type IS NULL OR NEW.expenditure_org IS NULL)
DECLARE
  v_type VARCHAR2(80 CHAR);
  v_org  VARCHAR2(240 CHAR);
BEGIN
  IF :NEW.expenditure_type IS NULL AND :NEW.task_id IS NOT NULL THEN
    BEGIN
      SELECT t.expenditure_type INTO v_type
        FROM oc_time_task t WHERE t.task_id = :NEW.task_id;
      :NEW.expenditure_type := v_type;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
    END;
  END IF;

  IF :NEW.expenditure_org IS NULL THEN
    -- NVL(allocation, worker): the allocation override first, the person's own
    -- organization otherwise. Same cascade V_OC_TIME_POET_READINESS counts on
    -- and the same shape V_OC_TIME_SIGNIN uses for the role.
    BEGIN
      SELECT NVL(MAX(a.expenditure_org), MAX(wk.expenditure_org)) INTO v_org
        FROM oc_ts_week w
        JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
        LEFT JOIN oc_time_allocation a
               ON a.employee_id = w.employee_id
              AND a.project_id  = :NEW.project_id
              AND a.status      = 'Active'
       WHERE w.ts_week_id = :NEW.ts_week_id;
      :NEW.expenditure_org := v_org;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
    END;
  END IF;
END;
/

PROMPT
PROMPT ============================================================
PROMPT time/03_timesheet complete.
PROMPT ============================================================
--== END 03_timesheet.sql ==

PROMPT >>> 04 approval & audit (approval log, audit, month confirm)

--==============================================================
-- BEGIN 04_approval_audit.sql
--==============================================================
--==============================================================
-- time/04_approval_audit.sql
-- O2C Timesheet Module — Approval workflow, audit trail, month confirmation
--
--   OC_TS_APPROVAL      = append-only event log of every approve / reject /
--                         override / advance-approve / confirm action, at the
--                         granularity it was taken (day, week or month).
--   OC_TS_AUDIT         = before-image of every changed hour. NFR-010 requires
--                         overrides, adjustments and rejections be retained for
--                         7 years; the BRD requires the original be kept when a
--                         manager edits (PROC-004).
--   OC_TS_MONTH_CONFIRM = one row per project-month once the manager confirms
--                         all employees at once (PROC-009 / RULE-020). This is
--                         the record the downstream accrual PULLS against, and
--                         it tracks the OTL push separately from the accrual
--                         hand-off because they can fail independently.
--
-- Requirement refs: PROC-003, PROC-004, PROC-009, PROC-010, PAGE-004, PAGE-005,
--                   ACT-012..ACT-020, ACT-024, RULE-013, RULE-015, RULE-020,
--                   NFR-010, OBS-002, OBS-005, REP-007
-- Idempotent. Depends on: time/01, time/02, time/03
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/6] OC_TS_APPROVAL — approval event log
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_approval (
      APPROVAL_ID   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      TS_WEEK_ID    NUMBER,                        -- NULL for month-level events
      EMPLOYEE_ID   VARCHAR2(50 CHAR) NOT NULL,
      PROJECT_ID    NUMBER,                        -- NULL when across all projects
      PERIOD_ID     NUMBER            NOT NULL,
      GRANULARITY   VARCHAR2(6 CHAR)  NOT NULL,    -- DAY | WEEK | MONTH
      ENTRY_DATE    DATE,                          -- set only when GRANULARITY='DAY'
      ACTION        VARCHAR2(20 CHAR) NOT NULL,
      REJECT_REASON VARCHAR2(20 CHAR),             -- FLD-057, mandatory on Reject
      REMARKS       VARCHAR2(1000 CHAR),           -- FLD-058
      ACTOR_EMP_ID  VARCHAR2(50 CHAR) NOT NULL,    -- RULE-015: never = EMPLOYEE_ID
      ACTOR_ROLE    VARCHAR2(30 CHAR),
      TRACE_ID      VARCHAR2(64 CHAR),             -- OBS-002 correlation
      ACTION_ON     TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT chk_oc_tsa_gran   CHECK (granularity IN ('DAY','WEEK','MONTH')),
      CONSTRAINT chk_oc_tsa_action CHECK (action IN
        ('Approve','Reject','Override','AdvanceApprove','Confirm',
         'Submit','Resubmit','Default','Release')),
      CONSTRAINT chk_oc_tsa_reason CHECK (reject_reason IS NULL OR
        reject_reason IN ('Manager','Client','Absence')),
      -- RULE-013: a rejection must carry a reason.
      CONSTRAINT chk_oc_tsa_rej_req CHECK (
        action <> 'Reject' OR reject_reason IS NOT NULL),
      -- A DAY event must name the day; WEEK/MONTH events must not.
      CONSTRAINT chk_oc_tsa_day CHECK (
        (granularity = 'DAY' AND entry_date IS NOT NULL) OR
        (granularity <> 'DAY' AND entry_date IS NULL)),
      -- RULE-015: a manager never approves their own timesheet.
      CONSTRAINT chk_oc_tsa_self CHECK (
        action NOT IN ('Approve','Reject','Override','AdvanceApprove','Confirm')
        OR actor_emp_id <> employee_id),
      CONSTRAINT fk_oc_tsa_week   FOREIGN KEY (ts_week_id)
        REFERENCES oc_ts_week(ts_week_id) ON DELETE CASCADE,
      CONSTRAINT fk_oc_tsa_period FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_APPROVAL created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_APPROVAL already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsa_week ON oc_ts_approval(ts_week_id, action)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsa_emp ON oc_ts_approval(employee_id, period_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsa_actor ON oc_ts_approval(actor_emp_id, action_on)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/6] OC_TS_AUDIT — before-image of every changed hour
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_audit (
      AUDIT_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      TS_ENTRY_ID     NUMBER,
      TS_WEEK_ID      NUMBER            NOT NULL,
      EMPLOYEE_ID     VARCHAR2(50 CHAR) NOT NULL,
      ENTRY_DATE      DATE              NOT NULL,
      CHANGE_TYPE     VARCHAR2(20 CHAR) NOT NULL,
      OLD_PROJECT_ID  NUMBER,
      OLD_TASK_ID     NUMBER,
      OLD_HOURS       NUMBER(6,2),
      OLD_BILL_TYPE   VARCHAR2(20 CHAR),
      OLD_REASON      VARCHAR2(60 CHAR),
      NEW_PROJECT_ID  NUMBER,
      NEW_TASK_ID     NUMBER,
      NEW_HOURS       NUMBER(6,2),
      NEW_BILL_TYPE   VARCHAR2(20 CHAR),
      NEW_REASON      VARCHAR2(60 CHAR),
      CHANGE_REASON   VARCHAR2(1000 CHAR),
      CHANGED_BY      VARCHAR2(100 CHAR) NOT NULL,
      CHANGED_ON      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      TRACE_ID        VARCHAR2(64 CHAR),
      CONSTRAINT chk_oc_tsau_type CHECK (change_type IN
        ('Override','Adjustment','Reversal','ManagerEdit','Import','DefaultCorrection')),
      CONSTRAINT fk_oc_tsau_week  FOREIGN KEY (ts_week_id)
        REFERENCES oc_ts_week(ts_week_id) ON DELETE CASCADE
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_AUDIT created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_AUDIT already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsau_week ON oc_ts_audit(ts_week_id, entry_date)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsau_emp ON oc_ts_audit(employee_id, changed_on)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/6] OC_TS_MONTH_CONFIRM — project-month confirmation
PROMPT ============================================================

-- PROC-009. One row per project + period. Written by
-- OC_TIME_PKG.confirm_month once RULE-020 passes (every employee on the
-- project Approved). Downstream:
--   * OTL_STATUS     — push to timeRecordEventRequests / TIME_SUBMIT (INT-007)
--   * ACCRUAL_STATUS — interface rows written to XX_O2C_TIMESHEET_ACCRUAL_IF,
--                      which the O2C accrual application PULLS (INT-014)
--   * PARTNER_STATUS — the parallel push to our other product
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_month_confirm (
      CONFIRM_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      PROJECT_ID        NUMBER            NOT NULL,
      PERIOD_ID         NUMBER            NOT NULL,
      PERIOD_YEAR       NUMBER(4)         NOT NULL,
      PERIOD_MONTH      NUMBER(2)         NOT NULL,
      EMPLOYEE_COUNT    NUMBER(6)  DEFAULT 0 NOT NULL,
      BILLABLE_HOURS    NUMBER(12,2) DEFAULT 0 NOT NULL,
      NON_BILLABLE_HOURS NUMBER(12,2) DEFAULT 0 NOT NULL,
      LEAVE_HOURS       NUMBER(12,2) DEFAULT 0 NOT NULL,
      ADJUSTMENT_HOURS  NUMBER(12,2) DEFAULT 0 NOT NULL,
      CONFIRM_TYPE      VARCHAR2(20 CHAR) DEFAULT 'Normal' NOT NULL,
      CONFIRMED_BY      VARCHAR2(100 CHAR) NOT NULL,
      CONFIRMED_ON      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      OTL_STATUS        VARCHAR2(20 CHAR) DEFAULT 'Pending' NOT NULL,
      OTL_PUSHED_ON     TIMESTAMP,
      OTL_MESSAGE       VARCHAR2(2000 CHAR),
      ACCRUAL_STATUS    VARCHAR2(20 CHAR) DEFAULT 'Pending' NOT NULL,
      ACCRUAL_ROWS      NUMBER(10),
      ACCRUAL_PUSHED_ON TIMESTAMP,
      ACCRUAL_MESSAGE   VARCHAR2(2000 CHAR),
      PARTNER_STATUS    VARCHAR2(20 CHAR) DEFAULT 'Pending' NOT NULL,
      PARTNER_PUSHED_ON TIMESTAMP,
      TRACE_ID          VARCHAR2(64 CHAR),
      CONSTRAINT chk_oc_tsmc_ctype CHECK (confirm_type IN
        ('Normal','Advance closure','Reopened')),
      CONSTRAINT chk_oc_tsmc_otl   CHECK (otl_status     IN ('Pending','Success','Failed','Skipped')),
      CONSTRAINT chk_oc_tsmc_accr  CHECK (accrual_status IN ('Pending','Success','Failed','Skipped')),
      CONSTRAINT chk_oc_tsmc_part  CHECK (partner_status IN ('Pending','Success','Failed','Skipped')),
      CONSTRAINT chk_oc_tsmc_month CHECK (period_month BETWEEN 1 AND 12),
      CONSTRAINT uk_oc_tsmc_proj   UNIQUE (project_id, period_id),
      CONSTRAINT fk_oc_tsmc_proj   FOREIGN KEY (project_id)
        REFERENCES oc_time_project(project_id),
      CONSTRAINT fk_oc_tsmc_period FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_MONTH_CONFIRM created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_MONTH_CONFIRM already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsmc_period ON oc_ts_month_confirm(period_id, accrual_status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [4/6] OC_TS_ENTRY — automatic before-image capture
PROMPT ============================================================

-- Every hour change made by anyone other than the owning employee is captured
-- before it is overwritten (NFR-010 / REP-007). SOURCE tells us who acted, and
-- it is set by OC_TIME_PKG on the way in, so this trigger needs no context.
CREATE OR REPLACE TRIGGER trg_oc_tse_audit_capture
BEFORE UPDATE OF hours, project_id, task_id, unbilled_reason ON oc_ts_entry
FOR EACH ROW
DECLARE
  v_emp  oc_ts_week.employee_id%TYPE;
  v_type oc_ts_audit.change_type%TYPE;
BEGIN
  -- Nothing meaningful changed -> no audit row.
  IF NVL(:OLD.hours,-1)           = NVL(:NEW.hours,-1)
 AND NVL(:OLD.project_id,-1)      = NVL(:NEW.project_id,-1)
 AND NVL(:OLD.task_id,-1)         = NVL(:NEW.task_id,-1)
 AND NVL(:OLD.unbilled_reason,'~')= NVL(:NEW.unbilled_reason,'~') THEN
    RETURN;
  END IF;

  SELECT employee_id INTO v_emp FROM oc_ts_week WHERE ts_week_id = :NEW.ts_week_id;

  v_type := CASE :NEW.source
              WHEN 'Manager' THEN 'Override'
              WHEN 'Import'  THEN 'Import'
              WHEN 'Job'     THEN 'DefaultCorrection'
              ELSE 'ManagerEdit'
            END;

  -- The employee correcting their own draft is normal editing, not an audited
  -- override; only non-employee sources are retained.
  IF :NEW.source = 'Employee' THEN RETURN; END IF;

  INSERT INTO oc_ts_audit (
    ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
    old_project_id, old_task_id, old_hours, old_bill_type, old_reason,
    new_project_id, new_task_id, new_hours, new_bill_type, new_reason,
    changed_by)
  VALUES (
    :NEW.ts_entry_id, :NEW.ts_week_id, v_emp, :NEW.entry_date, v_type,
    :OLD.project_id, :OLD.task_id, :OLD.hours, :OLD.billable_type, :OLD.unbilled_reason,
    :NEW.project_id, :NEW.task_id, :NEW.hours, :NEW.billable_type, :NEW.unbilled_reason,
    NVL(:NEW.updated_by, 'SYSTEM'));
END;
/

PROMPT ============================================================
PROMPT [5/6] V_OC_TS_MONTH_SUMMARY — manager monthly summary (PAGE-004)
PROMPT ============================================================

-- One row per employee per project per period: the multi-select approve/reject
-- grid (FLD-037..FLD-047). MONTH_STATUS is derived from the employee's weeks,
-- because the month itself is never stored (FLD-046):
--   any Rejected  -> Rejected
--   all Approved  -> Approved   (Overridden and approved counts as approved)
--   otherwise     -> Pending
CREATE OR REPLACE VIEW v_oc_ts_month_summary AS
SELECT e.project_id,
       p.project_number,
       p.project_name,
       p.revenue_model,
       p.leave_loss_flag,
       p.project_manager_id,
       w.period_id,
       w.period_year,
       w.period_month,
       w.employee_id,
       wk.employee_name,
       wk.worker_type,
       al.billing_status,
       al.client_role,
       al.cap_type,
       al.cap_hours,
       NVL(SUM(CASE WHEN e.billable_type = 'Billable'
                     AND e.is_leave = 'N' THEN e.hours END),0) AS billable_hours,
       NVL(SUM(CASE WHEN e.billable_type = 'Non-billable'
                     AND e.is_leave = 'N' THEN e.hours END),0) AS non_billable_hours,
       NVL(SUM(CASE WHEN e.is_leave = 'Y' THEN e.hours END),0) AS leave_hours,
       NVL(SUM(e.hours),0)                                     AS total_hours,
       COUNT(DISTINCT w.ts_week_id)                            AS week_count,
       COUNT(DISTINCT CASE WHEN w.week_status IN ('Approved','Overridden and approved','Closed')
                           THEN w.ts_week_id END)              AS approved_weeks,
       COUNT(DISTINCT CASE WHEN w.week_status = 'Rejected'
                           THEN w.ts_week_id END)              AS rejected_weeks,
       -- The weeks WAITING ON THE MANAGER. Without this the monthly summary
       -- counted only approved and rejected, so an employee submitting changed
       -- nothing a manager could see on the list they work from — the week said
       -- Submitted one screen deeper and the row above it looked identical to
       -- an employee who had not filled anything in.
       COUNT(DISTINCT CASE WHEN w.week_status = 'Submitted'
                           THEN w.ts_week_id END)              AS submitted_weeks,
       CASE
         WHEN COUNT(DISTINCT CASE WHEN w.week_status = 'Rejected'
                                  THEN w.ts_week_id END) > 0 THEN 'Rejected'
         WHEN COUNT(DISTINCT w.ts_week_id) =
              COUNT(DISTINCT CASE WHEN w.week_status IN
                     ('Approved','Overridden and approved','Closed')
                     THEN w.ts_week_id END)                 THEN 'Approved'
         ELSE 'Pending'
       END                                                     AS month_status,
       TO_CHAR(MAX(w.approved_on),'YYYY-MM-DD')                AS approved_on,
       MAX(w.overridden_flag)                                  AS overridden_flag,
       MAX(w.advance_closure_flag)                             AS advance_closure_flag
  FROM oc_ts_week      w
  JOIN oc_ts_entry     e  ON e.ts_week_id = w.ts_week_id
                         AND e.entry_type IN ('Actual','Default')
  JOIN oc_time_project p  ON p.project_id = e.project_id
  JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
  LEFT JOIN oc_time_allocation al
         ON al.project_id  = e.project_id
        AND al.employee_id = w.employee_id
        AND al.status      = 'Active'
 GROUP BY e.project_id, p.project_number, p.project_name, p.revenue_model,
          p.leave_loss_flag, p.project_manager_id,
          w.period_id, w.period_year, w.period_month, w.employee_id,
          wk.employee_name, wk.worker_type,
          al.billing_status, al.client_role, al.cap_type, al.cap_hours;

PROMPT ============================================================
PROMPT [6/6] V_OC_TS_DAY_DETAIL — manager daily line view (PAGE-005)
PROMPT ============================================================

-- FLD-051..FLD-056: line-wise billable / non-billable per task per day, with
-- the Type column the manager (and only the manager) sees, plus the editable
-- day-level Unbilled Reason.
CREATE OR REPLACE VIEW v_oc_ts_day_detail AS
SELECT e.ts_entry_id,
       e.ts_week_id,
       w.employee_id,
       wk.employee_name,
       w.period_id,
       w.week_index,
       TO_CHAR(w.week_start,'YYYY-MM-DD')  AS week_start,
       TO_CHAR(w.week_end,  'YYYY-MM-DD')  AS week_end,
       w.week_status,
       TO_CHAR(e.entry_date,'YYYY-MM-DD')  AS entry_date,
       TO_CHAR(e.entry_date,'DY')          AS day_name,
       e.project_id,
       p.project_name,
       e.task_id,
       t.task_code,
       t.task_name,
       e.hours,
       e.entry_type,
       e.billable_type,
       e.unbilled_reason,
       e.shift_code,
       e.standard_hours,
       e.is_leave,
       e.absence_type,
       e.day_status,
       e.reject_reason,
       e.reject_remarks,
       e.source
  FROM oc_ts_entry     e
  JOIN oc_ts_week      w  ON w.ts_week_id  = e.ts_week_id
  JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
  JOIN oc_time_project p  ON p.project_id  = e.project_id
  JOIN oc_time_task    t  ON t.task_id     = e.task_id;

PROMPT
PROMPT ============================================================
PROMPT time/04_approval_audit complete.
PROMPT ============================================================
--== END 04_approval_audit.sql ==

PROMPT >>> 05 adjustments, leave-loss coverage, salary hold

--==============================================================
-- BEGIN 05_adjustment_llc_salary.sql
--==============================================================
--==============================================================
-- time/05_adjustment_llc_salary.sql
-- O2C Timesheet Module — Retro adjustments, leave-loss coverage, salary hold
--
--   OC_TS_ADJUSTMENT        = day-wise retro Project/WBS change. One row per
--                             affected DAY (PROC-008 / #10 "day-wise"), holding
--                             both sides of the net-off: the old line to Reverse
--                             (-) and the new line to Adjust (+). On approval
--                             OC_TIME_PKG materialises the paired Reversal and
--                             Adjustment rows in OC_TS_ENTRY in the OPEN period.
--   OC_TS_LEAVE_LOSS_COVER  = absentee -> covering colleague, per day, for FCP
--                             projects with Leave Loss = Yes (PROC-006).
--   OC_TS_SALARY_HOLD       = payroll-cut-off hold for Defaulted timesheets
--                             (PROC-007). 'Awaiting approval' never holds pay.
--
-- Requirement refs: PROC-006, PROC-007, PROC-008, PAGE-006, PAGE-007,
--                   FLD-016..FLD-018, FLD-060..FLD-074, FLD-108, FLD-109,
--                   ACT-009, ACT-021..ACT-026, RULE-014, RULE-016, RULE-019,
--                   RA-018 (default corrections post as Reversal/Adjustment)
-- Idempotent. Depends on: time/01, time/02, time/03, time/04
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/8] OC_TS_ADJUSTMENT — day-wise retro Reversal(-)/Adjustment(+)
PROMPT ============================================================

-- SOURCE_PERIOD_ID = the closed period the work actually happened in.
-- POST_PERIOD_ID   = the OPEN period the net-off is posted into, because a
--                    closed book is never reopened (PROC-008).
-- ADJ_KIND distinguishes the two triggers for the same mechanism:
--   'RetroWBS'          backdated Project/WBS correction (PROC-008)
--   'DefaultCorrection' a defaulted week's default hours already went to
--                       accrual and were later corrected & approved (RA-018)
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_adjustment (
      ADJUSTMENT_ID    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EMPLOYEE_ID      VARCHAR2(50 CHAR) NOT NULL,
      WORK_DATE        DATE              NOT NULL,   -- FLD-016 the affected day
      SOURCE_PERIOD_ID NUMBER            NOT NULL,
      POST_PERIOD_ID   NUMBER            NOT NULL,
      ADJ_KIND         VARCHAR2(20 CHAR) DEFAULT 'RetroWBS' NOT NULL,
      -- Reversal (-) side : the line being reversed             FLD-017
      OLD_PROJECT_ID   NUMBER            NOT NULL,
      OLD_TASK_ID      NUMBER            NOT NULL,
      OLD_HOURS        NUMBER(6,2)       NOT NULL,
      -- Adjustment (+) side : the corrected line              FLD-018
      NEW_PROJECT_ID   NUMBER,
      NEW_TASK_ID      NUMBER,
      NEW_HOURS        NUMBER(6,2)       DEFAULT 0 NOT NULL,
      STATUS           VARCHAR2(30 CHAR) DEFAULT 'Awaiting Approval' NOT NULL,
      REASON           VARCHAR2(1000 CHAR),
      -- RA-014: currently BOTH the old and the new project manager see it.
      OLD_MGR_APPROVED_BY VARCHAR2(100 CHAR),
      OLD_MGR_APPROVED_ON TIMESTAMP,
      NEW_MGR_APPROVED_BY VARCHAR2(100 CHAR),
      NEW_MGR_APPROVED_ON TIMESTAMP,
      ACTION_DATE      DATE,                          -- manager approval action date
      POSTED_FLAG      CHAR(1) DEFAULT 'N' NOT NULL,  -- entries materialised?
      POSTED_ON        TIMESTAMP,
      APPLIED_BY       VARCHAR2(100 CHAR) NOT NULL,
      APPLIED_ON       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      TRACE_ID         VARCHAR2(64 CHAR),
      CONSTRAINT chk_oc_tsadj_kind   CHECK (adj_kind IN ('RetroWBS','DefaultCorrection')),
      CONSTRAINT chk_oc_tsadj_status CHECK (status IN
        ('Awaiting Approval','Approved','Rejected','Cancelled')),
      CONSTRAINT chk_oc_tsadj_posted CHECK (posted_flag IN ('Y','N')),
      -- RULE-005 applies to both sides of the net-off.
      CONSTRAINT chk_oc_tsadj_q1 CHECK (MOD(ABS(old_hours) * 100, 25) = 0),
      CONSTRAINT chk_oc_tsadj_q2 CHECK (MOD(ABS(new_hours) * 100, 25) = 0),
      CONSTRAINT chk_oc_tsadj_h1 CHECK (old_hours BETWEEN 0 AND 24),
      CONSTRAINT chk_oc_tsadj_h2 CHECK (new_hours BETWEEN 0 AND 24),
      -- Moving hours to a new line requires that line to be named.
      CONSTRAINT chk_oc_tsadj_new CHECK (
        new_hours = 0 OR (new_project_id IS NOT NULL AND new_task_id IS NOT NULL)),
      CONSTRAINT uk_oc_tsadj_day UNIQUE
        (employee_id, work_date, old_project_id, old_task_id, applied_on),
      CONSTRAINT fk_oc_tsadj_emp     FOREIGN KEY (employee_id)
        REFERENCES oc_time_worker(employee_id),
      CONSTRAINT fk_oc_tsadj_srcper  FOREIGN KEY (source_period_id)
        REFERENCES oc_time_period(period_id),
      CONSTRAINT fk_oc_tsadj_postper FOREIGN KEY (post_period_id)
        REFERENCES oc_time_period(period_id),
      CONSTRAINT fk_oc_tsadj_oldproj FOREIGN KEY (old_project_id)
        REFERENCES oc_time_project(project_id),
      CONSTRAINT fk_oc_tsadj_newproj FOREIGN KEY (new_project_id)
        REFERENCES oc_time_project(project_id),
      CONSTRAINT fk_oc_tsadj_oldtask FOREIGN KEY (old_task_id)
        REFERENCES oc_time_task(task_id),
      CONSTRAINT fk_oc_tsadj_newtask FOREIGN KEY (new_task_id)
        REFERENCES oc_time_task(task_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_ADJUSTMENT created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_ADJUSTMENT already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsadj_emp ON oc_ts_adjustment(employee_id, work_date)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsadj_status ON oc_ts_adjustment(status, post_period_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsadj_oldproj ON oc_ts_adjustment(old_project_id, status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsadj_newproj ON oc_ts_adjustment(new_project_id, status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

-- Deferred FK from time/03: Reversal/Adjustment entries point back at the
-- adjustment that produced them.
BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE oc_ts_entry ADD CONSTRAINT fk_oc_tse_adj
      FOREIGN KEY (adjustment_id) REFERENCES oc_ts_adjustment(adjustment_id)
  ]';
  DBMS_OUTPUT.PUT_LINE('FK_OC_TSE_ADJ added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-2275, -2264) THEN            -- already exists / dup name
    DBMS_OUTPUT.PUT_LINE('FK_OC_TSE_ADJ already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/8] OC_TS_ADJUSTMENT — backdating window guard (RULE-019)
PROMPT ============================================================

-- RULE-019: adjustments only within the configured window (default 3 months,
-- FLD-091 / CFG-011). Enforced at row level against the POST period's
-- ADJUSTMENT_MONTHS so finance can widen the window without a code change.
CREATE OR REPLACE TRIGGER trg_oc_tsadj_window
BEFORE INSERT ON oc_ts_adjustment
FOR EACH ROW
DECLARE
  v_post_start  DATE;
  v_months      NUMBER;
BEGIN
  SELECT start_date, adjustment_months
    INTO v_post_start, v_months
    FROM oc_time_period
   WHERE period_id = :NEW.post_period_id;

  IF :NEW.work_date < ADD_MONTHS(TRUNC(v_post_start,'MM'), -v_months) THEN
    RAISE_APPLICATION_ERROR(-20019,
      'Adjustments are only allowed up to ' || v_months || ' months back.');
  END IF;

  :NEW.applied_on := NVL(:NEW.applied_on, SYSTIMESTAMP);
END;
/

PROMPT ============================================================
PROMPT [3/8] OC_TS_LEAVE_LOSS_COVER — FCP absence coverage
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_leave_loss_cover (
      LLC_ID             NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      PROJECT_ID         NUMBER            NOT NULL,
      PERIOD_ID          NUMBER            NOT NULL,
      ABSENT_EMPLOYEE_ID VARCHAR2(50 CHAR) NOT NULL,   -- FLD-060 / FLD-061
      ABSENCE_DATE       DATE              NOT NULL,   -- FLD-062
      ABSENCE_HOURS      NUMBER(5,2)       NOT NULL,   -- FLD-063
      ABSENCE_TYPE       VARCHAR2(100 CHAR),
      COVER_EMPLOYEE_ID  VARCHAR2(50 CHAR),            -- FLD-064
      LLC_STATUS         VARCHAR2(20 CHAR) DEFAULT 'Open' NOT NULL, -- FLD-065
      BILLED_FLAG        CHAR(1) DEFAULT 'N' NOT NULL, -- approved cover => billed
      ASSIGNED_BY        VARCHAR2(100 CHAR),
      ASSIGNED_ON        TIMESTAMP,
      APPROVED_BY        VARCHAR2(100 CHAR),
      APPROVED_ON        TIMESTAMP,
      REMARKS            VARCHAR2(1000 CHAR),
      CREATED_BY         VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY         VARCHAR2(100),
      UPDATED_ON         TIMESTAMP,
      CONSTRAINT chk_oc_tsllc_status CHECK (llc_status IN ('Open','Assigned','Approved')),
      CONSTRAINT chk_oc_tsllc_billed CHECK (billed_flag IN ('Y','N')),
      CONSTRAINT chk_oc_tsllc_hours  CHECK (absence_hours > 0 AND absence_hours <= 24),
      -- A cover must be named before the line can move past Open.
      CONSTRAINT chk_oc_tsllc_cover  CHECK (
        llc_status = 'Open' OR cover_employee_id IS NOT NULL),
      -- RULE-014: nobody covers themselves.
      CONSTRAINT chk_oc_tsllc_self   CHECK (
        cover_employee_id IS NULL OR cover_employee_id <> absent_employee_id),
      CONSTRAINT uk_oc_tsllc_day UNIQUE (project_id, absent_employee_id, absence_date),
      CONSTRAINT fk_oc_tsllc_proj    FOREIGN KEY (project_id)
        REFERENCES oc_time_project(project_id),
      CONSTRAINT fk_oc_tsllc_period  FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id),
      CONSTRAINT fk_oc_tsllc_absent  FOREIGN KEY (absent_employee_id)
        REFERENCES oc_time_worker(employee_id),
      CONSTRAINT fk_oc_tsllc_cover   FOREIGN KEY (cover_employee_id)
        REFERENCES oc_time_worker(employee_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_LEAVE_LOSS_COVER created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_LEAVE_LOSS_COVER already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsllc_period ON oc_ts_leave_loss_cover(period_id, project_id, llc_status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
-- RULE-014: a colleague cannot cover two absentees on the same day.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE UNIQUE INDEX uk_oc_tsllc_cover_day
      ON oc_ts_leave_loss_cover (cover_employee_id, absence_date)
  ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [4/8] V_OC_TS_LLC_ELIGIBLE_COVER — cover LOV (RULE-014)
PROMPT ============================================================

-- FLD-064 LOV, filtered exactly as RULE-014 states: unbilled on the SAME
-- project, not absent that day, not already assigned as cover that day.
-- The absentee list itself excludes LOP and maternity.
CREATE OR REPLACE VIEW v_oc_ts_llc_eligible_cover AS
SELECT al.project_id,
       d.absence_date,
       al.employee_id AS cover_employee_id,
       w.employee_name,
       al.client_role,
       al.billing_status
  FROM oc_time_allocation al
  JOIN oc_time_worker w ON w.employee_id = al.employee_id
  -- Candidate dates = the days on which this project actually has absentees.
  JOIN (SELECT DISTINCT project_id, absence_date
          FROM oc_ts_leave_loss_cover) d
    ON d.project_id = al.project_id
 WHERE al.status         = 'Active'
   AND al.billing_status = 'Unbilled'
   AND w.status          = 'Active'
   -- not absent that day
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id  = al.employee_id
                      AND ab.absence_date = d.absence_date)
   -- not already covering someone that day
   AND NOT EXISTS (SELECT 1 FROM oc_ts_leave_loss_cover c
                    WHERE c.cover_employee_id = al.employee_id
                      AND c.absence_date      = d.absence_date);

PROMPT ============================================================
PROMPT [5/8] OC_TS_SALARY_HOLD — payroll hold for defaulted timesheets
PROMPT ============================================================

-- PROC-007 / RULE-016. Only WEEK_STATUS = 'Defaulted' holds salary; a week
-- merely awaiting manager approval does NOT. APPLIED vs DEFAULT hours and the
-- submitted/defaulted week split are what PAGE-007 shows (FLD-069..FLD-071).
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE oc_ts_salary_hold (
      HOLD_ID           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EMPLOYEE_ID       VARCHAR2(50 CHAR) NOT NULL,
      PERIOD_ID         NUMBER            NOT NULL,
      WEEKS_TOTAL       NUMBER(2)   DEFAULT 0 NOT NULL,
      WEEKS_SUBMITTED   NUMBER(2)   DEFAULT 0 NOT NULL,  -- FLD-069
      WEEKS_DEFAULTED   NUMBER(2)   DEFAULT 0 NOT NULL,  -- FLD-069
      APPLIED_HOURS     NUMBER(8,2) DEFAULT 0 NOT NULL,  -- FLD-070
      DEFAULT_HOURS     NUMBER(8,2) DEFAULT 0 NOT NULL,  -- FLD-071
      SALARY_STATUS     VARCHAR2(20 CHAR) DEFAULT 'Held' NOT NULL, -- FLD-072
      HOLD_RELEASE_DAYS NUMBER(4),                       -- FLD-073 / CFG-012
      HELD_ON           TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      WINDOW_EXPIRES_ON DATE,
      CORRECTED_BY      VARCHAR2(100 CHAR),
      CORRECTED_ON      TIMESTAMP,
      RELEASED_BY       VARCHAR2(100 CHAR),
      RELEASED_ON       TIMESTAMP,
      PAYROLL_NOTIFIED  CHAR(1) DEFAULT 'N' NOT NULL,
      REMARKS           VARCHAR2(1000 CHAR),
      TRACE_ID          VARCHAR2(64 CHAR),
      CONSTRAINT chk_oc_tssh_status CHECK (salary_status IN ('Held','Released')),
      CONSTRAINT chk_oc_tssh_notif  CHECK (payroll_notified IN ('Y','N')),
      -- A released hold must record who released it (SOX / PAGE-007 privileged).
      CONSTRAINT chk_oc_tssh_rel    CHECK (
        salary_status = 'Held' OR released_by IS NOT NULL),
      CONSTRAINT uk_oc_tssh_emp     UNIQUE (employee_id, period_id),
      CONSTRAINT fk_oc_tssh_emp     FOREIGN KEY (employee_id)
        REFERENCES oc_time_worker(employee_id),
      CONSTRAINT fk_oc_tssh_period  FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('OC_TS_SALARY_HOLD created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_SALARY_HOLD already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tssh_period ON oc_ts_salary_hold(period_id, salary_status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [6/8] Audit triggers
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tsllc_audit
BEFORE INSERT OR UPDATE ON oc_ts_leave_loss_cover
FOR EACH ROW
BEGIN
  -- Approved coverage makes the absence hours BILLED for FCP (PROC-006) and is
  -- what flows to the invoice annexure (REP-002).
  IF :NEW.llc_status = 'Approved' THEN
    :NEW.billed_flag := 'Y';
    :NEW.approved_on := NVL(:NEW.approved_on, SYSTIMESTAMP);
  END IF;
  IF :NEW.llc_status = 'Assigned' AND :NEW.assigned_on IS NULL THEN
    :NEW.assigned_on := SYSTIMESTAMP;
  END IF;
  IF INSERTING THEN :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE :NEW.updated_on := SYSTIMESTAMP;
       :NEW.created_on := :OLD.created_on; :NEW.created_by := :OLD.created_by; END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_oc_tssh_window
BEFORE INSERT OR UPDATE ON oc_ts_salary_hold
FOR EACH ROW
DECLARE
  v_days NUMBER;
BEGIN
  IF :NEW.hold_release_days IS NULL THEN
    SELECT hold_release_days INTO v_days
      FROM oc_time_period WHERE period_id = :NEW.period_id;
    :NEW.hold_release_days := NVL(v_days, 60);
  END IF;
  IF :NEW.window_expires_on IS NULL THEN
    :NEW.window_expires_on :=
      TRUNC(CAST(NVL(:NEW.held_on, SYSTIMESTAMP) AS DATE)) + :NEW.hold_release_days;
  END IF;
  IF :NEW.salary_status = 'Released' AND :NEW.released_on IS NULL THEN
    :NEW.released_on := SYSTIMESTAMP;
  END IF;
END;
/

PROMPT ============================================================
PROMPT [7/8] V_OC_TS_SALARY_HOLD — PAGE-007 projection
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_salary_hold AS
SELECT h.hold_id,
       h.employee_id,
       w.employee_name,
       w.worker_type,
       w.base_country,
       w.manager_emp_id,
       h.period_id,
       p.period_name,
       h.weeks_total,
       h.weeks_submitted,
       h.weeks_defaulted,
       h.weeks_submitted || ' submitted / ' || h.weeks_defaulted || ' defaulted'
         AS weeks_split,                                   -- FLD-069 display
       h.applied_hours,
       h.default_hours,
       h.salary_status,
       h.hold_release_days,
       TO_CHAR(h.window_expires_on,'YYYY-MM-DD') AS window_expires_on,
       CASE WHEN h.salary_status = 'Held'
             AND h.window_expires_on < TRUNC(SYSDATE) THEN 'Y' ELSE 'N' END
         AS window_expired,
       TO_CHAR(h.held_on,     'YYYY-MM-DD HH24:MI') AS held_on,
       TO_CHAR(h.released_on, 'YYYY-MM-DD HH24:MI') AS released_on,
       h.released_by,
       h.remarks
  FROM oc_ts_salary_hold h
  JOIN oc_time_worker    w ON w.employee_id = h.employee_id
  JOIN oc_time_period    p ON p.period_id   = h.period_id;

PROMPT ============================================================
PROMPT [8/8] V_OC_TS_ADJUSTMENT — adjustment panel (PAGE-003 / PAGE-011)
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_adjustment AS
SELECT a.adjustment_id,
       a.employee_id,
       w.employee_name,
       TO_CHAR(a.work_date,'YYYY-MM-DD') AS work_date,
       a.adj_kind,
       sp.period_name AS source_period,
       pp.period_name AS post_period,
       a.post_period_id,
       a.old_project_id,
       op.project_name AS old_project_name,
       ot.task_code    AS old_task_code,
       a.old_hours,
       a.new_project_id,
       np.project_name AS new_project_name,
       nt.task_code    AS new_task_code,
       a.new_hours,
       (a.new_hours - a.old_hours) AS net_hours,          -- REP-004 net-off
       a.status,
       a.reason,
       a.old_mgr_approved_by,
       a.new_mgr_approved_by,
       TO_CHAR(a.action_date,'YYYY-MM-DD') AS action_date,
       a.posted_flag,
       a.applied_by,
       TO_CHAR(a.applied_on,'YYYY-MM-DD HH24:MI') AS applied_on,
       op.project_manager_id AS old_project_manager_id,
       np.project_manager_id AS new_project_manager_id
  FROM oc_ts_adjustment a
  JOIN oc_time_worker  w  ON w.employee_id = a.employee_id
  JOIN oc_time_period  sp ON sp.period_id  = a.source_period_id
  JOIN oc_time_period  pp ON pp.period_id  = a.post_period_id
  JOIN oc_time_project op ON op.project_id = a.old_project_id
  JOIN oc_time_task    ot ON ot.task_id    = a.old_task_id
  LEFT JOIN oc_time_project np ON np.project_id = a.new_project_id
  LEFT JOIN oc_time_task    nt ON nt.task_id    = a.new_task_id;

PROMPT
PROMPT ============================================================
PROMPT time/05_adjustment_llc_salary complete.
PROMPT ============================================================
--== END 05_adjustment_llc_salary.sql ==

PROMPT >>> 06 client documents & sync telemetry

--==============================================================
-- BEGIN 06_client_docs_sync.sql
--==============================================================
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
--== END 06_client_docs_sync.sql ==

PROMPT >>> 07 accrual interface (XX_O2C_TIMESHEET_ACCRUAL_IF)

--==============================================================
-- BEGIN 07_accrual_interface.sql
--==============================================================
--==============================================================
-- time/07_accrual_interface.sql
-- O2C Timesheet Module — Accrual hand-off interface (INT-014)
--
-- XX_O2C_TIMESHEET_ACCRUAL_IF is the contract between this standalone Time
-- application and the O2C Revenue Accrual application. On month confirmation
-- (PROC-009) we FILL this table with the consolidated timesheet
-- (employee x project x WBS x day) plus the day-wise Reversal(-)/Adjustment(+)
-- rows. The accrual application then PULLS from it — it is never pushed
-- row-by-row into accrual's own tables from here.
--
-- Consequences of "accrual pulls":
--   * rows must be self-describing (names as well as ids), because the reader
--     does not share our master-data cache;
--   * rows must be idempotent and re-readable, so PROCESSED_FLAG / PULLED_ON /
--     BATCH_ID let the consumer claim a batch exactly once and let us prove
--     what was handed over (OBS-005, REP-001);
--   * only manager-confirmed months land here (RULE-020) — enforced by
--     OC_TIME_PKG.confirm_month, which is the only writer.
--
-- Column set as specified in INT-014:
--   PERIOD, EMPLOYEE_ID/NAME, PROJECT/WBS_TASK, WORK_DATE,
--   BILLABLE/NON_BILLABLE/LEAVE_HOURS, UNBILLED_REASON,
--   ENTRY_TYPE (Actual/Default/Reversal/Adjustment), FLAG, ACTION_DATE,
--   SOURCE_TS_ID
--
-- Requirement refs: PROC-009, PAGE-011, INT-014, RA-019, RULE-020,
--                   FLD-102..FLD-109, REP-001, REP-002, REP-004, OBS-005
-- Idempotent. Depends on: time/01 .. time/06
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/5] XX_O2C_TIMESHEET_ACCRUAL_IF — interface table
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE xx_o2c_timesheet_accrual_if (
      IF_ID            NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      -- ── Period & confirmation context ────────────────────────
      PERIOD           VARCHAR2(30 CHAR)  NOT NULL,   -- 'JUL-2026'
      PERIOD_YEAR      NUMBER(4)          NOT NULL,
      PERIOD_MONTH     NUMBER(2)          NOT NULL,
      CONFIRM_ID       NUMBER             NOT NULL,   -- OC_TS_MONTH_CONFIRM
      -- ── Who ─────────────────────────────────────────────────
      EMPLOYEE_ID      VARCHAR2(50 CHAR)  NOT NULL,
      EMPLOYEE_NAME    VARCHAR2(200 CHAR) NOT NULL,
      WORKER_TYPE      VARCHAR2(20 CHAR),             -- Employee | Contractor
      -- ── What ────────────────────────────────────────────────
      PROJECT_NUMBER   VARCHAR2(60 CHAR)  NOT NULL,
      PROJECT_NAME     VARCHAR2(240 CHAR) NOT NULL,
      CUSTOMER_NAME    VARCHAR2(240 CHAR),
      REVENUE_MODEL    VARCHAR2(20 CHAR),
      WBS_TASK         VARCHAR2(60 CHAR)  NOT NULL,   -- task_code
      WBS_TASK_NAME    VARCHAR2(240 CHAR),
      -- ── When ────────────────────────────────────────────────
      WORK_DATE        DATE               NOT NULL,   -- day-wise, never rolled up
      -- ── How many ────────────────────────────────────────────
      BILLABLE_HOURS     NUMBER(8,2) DEFAULT 0 NOT NULL,
      NON_BILLABLE_HOURS NUMBER(8,2) DEFAULT 0 NOT NULL,
      LEAVE_HOURS        NUMBER(8,2) DEFAULT 0 NOT NULL,
      UNBILLED_REASON    VARCHAR2(60 CHAR),
      -- ── Classification ──────────────────────────────────────
      ENTRY_TYPE       VARCHAR2(12 CHAR)  NOT NULL,   -- Actual|Default|Reversal|Adjustment
      FLAG             VARCHAR2(60 CHAR),             -- the 8-value workflow flag set
      ACTION_DATE      DATE,                          -- manager approval action date
      -- ── Traceability back to us ─────────────────────────────
      SOURCE_TS_ID     NUMBER,                        -- OC_TS_ENTRY.TS_ENTRY_ID
      SOURCE_ADJ_ID    NUMBER,                        -- OC_TS_ADJUSTMENT.ADJUSTMENT_ID
      SOURCE_SYSTEM    VARCHAR2(30 CHAR) DEFAULT 'O2C_TIME' NOT NULL,
      TRACE_ID         VARCHAR2(64 CHAR),
      -- ── Pull bookkeeping (consumer-owned) ───────────────────
      BATCH_ID         VARCHAR2(64 CHAR)  NOT NULL,
      PROCESSED_FLAG   CHAR(1) DEFAULT 'N' NOT NULL,
      PULLED_ON        TIMESTAMP,
      PULLED_BY        VARCHAR2(100 CHAR),
      PROCESS_MESSAGE  VARCHAR2(2000 CHAR),
      -- ── Ours ────────────────────────────────────────────────
      CREATED_BY       VARCHAR2(100 CHAR) DEFAULT 'O2C_TIME' NOT NULL,
      CREATED_ON       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT chk_xx_tsif_etype CHECK (entry_type IN
        ('Actual','Default','Reversal','Adjustment')),
      CONSTRAINT chk_xx_tsif_proc  CHECK (processed_flag IN ('N','Y','E')), -- E = error
      CONSTRAINT chk_xx_tsif_month CHECK (period_month BETWEEN 1 AND 12),
      -- Reversal rows are negative, everything else is non-negative. Guarantees
      -- the consumer can SUM() the three hour columns without sign handling.
      CONSTRAINT chk_xx_tsif_sign CHECK (
        (entry_type = 'Reversal'
           AND billable_hours <= 0 AND non_billable_hours <= 0 AND leave_hours <= 0)
        OR
        (entry_type <> 'Reversal'
           AND billable_hours >= 0 AND non_billable_hours >= 0 AND leave_hours >= 0)),
      -- Every row traces to exactly one origin.
      CONSTRAINT chk_xx_tsif_source CHECK (
        source_ts_id IS NOT NULL OR source_adj_id IS NOT NULL),
      -- Re-running confirm_month for the same month must not double-post.
      CONSTRAINT uk_xx_tsif_row UNIQUE
        (confirm_id, employee_id, project_number, wbs_task, work_date, entry_type,
         source_ts_id, source_adj_id)
    )
  ]';
  DBMS_OUTPUT.PUT_LINE('XX_O2C_TIMESHEET_ACCRUAL_IF created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('XX_O2C_TIMESHEET_ACCRUAL_IF already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- The consumer's read pattern: unprocessed rows for a period, in batch order.
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_xx_tsif_pull ON xx_o2c_timesheet_accrual_if(processed_flag, period_year, period_month, batch_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_xx_tsif_confirm ON xx_o2c_timesheet_accrual_if(confirm_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_xx_tsif_emp ON xx_o2c_timesheet_accrual_if(employee_id, work_date)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_xx_tsif_batch ON xx_o2c_timesheet_accrual_if(batch_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/5] V_OC_TS_ACCRUAL_EXTRACT — day-wise extract (PAGE-011)
PROMPT ============================================================

-- FLD-102..FLD-109 / REP-001. What PAGE-011 shows and what the accrual
-- application sees, from the same rows, so the screen can never disagree with
-- the hand-off.
CREATE OR REPLACE VIEW v_oc_ts_accrual_extract AS
SELECT i.if_id,
       i.confirm_id,
       i.period,
       i.period_year,
       i.period_month,
       i.employee_id,
       i.employee_name,
       i.worker_type,
       i.project_number,
       i.project_name,
       i.customer_name,
       i.revenue_model,
       i.wbs_task,
       i.wbs_task_name,
       i.wbs_task || ' / ' || TO_CHAR(i.work_date,'YYYY-MM-DD') AS wbs_date, -- FLD-107
       TO_CHAR(i.work_date,'YYYY-MM-DD') AS work_date,
       i.billable_hours     AS billed,      -- FLD-104
       i.non_billable_hours AS unbilled,    -- FLD-105
       i.leave_hours        AS leave_hours, -- FLD-106
       i.unbilled_reason,
       i.entry_type,                        -- FLD-108
       CASE WHEN i.entry_type IN ('Reversal','Adjustment')
            THEN 'Manager-approved' ELSE 'Manager-approved' END AS approval, -- FLD-109
       i.flag,
       TO_CHAR(i.action_date,'YYYY-MM-DD') AS action_date,
       i.batch_id,
       i.processed_flag,
       TO_CHAR(i.pulled_on,'YYYY-MM-DD HH24:MI') AS pulled_on,
       i.source_ts_id,
       i.source_adj_id,
       i.trace_id
  FROM xx_o2c_timesheet_accrual_if i;

PROMPT ============================================================
PROMPT [3/5] V_OC_TS_CONFIRMED_MONTHS — confirmed-months table (PAGE-011)
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_confirmed_months AS
SELECT c.confirm_id,
       c.project_id,
       p.project_number,
       p.project_name,
       p.customer_name,
       p.revenue_model,
       c.period_id,
       pe.period_name,
       c.period_year,
       c.period_month,
       c.employee_count,
       c.billable_hours,
       c.non_billable_hours,
       c.leave_hours,
       c.adjustment_hours,
       c.confirm_type,
       c.confirmed_by,
       TO_CHAR(c.confirmed_on, 'YYYY-MM-DD HH24:MI') AS confirmed_on,
       c.otl_status,
       TO_CHAR(c.otl_pushed_on, 'YYYY-MM-DD HH24:MI') AS otl_pushed_on,
       c.otl_message,
       c.accrual_status,
       c.accrual_rows,
       TO_CHAR(c.accrual_pushed_on, 'YYYY-MM-DD HH24:MI') AS accrual_pushed_on,
       c.accrual_message,
       c.partner_status,
       c.trace_id,
       -- How much of what we handed over has actually been consumed.
       (SELECT COUNT(*) FROM xx_o2c_timesheet_accrual_if i
         WHERE i.confirm_id = c.confirm_id AND i.processed_flag = 'Y') AS rows_pulled,
       (SELECT COUNT(*) FROM xx_o2c_timesheet_accrual_if i
         WHERE i.confirm_id = c.confirm_id AND i.processed_flag = 'N') AS rows_pending
  FROM oc_ts_month_confirm c
  JOIN oc_time_project     p  ON p.project_id = c.project_id
  JOIN oc_time_period      pe ON pe.period_id = c.period_id;

PROMPT ============================================================
PROMPT [4/5] V_OC_TS_LLC_ANNEXURE — invoice annexure (REP-002)
PROMPT ============================================================

-- Approved leave-loss coverage becomes BILLED absence hours for FCP projects
-- and flows with the invoice as an appendix (PROC-006). Only approved lines
-- appear — an assigned-but-unapproved cover is not billable.
CREATE OR REPLACE VIEW v_oc_ts_llc_annexure AS
SELECT l.llc_id,
       l.project_id,
       p.project_number,
       p.project_name,
       p.customer_name,
       p.revenue_model,
       l.period_id,
       pe.period_name,
       l.absent_employee_id,
       aw.employee_name AS absent_employee_name,
       TO_CHAR(l.absence_date,'YYYY-MM-DD') AS absence_date,
       l.absence_type,
       l.absence_hours  AS covered_billed_hours,
       l.cover_employee_id,
       cw.employee_name AS cover_employee_name,
       l.llc_status,
       l.billed_flag,
       l.approved_by,
       TO_CHAR(l.approved_on,'YYYY-MM-DD HH24:MI') AS approved_on
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_project p  ON p.project_id  = l.project_id
  JOIN oc_time_period  pe ON pe.period_id  = l.period_id
  JOIN oc_time_worker  aw ON aw.employee_id = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id
 WHERE l.llc_status  = 'Approved'
   AND l.billed_flag = 'Y';

PROMPT ============================================================
PROMPT [5/5] V_OC_TS_COMPLIANCE — status dashboard (REP-005)
PROMPT ============================================================

-- The 7 statuses and 6 flags (revised 30-Jul-2026), counted by project /
-- manager / week, for the compliance dashboard.
CREATE OR REPLACE VIEW v_oc_ts_compliance AS
SELECT w.period_id,
       pe.period_name,
       w.period_year,
       w.period_month,
       w.week_index,
       TO_CHAR(w.week_start,'YYYY-MM-DD') AS week_start,
       wk.manager_emp_id,
       COUNT(*)                                                          AS employees,
       SUM(CASE WHEN w.week_status = 'Not yet submitted' THEN 1 ELSE 0 END) AS not_submitted,
       SUM(CASE WHEN w.week_status = 'Submitted'         THEN 1 ELSE 0 END) AS submitted,
       SUM(CASE WHEN w.week_status IN ('Approved','Overridden and approved')
                                                         THEN 1 ELSE 0 END) AS approved,
       SUM(CASE WHEN w.week_status = 'Rejected'          THEN 1 ELSE 0 END) AS rejected,
       SUM(CASE WHEN w.week_status = 'Defaulted'         THEN 1 ELSE 0 END) AS defaulted,
       SUM(CASE WHEN w.week_status = 'Closed'            THEN 1 ELSE 0 END) AS closed,
       -- 'Late submission' and 'Manager Defaulted' are no longer statuses
       -- (revised 30-Jul-2026), so they are counted from the flag and from
       -- DEFAULTED_BY instead of from WEEK_STATUS.
       SUM(CASE WHEN w.late_submission_flag = 'Y' THEN 1 ELSE 0 END) AS late,
       SUM(CASE WHEN w.week_status  = 'Defaulted'
                 AND w.defaulted_by = 'MANAGER'  THEN 1 ELSE 0 END) AS manager_defaulted,
       SUM(CASE WHEN w.week_status  = 'Defaulted'
                 AND w.defaulted_by = 'EMPLOYEE' THEN 1 ELSE 0 END) AS employee_defaulted,
       SUM(CASE WHEN w.overridden_flag      = 'Y' THEN 1 ELSE 0 END) AS overridden,
       SUM(CASE WHEN w.advance_closure_flag = 'Y' THEN 1 ELSE 0 END) AS advance_closed
  FROM oc_ts_week     w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
  JOIN oc_time_period pe ON pe.period_id   = w.period_id
 GROUP BY w.period_id, pe.period_name, w.period_year, w.period_month,
          w.week_index, w.week_start, wk.manager_emp_id;

PROMPT ============================================================
PROMPT [6/6] V_OC_TS_O2C_PUSH_* — consolidated push to the main O2C app
PROMPT ============================================================

-- The hand-off to the main O2C application's timesheet -> accrual chain.
--
--   POST /oc/accrual/timesheet/import             -> OC_TIMESHEET_HEADER
--   POST /oc/accrual/timesheet/lines/import/{id}  -> OC_TIMESHEET_LINE
--   POST /oc/accrual/accruals/generate            -> their accrual takes over
--
-- Both endpoints upsert, so re-confirming a month is safe and self-correcting.
--
-- Source is XX_O2C_TIMESHEET_ACCRUAL_IF, not the live tables. That matters: the
-- interface rows are the frozen, manager-confirmed set, and Reversal rows are
-- already stored with NEGATIVE hours, so a plain SUM nets a retro correction
-- against its Adjustment pair with no sign handling. Summing OC_TS_ENTRY instead
-- would double-count every adjusted day.
--
-- Two deliberate reductions, because their model is coarser than ours:
--   * no task dimension  - their line is UNIQUE (ts_header_id, entry_date), so
--     a day's task lines collapse into one row. Task detail stays here, where
--     OC_TS_ENTRY remains the system of record for it.
--   * 7 statuses -> 4    - their CHK allows Draft|Submitted|Approved|Rejected.
--     Anything we have confirmed is, by definition, manager-approved.

CREATE OR REPLACE VIEW v_oc_ts_o2c_push_header AS
SELECT i.confirm_id,
       p.main_project_id                          AS project_id,     -- THEIR id
       i.project_number,
       i.employee_id,
       MAX(i.employee_name)                       AS employee_name,
       -- Their CHK is Billable | Non-Billable. A month with any billable hour
       -- is billable; only a wholly non-billable month is flagged as such.
       CASE WHEN SUM(i.billable_hours) > 0
            THEN 'Billable' ELSE 'Non-Billable' END AS billing_status,
       i.period_year,
       i.period_month,
       ROUND(SUM(i.billable_hours), 2)            AS billable_hours,
       ROUND(SUM(i.non_billable_hours), 2)        AS non_billable_hours,
       ROUND(SUM(i.leave_hours), 2)               AS leave_hours,
       COUNT(DISTINCT i.work_date)                AS working_days,
       'Approved'                                 AS status,
       -- A project that has never been mapped cannot be pushed. Surfaced as a
       -- row with a reason rather than dropped, so a blocked month is visible
       -- instead of silently missing from the main app.
       CASE WHEN p.main_project_id IS NULL
            THEN 'BLOCKED: no MAIN_PROJECT_ID for ' || i.project_number
            ELSE 'READY' END                      AS push_state
  FROM xx_o2c_timesheet_accrual_if i
  LEFT JOIN oc_time_project p
    ON p.project_number = i.project_number
 GROUP BY i.confirm_id, p.main_project_id, i.project_number,
          i.employee_id, i.period_year, i.period_month;

CREATE OR REPLACE VIEW v_oc_ts_o2c_push_line AS
SELECT i.confirm_id,
       i.employee_id,
       i.project_number,
       TO_CHAR(i.work_date,'YYYY-MM-DD')      AS entry_date,
       ROUND(SUM(i.billable_hours), 2)        AS billable_hours,
       ROUND(SUM(i.non_billable_hours), 2)    AS non_billable_hours,
       -- Their line carries a single IS_LEAVE flag, not leave hours. A day with
       -- any leave is marked; the hours themselves are already in the header.
       CASE WHEN SUM(i.leave_hours) > 0 THEN 'Y' ELSE 'N' END AS is_leave,
       -- Entry types present on the day, so a corrected day is identifiable in
       -- the main app without it needing to model reversals.
       LISTAGG(DISTINCT i.entry_type, ',')
         WITHIN GROUP (ORDER BY i.entry_type)   AS remarks
  FROM xx_o2c_timesheet_accrual_if i
 GROUP BY i.confirm_id, i.employee_id, i.project_number, i.work_date;

PROMPT
PROMPT ============================================================
PROMPT time/07_accrual_interface complete.
PROMPT ============================================================
--== END 07_accrual_interface.sql ==

PROMPT >>> 08 page views

--==============================================================
-- BEGIN 08_views.sql
--==============================================================
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
   -- Both flags, decided 06-Aug-2026. Chargeable alone let a task through that
   -- Fusion does not consider billable work - on project 444 that is the Leave
   -- task, which is chargeable but not billable and is system-owned anyway
   -- (RULE-008). A task an employee may pick must be both.
   AND t.chargeable_flag = 'Y'
   -- BILLABLE_TYPE, not a flag: this module has no BILLABLE_FLAG column. Fusion
   -- returns BillableFlag true/false and the sync lands it here as the word.
   AND t.billable_type   = 'Billable'
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

PROMPT ============================================================
PROMPT [10/10] V_OC_TS_WEEK_ACTIVITY - change history AND decisions
PROMPT ============================================================

-- Everything that has happened to a week, in one list (REP-007 / NFR-010).
--
-- WHY THIS EXISTS
--
-- OC_TS_AUDIT records only what CHK_OC_TSAU_TYPE allows - Override, Adjustment,
-- Reversal, ManagerEdit, Import, DefaultCorrection - which is to say, changes to
-- the VALUES. A manager approving or rejecting changes no value, so it writes to
-- OC_TS_APPROVAL and nothing at all to OC_TS_AUDIT. The Change history panel
-- read the audit table alone, so a week whose seven days had just been rejected
-- reported "Nothing has been changed on this week": true to the letter, and
-- useless as evidence for the decision it sits underneath.
--
-- Both halves are needed and neither belongs inside the other: a decision has no
-- old and new hours, and a correction has no reject reason. They are unioned
-- here with a KIND column so the screen can render each properly, and
-- ACTIVITY_ID is prefixed because the two source keys are independent identity
-- columns that would otherwise collide.
CREATE OR REPLACE VIEW v_oc_ts_week_activity AS
SELECT 'A' || a.audit_id                          AS activity_id,
       a.ts_week_id,
       'Change'                                   AS kind,
       'DAY'                                      AS scope,
       a.employee_id,
       w.employee_name,
       TO_CHAR(a.entry_date,'YYYY-MM-DD')         AS entry_date,
       a.change_type,
       op.project_name                            AS old_project_name,
       ot.task_code                               AS old_task_code,
       a.old_hours,
       np.project_name                            AS new_project_name,
       nt.task_code                               AS new_task_code,
       a.new_hours,
       (NVL(a.new_hours,0) - NVL(a.old_hours,0))  AS delta_hours,
       a.change_reason,
       a.changed_by,
       TO_CHAR(a.changed_on,'YYYY-MM-DD HH24:MI:SS') AS changed_on
  FROM oc_ts_audit    a
  JOIN oc_time_worker w  ON w.employee_id = a.employee_id
  LEFT JOIN oc_time_project op ON op.project_id = a.old_project_id
  LEFT JOIN oc_time_project np ON np.project_id = a.new_project_id
  LEFT JOIN oc_time_task    ot ON ot.task_id    = a.old_task_id
  LEFT JOIN oc_time_task    nt ON nt.task_id    = a.new_task_id
UNION ALL
SELECT 'D' || v.approval_id                       AS activity_id,
       v.ts_week_id,
       'Decision'                                 AS kind,
       v.granularity                              AS scope,
       v.employee_id,
       w.employee_name,
       TO_CHAR(v.entry_date,'YYYY-MM-DD')         AS entry_date,
       v.action                                   AS change_type,
       CAST(NULL AS VARCHAR2(240 CHAR))           AS old_project_name,
       CAST(NULL AS VARCHAR2(60 CHAR))            AS old_task_code,
       CAST(NULL AS NUMBER)                       AS old_hours,
       CAST(NULL AS VARCHAR2(240 CHAR))           AS new_project_name,
       CAST(NULL AS VARCHAR2(60 CHAR))            AS new_task_code,
       CAST(NULL AS NUMBER)                       AS new_hours,
       CAST(NULL AS NUMBER)                       AS delta_hours,
       -- FLD-057 and FLD-058 read as one sentence; separately they are a bare
       -- code and a comment with nothing to attach it to.
       LTRIM(v.reject_reason || CASE WHEN v.reject_reason IS NOT NULL
                                      AND v.remarks IS NOT NULL
                                     THEN ' - ' END || v.remarks)
                                                  AS change_reason,
       -- The person, not the id. NVL because a job actor (SCHEDULER) is not a
       -- worker and must still be named rather than vanishing.
       NVL(act.employee_name, v.actor_emp_id)     AS changed_by,
       TO_CHAR(v.action_on,'YYYY-MM-DD HH24:MI:SS') AS changed_on
  FROM oc_ts_approval v
  JOIN oc_time_worker w   ON w.employee_id  = v.employee_id
  LEFT JOIN oc_time_worker act ON act.employee_id = v.actor_emp_id
 WHERE v.ts_week_id IS NOT NULL;

PROMPT
PROMPT ============================================================
PROMPT time/08_views complete.
PROMPT ============================================================
--== END 08_views.sql ==

-- ── Tables the package body reads ────────────────────────────
-- 15 runs HERE, ahead of its number, and the number is not the mistake.
--
-- OC_TIME_PKG references OC_TS_SALARY_HOLD_DAY in six procedures. Created after
-- the package, every one of those is ORA-00942 and the body compiles INVALID --
-- nine errors from one missing table. A recompile after step 15 fixed the full
-- installer and fixed nothing else: running 09 on its own, which is the normal
-- thing to do after editing the package, still failed. Ordering the dependency
-- correctly fixes both.
--
-- 15 only needs 01, 03 and 05, all of which are already done by here.
PROMPT >>> 15 salary stopping, day-wise (PROC-007 revised)

--==============================================================
-- BEGIN 15_salary_hold_days.sql
--==============================================================
--==============================================================
-- time/15_salary_hold_days.sql
-- O2C Timesheet Module — salary stopping, day-wise (PROC-007 revised)
--
-- Functional owner, 08/10-Aug-2026, verbatim:
--
--   "on the day you have configured in the control for payroll date + 1 you
--    will run the process and just create data in a secondary table with the
--    dates for which the time is not yet submitted by the employee. No other
--    action needed"
--
--   "the data will be moved to a separate table and will be displayed to
--    employee for a period of 60 calendar days to correct by date and get it
--    approved"
--
--   applicable to "all employees irrespective of grade" — and to contractors:
--   the question named "employees/contractors" and was answered yes.
--
-- WHAT THAT CHANGES ABOUT WHAT WAS BUILT
--
--   grain      OC_TS_SALARY_HOLD is one row per employee per PERIOD, counting
--              weeks. The owner asked for DATES, twice, and the correction is
--              "by date". A week-grained hold cannot express "these four days".
--              So the header stays — it still owns the release decision and the
--              payroll notification — and this adds the day rows under it.
--
--   trigger    was the weekly cut-off and the defaulting jobs. Now PAYROLL
--              CUT-OFF + 1, which is a different date entirely and is already
--              on OC_TIME_PERIOD as PAYROLL_CUTOFF.
--
--   who        contractors were excluded on assumption RA-012. That assumption
--              is now WRONG and is retired here.
--
--   test       "not yet submitted BY THE EMPLOYEE" is read as SUBMITTED_ON IS
--              NULL. That is the literal reading and it also preserves RULE-016
--              for free: a week the employee submitted has a stamp, so a
--              manager who has not yet approved it can never hold anyone's pay.
--
-- OPEN, AND DELIBERATELY NOT GUESSED: a REJECTED week was submitted once, so it
-- has a stamp and is not held here — but its hours will not reach payroll
-- either. Confirm whether a rejected week should be held. Changing it later is
-- one predicate.
--
-- Idempotent. Depends on: time/01, time/03, time/05
--
-- RUNS BEFORE 09 DESPITE THE NUMBER. OC_TIME_PKG reads
-- OC_TS_SALARY_HOLD_DAY in six procedures, so creating it after the package
-- gives nine ORA-00942s and an INVALID body. If you are applying scripts by
-- hand, run this one before 09_pkg_oc_time.sql -- install_time.sql already
-- does.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] OC_TS_SALARY_HOLD_DAY — the dates, and their correction
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_ts_salary_hold_day (
      HOLD_DAY_ID     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      HOLD_ID         NUMBER            NOT NULL,
      EMPLOYEE_ID     VARCHAR2(50 CHAR) NOT NULL,
      PERIOD_ID       NUMBER            NOT NULL,
      WORK_DATE       DATE              NOT NULL,
      -- The week the day belongs to, so the employee screen can link straight
      -- to the timesheet rather than making them find it.
      TS_WEEK_ID      NUMBER,
      -- What the day SHOULD have carried, from the resolved calendar. Kept so
      -- the held amount is reproducible after the calendar later changes.
      EXPECTED_HOURS  NUMBER(5,2) DEFAULT 0 NOT NULL,
      DAY_STATUS      VARCHAR2(20 CHAR) DEFAULT 'Held' NOT NULL,
      -- ── the employee's correction ────────────────────────────
      CORRECTED_HOURS NUMBER(5,2),
      CORRECTION_REASON VARCHAR2(1000 CHAR),
      CORRECTED_BY    VARCHAR2(100 CHAR),
      CORRECTED_ON    TIMESTAMP,
      -- ── the manager's decision on it ─────────────────────────
      APPROVED_BY     VARCHAR2(100 CHAR),
      APPROVED_ON     TIMESTAMP,
      REJECT_REMARKS  VARCHAR2(1000 CHAR),
      CREATED_BY      VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY      VARCHAR2(100),
      UPDATED_ON      TIMESTAMP,
      -- Held      the job found the day unsubmitted
      -- Corrected the employee has entered hours and a reason
      -- Approved  a manager accepted the correction; pay can be released
      -- Rejected  sent back; still held
      -- Expired   the 60-day window closed with no approved correction
      CONSTRAINT chk_oc_tsshd_status CHECK (day_status IN
        ('Held','Corrected','Approved','Rejected','Expired')),
      -- A correction must say what and why; an approval must name someone.
      CONSTRAINT chk_oc_tsshd_corr CHECK (
        day_status NOT IN ('Corrected','Approved')
        OR (corrected_hours IS NOT NULL AND corrected_by IS NOT NULL)),
      CONSTRAINT chk_oc_tsshd_appr CHECK (
        day_status <> 'Approved' OR approved_by IS NOT NULL),
      CONSTRAINT chk_oc_tsshd_hrs  CHECK (
        corrected_hours IS NULL OR corrected_hours BETWEEN 0 AND 24),
      -- One row per person per date. Re-running the job must not duplicate.
      CONSTRAINT uk_oc_tsshd_day   UNIQUE (employee_id, work_date),
      CONSTRAINT fk_oc_tsshd_hold  FOREIGN KEY (hold_id)
        REFERENCES oc_ts_salary_hold(hold_id),
      CONSTRAINT fk_oc_tsshd_emp   FOREIGN KEY (employee_id)
        REFERENCES oc_time_worker(employee_id),
      CONSTRAINT fk_oc_tsshd_per   FOREIGN KEY (period_id)
        REFERENCES oc_time_period(period_id)
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TS_SALARY_HOLD_DAY created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_SALARY_HOLD_DAY already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- The employee's own list, and the manager's queue, are both "by date".
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsshd_emp ON oc_ts_salary_hold_day(employee_id, work_date)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsshd_status ON oc_ts_salary_hold_day(day_status, period_id)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/3] V_OC_TS_SALARY_HOLD_MINE — what the employee sees
PROMPT ============================================================

-- The employee's own held dates for 60 calendar days (CFG-012). Carries
-- DAYS_LEFT rather than only the expiry date, because "you have 6 days" is
-- what makes somebody act and "expires 2026-10-09" is not.
--
-- WINDOW_OPEN is the single fact the screen gates on: past it the row is
-- read-only, whatever its status. Computed here so the page, the endpoint and
-- the correction procedure cannot each decide it differently.
CREATE OR REPLACE VIEW v_oc_ts_salary_hold_mine AS
SELECT d.hold_day_id,
       d.hold_id,
       d.employee_id,
       w.employee_name,
       w.worker_type,
       d.period_id,
       p.period_name,
       TO_CHAR(d.work_date,'YYYY-MM-DD')            AS work_date,
       TO_CHAR(d.work_date,'DY')                    AS day_name,
       d.ts_week_id,
       d.expected_hours,
       d.day_status,
       d.corrected_hours,
       d.correction_reason,
       TO_CHAR(d.corrected_on,'YYYY-MM-DD HH24:MI') AS corrected_on,
       d.approved_by,
       TO_CHAR(d.approved_on,'YYYY-MM-DD HH24:MI')  AS approved_on,
       d.reject_remarks,
       h.salary_status,
       TO_CHAR(h.held_on,'YYYY-MM-DD')              AS held_on,
       TO_CHAR(h.window_expires_on,'YYYY-MM-DD')    AS window_expires_on,
       GREATEST(h.window_expires_on - TRUNC(SYSDATE), 0) AS days_left,
       CASE WHEN TRUNC(SYSDATE) <= h.window_expires_on
             AND d.day_status IN ('Held','Rejected')
            THEN 'Y' ELSE 'N' END                   AS window_open
  FROM oc_ts_salary_hold_day d
  JOIN oc_ts_salary_hold     h ON h.hold_id     = d.hold_id
  JOIN oc_time_worker        w ON w.employee_id = d.employee_id
  JOIN oc_time_period        p ON p.period_id   = d.period_id;

PROMPT ============================================================
PROMPT [3/3] V_OC_TS_SALARY_HOLD_QUEUE — the manager's approval queue
PROMPT ============================================================

-- Only corrections actually waiting on somebody. A manager opening this should
-- see work to do, not a list of everything ever held.
CREATE OR REPLACE VIEW v_oc_ts_salary_hold_queue AS
SELECT m.employee_id           AS manager_emp_id,
       d.hold_day_id,
       d.employee_id,
       w.employee_name,
       w.worker_type,
       d.period_id,
       p.period_name,
       TO_CHAR(d.work_date,'YYYY-MM-DD')            AS work_date,
       d.expected_hours,
       d.corrected_hours,
       d.correction_reason,
       TO_CHAR(d.corrected_on,'YYYY-MM-DD HH24:MI') AS corrected_on,
       d.ts_week_id
  FROM oc_ts_salary_hold_day d
  JOIN oc_time_worker w ON w.employee_id = d.employee_id
  JOIN oc_time_worker m ON m.employee_id = w.manager_emp_id
  JOIN oc_time_period p ON p.period_id   = d.period_id
 WHERE d.day_status = 'Corrected';

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN object_name FORMAT A34
COLUMN object_type FORMAT A6
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TS_SALARY_HOLD_DAY',
                       'V_OC_TS_SALARY_HOLD_MINE',
                       'V_OC_TS_SALARY_HOLD_QUEUE')
 ORDER BY object_type, object_name;

PROMPT Done. Run 09_pkg_oc_time.sql after this - run_salary_stopping fills it.
--== END 15_salary_hold_days.sql ==

-- ── Business logic ───────────────────────────────────────────
PROMPT >>> 09 OC_TIME_PKG

--==============================================================
-- BEGIN 09_pkg_oc_time.sql
--==============================================================
--==============================================================
-- time/09_pkg_oc_time.sql
-- O2C Timesheet Module — OC_TIME_PKG business logic
--
-- Single entry point for every state change. The ORDS handlers are thin: they
-- bind parameters and call this package, so the rules live in one place and are
-- identical whether the caller is VBCS, OIC or a scheduled job.
--
-- ── Week model ───────────────────────────────────────────────────────────────
-- Weeks are CLIPPED TO THE MONTH. A calendar week that straddles a month
-- boundary becomes two OC_TS_WEEK rows: the tail of month N and the head of
-- month N+1. This is deliberate:
--   * the employee's Week LOV is "weeks in month" (FLD-002);
--   * the manager confirms a project MONTH in one action (PROC-009), so a week
--     must never contribute hours to two periods;
--   * month aggregation then needs no date arithmetic and cannot double-count.
-- WEEK_START is therefore MAX(Monday of that ISO week, 1st of month) and
-- WEEK_END is MIN(WEEK_START + 6, last of month).
--
-- ── Rules implemented here ───────────────────────────────────────────────────
--   RULE-001 allocation should total 100%              (warning, not blocking)
--   RULE-002 non-billable requires an unbilled reason  (also a table CHECK)
--   RULE-003 max 24 hours per DAY across all lines
--   RULE-004 no hours for future weeks
--   RULE-005 15-minute increments                      (also a table CHECK)
--   RULE-006 weekly cut-off defaulting
--   RULE-007 edit & resubmit until the delivery cut-off; late => Late submission
--   RULE-008 leave comes from Absence only
--   RULE-009 billing loss automatic                    (trigger in time/03)
--   RULE-010 task must be in the WBS or be a common task
--   RULE-011 one shift per employee per day, read-only
--   RULE-012 Sat/Sun editable, default 0
--   RULE-013 rejection reason mandatory                (also a table CHECK)
--   RULE-014 leave-loss cover eligibility
--   RULE-015 a manager never approves their own timesheet
--   RULE-016 only Defaulted stops salary
--   RULE-019 adjustments within the backdating window  (trigger in time/05)
--   RULE-020 accrual confirm needs every employee approved
--   RULE-021 contractor unbilled needs exception approval
--
-- Idempotent (CREATE OR REPLACE). Depends on: time/01 .. time/08
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/2] OC_TIME_PKG — specification
PROMPT ============================================================

CREATE OR REPLACE PACKAGE oc_time_pkg AS

  -- ── Application errors ─────────────────────────────────────
  e_future_week      EXCEPTION;  PRAGMA EXCEPTION_INIT(e_future_week,      -20004);
  e_day_over_24      EXCEPTION;  PRAGMA EXCEPTION_INIT(e_day_over_24,      -20003);
  e_not_editable     EXCEPTION;  PRAGMA EXCEPTION_INIT(e_not_editable,     -20007);
  e_invalid_task     EXCEPTION;  PRAGMA EXCEPTION_INIT(e_invalid_task,     -20010);
  e_no_reason        EXCEPTION;  PRAGMA EXCEPTION_INIT(e_no_reason,        -20013);
  e_cover_invalid    EXCEPTION;  PRAGMA EXCEPTION_INIT(e_cover_invalid,    -20014);
  e_self_approval    EXCEPTION;  PRAGMA EXCEPTION_INIT(e_self_approval,    -20015);
  e_not_all_approved EXCEPTION;  PRAGMA EXCEPTION_INIT(e_not_all_approved, -20020);
  e_no_open_period   EXCEPTION;  PRAGMA EXCEPTION_INIT(e_no_open_period,   -20017);

  -- ── Calendar & period helpers ──────────────────────────────
  -- RULE-017 was relaxed on 04-Aug-2026: more than one period may be Open, so
  -- "the open period" is no longer a single row. This picks deterministically —
  -- the open period containing today, else the earliest open one.
  FUNCTION get_open_period_id RETURN NUMBER;

  -- The period a given DATE falls in, open or not. Preferred over
  -- get_open_period_id wherever the caller already knows the date it is acting
  -- on, because that answer cannot be ambiguous.
  FUNCTION get_period_for_date(p_date IN DATE) RETURN NUMBER;

  PROCEDURE resolve_day(
    p_employee_id  IN  VARCHAR2,
    p_project_id   IN  NUMBER,
    p_date         IN  DATE,
    o_shift_code   OUT VARCHAR2,
    o_std_hours    OUT NUMBER,
    o_is_working   OUT VARCHAR2,
    o_holiday_name OUT VARCHAR2);

  FUNCTION week_start_of(p_date IN DATE) RETURN DATE;
  FUNCTION week_end_of  (p_date IN DATE) RETURN DATE;
  FUNCTION week_index_of(p_date IN DATE) RETURN NUMBER;

  FUNCTION ensure_week(
    p_employee_id IN VARCHAR2,
    p_date        IN DATE,
    p_actor       IN VARCHAR2 DEFAULT 'SYSTEM') RETURN NUMBER;

  -- ── Validation ─────────────────────────────────────────────
  PROCEDURE validate_day(p_ts_week_id IN NUMBER, p_entry_date IN DATE);
  PROCEDURE assert_editable(p_ts_week_id IN NUMBER);
  PROCEDURE assert_not_self(p_employee_id IN VARCHAR2, p_actor_emp_id IN VARCHAR2);
  FUNCTION  allocation_pct(p_employee_id IN VARCHAR2) RETURN NUMBER;

  -- ── Population (PROC-001) ──────────────────────────────────
  FUNCTION populate_month(
    p_period_id   IN NUMBER,
    p_employee_id IN VARCHAR2 DEFAULT NULL,
    p_actor       IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER;   -- job_run_id

  FUNCTION populate_daily(
    p_action_date IN DATE,
    p_scope_key   IN VARCHAR2 DEFAULT NULL,
    p_actor       IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER;   -- job_run_id

  -- ── Employee entry (PROC-002) ──────────────────────────────
  PROCEDURE save_entry(
    p_ts_week_id     IN NUMBER,
    p_project_id     IN NUMBER,
    p_task_id        IN NUMBER,
    p_entry_date     IN DATE,
    p_hours          IN NUMBER,
    p_source         IN VARCHAR2 DEFAULT 'Employee',
    p_unbilled_reason IN VARCHAR2 DEFAULT NULL,
    p_actor          IN VARCHAR2 DEFAULT 'VBCS_USER');

  PROCEDURE remove_line(
    p_ts_week_id IN NUMBER,
    p_project_id IN NUMBER,
    p_task_id    IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER');

  PROCEDURE submit_week(
    p_ts_week_id IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id   IN VARCHAR2 DEFAULT NULL);

  -- Pull a submitted week back so the employee can correct it. Submitted only:
  -- once a manager has approved, undoing it is their decision (a send-back),
  -- not the employee's.
  PROCEDURE revoke_week(
    p_ts_week_id IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id   IN VARCHAR2 DEFAULT NULL);

  -- The two defaulting jobs. Both produce week_status 'Defaulted'; they differ
  -- in who missed the cut-off, and that difference decides whether the
  -- employee's pay is held (RULE-016, TIMESHEET_FLOW.html §01).
  --
  --   weekly   employee never submitted  -> DEFAULTED_BY 'EMPLOYEE', LOCKS,
  --                                         holds salary
  --   delivery manager never decided     -> DEFAULTED_BY 'MANAGER',  no lock,
  --                                         never holds salary
  FUNCTION run_weekly_defaulting(
    p_period_id IN NUMBER,
    p_as_of     IN DATE     DEFAULT SYSDATE,
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER;     -- job_run_id

  FUNCTION run_delivery_defaulting(
    p_period_id IN NUMBER,
    p_as_of     IN DATE     DEFAULT SYSDATE,
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER;     -- job_run_id

  -- ── Manager approval (PROC-003, PROC-004, PROC-005) ────────
  PROCEDURE approve_week(
    p_ts_week_id   IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE reject_week(
    p_ts_week_id   IN NUMBER,
    p_reason       IN VARCHAR2,
    p_remarks      IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE approve_day(
    p_ts_week_id   IN NUMBER,
    p_entry_date   IN DATE,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE reject_day(
    p_ts_week_id   IN NUMBER,
    p_entry_date   IN DATE,
    p_reason       IN VARCHAR2,
    p_remarks      IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  -- Undo a day-level Approve or Reject the manager took by mistake.
  --
  -- The counterpart to revoke_week, and deliberately a DIFFERENT actor: an
  -- employee may pull back their own submission, but only the manager can undo
  -- their own decision, so this one takes p_actor_emp_id and goes through
  -- assert_not_self like every other approval action.
  PROCEDURE revoke_decision(
    p_ts_week_id   IN NUMBER,
    p_entry_date   IN DATE,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  -- The same undo for every decided day in a week, for the week-level buttons.
  PROCEDURE revoke_week_decision(
    p_ts_week_id   IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE override_approve(
    p_ts_entry_id  IN NUMBER,
    p_new_hours    IN NUMBER,
    p_reason       IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE finish_override(
    p_ts_week_id   IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER');

  PROCEDURE approve_employee_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_employee_id  IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE reject_employee_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_employee_id  IN VARCHAR2,
    p_reason       IN VARCHAR2,
    p_remarks      IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  PROCEDURE advance_approve_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_employee_id  IN VARCHAR2 DEFAULT NULL,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL);

  -- ── Leave-loss coverage (PROC-006) ─────────────────────────
  FUNCTION generate_llc_lines(
    p_project_id IN NUMBER,
    p_period_id  IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'SYSTEM') RETURN NUMBER;       -- lines created

  PROCEDURE assign_cover(
    p_llc_id            IN NUMBER,
    p_cover_employee_id IN VARCHAR2,
    p_actor             IN VARCHAR2 DEFAULT 'VBCS_USER');

  PROCEDURE approve_cover(
    p_llc_id       IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER');

  -- ── Salary stopping (PROC-007) ─────────────────────────────
  FUNCTION run_salary_stopping(
    p_period_id IN NUMBER,
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER',
    p_from      IN DATE     DEFAULT NULL) RETURN NUMBER;     -- job_run_id

  PROCEDURE release_salary_hold(
    p_hold_id      IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_remarks      IN VARCHAR2 DEFAULT NULL,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER');

  -- The employee's own correction of one held DATE, inside the 60-day window
  -- (CFG-012). Takes no actor_emp_id and goes through no assert_not_self: this
  -- is somebody correcting their own record, which is the whole point of the
  -- screen -- the manager's sign-off is the control, not the entry.
  PROCEDURE correct_salary_hold_day(
    p_hold_day_id IN NUMBER,
    p_hours       IN NUMBER,
    p_reason      IN VARCHAR2,
    p_actor       IN VARCHAR2 DEFAULT 'VBCS_USER');

  -- The manager's decision on that correction. Approve releases the day;
  -- Reject sends it back and it stays held.
  PROCEDURE decide_salary_hold_day(
    p_hold_day_id  IN NUMBER,
    p_approve      IN VARCHAR2,               -- 'Y' | 'N'
    p_remarks      IN VARCHAR2 DEFAULT NULL,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER');

  -- ── Retro adjustments (PROC-008) ───────────────────────────
  FUNCTION apply_adjustment(
    p_employee_id    IN VARCHAR2,
    p_work_date      IN DATE,
    p_old_project_id IN NUMBER,
    p_old_task_id    IN NUMBER,
    p_old_hours      IN NUMBER,
    p_new_project_id IN NUMBER,
    p_new_task_id    IN NUMBER,
    p_new_hours      IN NUMBER,
    p_reason         IN VARCHAR2,
    p_adj_kind       IN VARCHAR2 DEFAULT 'RetroWBS',
    p_actor          IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id       IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;       -- adjustment_id

  PROCEDURE approve_adjustment(
    p_adjustment_id IN NUMBER,
    p_actor_emp_id  IN VARCHAR2,
    p_actor         IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id      IN VARCHAR2 DEFAULT NULL);

  -- ── Month confirmation & accrual hand-off (PROC-009) ───────
  FUNCTION confirm_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_confirm_type IN VARCHAR2 DEFAULT 'Normal',
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;         -- confirm_id

  PROCEDURE mark_accrual_pulled(
    p_batch_id IN VARCHAR2,
    p_status   IN VARCHAR2 DEFAULT 'Y',
    p_message  IN VARCHAR2 DEFAULT NULL,
    p_actor    IN VARCHAR2 DEFAULT 'ACCRUAL');

  -- ACT-033. Posts retro adjustments approved AFTER their month was confirmed.
  --
  -- confirm_month fills the interface once, at confirmation. An adjustment
  -- approved later writes its Reversal(-)/Adjustment(+) pair to OC_TS_ENTRY but
  -- nothing carries it across, so it would never reach accrual. This is the job
  -- that carries it — PAGE-011's "retro adjustments post day-wise after
  -- approval".
  FUNCTION run_accrual_top_up(
    p_period_id IN NUMBER,
    p_actor     IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id  IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;            -- job_run_id

END oc_time_pkg;
/

PROMPT ============================================================
PROMPT [2/2] OC_TIME_PKG — body
PROMPT ============================================================

CREATE OR REPLACE PACKAGE BODY oc_time_pkg AS

  -- ═══════════════════════════════════════════════════════════
  -- Private helpers
  -- ═══════════════════════════════════════════════════════════

  PROCEDURE log_event(
    p_ts_week_id  IN NUMBER,
    p_employee_id IN VARCHAR2,
    p_project_id  IN NUMBER,
    p_period_id   IN NUMBER,
    p_granularity IN VARCHAR2,
    p_entry_date  IN DATE,
    p_action      IN VARCHAR2,
    p_reason      IN VARCHAR2,
    p_remarks     IN VARCHAR2,
    p_actor_emp   IN VARCHAR2,
    p_trace_id    IN VARCHAR2)
  IS
  BEGIN
    INSERT INTO oc_ts_approval (
      ts_week_id, employee_id, project_id, period_id, granularity, entry_date,
      action, reject_reason, remarks, actor_emp_id, trace_id)
    VALUES (
      p_ts_week_id, p_employee_id, p_project_id, p_period_id, p_granularity,
      p_entry_date, p_action, p_reason, p_remarks, p_actor_emp, p_trace_id);
  END log_event;


  FUNCTION start_job(
    p_job_name IN VARCHAR2,
    p_job_type IN VARCHAR2,
    p_period_id IN NUMBER,
    p_action_date IN DATE,
    p_scope_key IN VARCHAR2,
    p_actor IN VARCHAR2) RETURN NUMBER
  IS
    v_id NUMBER;
  BEGIN
    INSERT INTO oc_time_sync_job (
      job_name, job_type, period_id, action_date, scope_key,
      job_status, triggered_by, trace_id)
    VALUES (
      p_job_name, p_job_type, p_period_id, p_action_date, p_scope_key,
      'Running', p_actor, SYS_GUID())
    RETURNING job_run_id INTO v_id;
    RETURN v_id;
  END start_job;


  PROCEDURE finish_job(
    p_job_run_id IN NUMBER,
    p_read     IN NUMBER,
    p_upserted IN NUMBER,
    p_failed   IN NUMBER,
    p_message  IN VARCHAR2 DEFAULT NULL)
  IS
  BEGIN
    UPDATE oc_time_sync_job
       SET finished_on      = SYSTIMESTAMP,
           job_status       = CASE WHEN p_failed > 0 THEN 'Partial' ELSE 'Success' END,
           records_read     = p_read,
           records_upserted = p_upserted,
           records_failed   = p_failed,
           message          = p_message
     WHERE job_run_id = p_job_run_id;
  END finish_job;


  PROCEDURE fail_record(
    p_job_run_id IN NUMBER,
    p_entity     IN VARCHAR2,
    p_key        IN VARCHAR2,
    p_emp        IN VARCHAR2,
    p_reason     IN VARCHAR2,
    p_code       IN VARCHAR2 DEFAULT NULL)
  IS
  BEGIN
    INSERT INTO oc_time_sync_failed (
      job_run_id, entity_type, entity_key, employee_id, failure_reason, failure_code)
    VALUES (p_job_run_id, p_entity, p_key, p_emp, SUBSTR(p_reason,1,1000), p_code);
  END fail_record;


  -- ═══════════════════════════════════════════════════════════
  -- Calendar & period helpers
  -- ═══════════════════════════════════════════════════════════

  FUNCTION get_open_period_id RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    -- RULE-017 relaxed 04-Aug-2026: UK_OC_TP_SINGLE_OPEN is gone and several
    -- months may be Open at once, so this can no longer be a bare SELECT INTO —
    -- that raised TOO_MANY_ROWS the moment a second month opened.
    --
    -- Deterministic by design, never "whichever row comes back first":
    --   1. the open period that contains today  — the month work is happening in
    --   2. failing that, the EARLIEST open one  — a backlog is worked oldest
    --      first, and picking the newest would silently skip it
    SELECT period_id INTO v_id FROM (
      SELECT period_id
        FROM oc_time_period
       WHERE status = 'Open'
       ORDER BY CASE WHEN TRUNC(SYSDATE) BETWEEN start_date AND end_date
                     THEN 0 ELSE 1 END,
                start_date)
     WHERE ROWNUM = 1;
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20017, 'No period is currently Open.');
  END get_open_period_id;


  FUNCTION get_period_for_date(p_date IN DATE) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    SELECT period_id INTO v_id
      FROM oc_time_period
     WHERE TRUNC(p_date) BETWEEN start_date AND end_date;
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20017,
        'No period covers ' || TO_CHAR(p_date, 'DD-Mon-YYYY') || '.');
  END get_period_for_date;


  -- Weeks are clipped to the month (see header note).
  FUNCTION week_start_of(p_date IN DATE) RETURN DATE IS
  BEGIN
    RETURN GREATEST(TRUNC(p_date, 'IW'), TRUNC(p_date, 'MM'));
  END week_start_of;

  FUNCTION week_end_of(p_date IN DATE) RETURN DATE IS
  BEGIN
    RETURN LEAST(TRUNC(p_date,'IW') + 6, LAST_DAY(TRUNC(p_date,'MM')));
  END week_end_of;

  FUNCTION week_index_of(p_date IN DATE) RETURN NUMBER IS
  BEGIN
    -- 1-based index of the clipped week inside its month.
    RETURN TRUNC((TRUNC(p_date,'IW') - TRUNC(TRUNC(p_date,'MM'),'IW')) / 7) + 1;
  END week_index_of;


  -- PROC-013 / SC-21: Shift > Client > Project > Corporate.
  PROCEDURE resolve_day(
    p_employee_id  IN  VARCHAR2,
    p_project_id   IN  NUMBER,
    p_date         IN  DATE,
    o_shift_code   OUT VARCHAR2,
    o_std_hours    OUT NUMBER,
    o_is_working   OUT VARCHAR2,
    o_holiday_name OUT VARCHAR2)
  IS
    v_country  oc_time_worker.base_country%TYPE;
    v_std      oc_time_worker.std_hours_per_day%TYPE;
    v_customer oc_time_project.customer_id%TYPE;
  BEGIN
    -- Deputation wins over base country for calendar purposes (PROC-001).
    SELECT NVL(deputed_country, base_country), std_hours_per_day
      INTO v_country, v_std
      FROM oc_time_worker
     WHERE employee_id = p_employee_id;

    BEGIN
      SELECT customer_id INTO v_customer
        FROM oc_time_project WHERE project_id = p_project_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_customer := NULL; END;

    -- Highest-precedence matching layer wins. Scope keys are checked in the
    -- same order the precedence implies, so the first hit is the answer.
    BEGIN
      SELECT shift_code, NVL(std_hours, v_std), is_working_day, holiday_name
        INTO o_shift_code, o_std_hours, o_is_working, o_holiday_name
        FROM (SELECT c.shift_code, c.std_hours, c.is_working_day, c.holiday_name
                FROM oc_time_calendar c
               WHERE c.cal_date = TRUNC(p_date)
                 AND ( (c.layer = 'SHIFT'     AND c.scope_key = p_employee_id)
                    OR (c.layer = 'CLIENT'    AND c.scope_key = v_customer)
                    OR (c.layer = 'PROJECT'   AND c.scope_key = TO_CHAR(p_project_id))
                    OR (c.layer = 'CORPORATE' AND c.scope_key = v_country) )
               ORDER BY c.precedence DESC)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      -- No calendar row: fall back to Mon-Fri at the worker's standard hours.
      o_shift_code   := NULL;
      o_std_hours    := v_std;
      o_is_working   := CASE WHEN TO_CHAR(TRUNC(p_date),'DY','NLS_DATE_LANGUAGE=ENGLISH')
                                  IN ('SAT','SUN') THEN 'N' ELSE 'Y' END;
      o_holiday_name := NULL;
    END;

    -- RULE-012: weekends are enterable but never pre-filled, so standard hours
    -- on a non-working day are zero.
    IF o_is_working = 'N' THEN
      o_std_hours := 0;
    END IF;
  END resolve_day;


  FUNCTION ensure_week(
    p_employee_id IN VARCHAR2,
    p_date        IN DATE,
    p_actor       IN VARCHAR2 DEFAULT 'SYSTEM') RETURN NUMBER
  IS
    v_id     NUMBER;
    v_ws     DATE := week_start_of(p_date);
    v_we     DATE := week_end_of(p_date);
    v_period NUMBER;
  BEGIN
    BEGIN
      SELECT ts_week_id INTO v_id
        FROM oc_ts_week
       WHERE employee_id = p_employee_id AND week_start = v_ws;
      RETURN v_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL; END;

    -- The week belongs to the period that contains its (clipped) start.
    SELECT period_id INTO v_period
      FROM oc_time_period
     WHERE period_year  = EXTRACT(YEAR  FROM v_ws)
       AND period_month = EXTRACT(MONTH FROM v_ws)
       AND ROWNUM = 1;

    INSERT INTO oc_ts_week (
      employee_id, period_id, period_year, period_month, week_index,
      week_start, week_end, week_status, created_by)
    VALUES (
      p_employee_id, v_period,
      EXTRACT(YEAR FROM v_ws), EXTRACT(MONTH FROM v_ws), week_index_of(p_date),
      v_ws, v_we, 'Not yet submitted', p_actor)
    RETURNING ts_week_id INTO v_id;

    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20017,
        'No period is defined for ' || TO_CHAR(v_ws,'MON-YYYY') || '.');
    WHEN DUP_VAL_ON_INDEX THEN
      -- Lost a race; the other session created it.
      SELECT ts_week_id INTO v_id
        FROM oc_ts_week
       WHERE employee_id = p_employee_id AND week_start = v_ws;
      RETURN v_id;
  END ensure_week;


  -- ═══════════════════════════════════════════════════════════
  -- Validation
  -- ═══════════════════════════════════════════════════════════

  -- RULE-003: the DAILY total across every line must not exceed 24h. Allocation
  -- may exceed 100% but a day cannot exceed 24 hours.
  PROCEDURE validate_day(p_ts_week_id IN NUMBER, p_entry_date IN DATE) IS
    v_total NUMBER;
    v_leave NUMBER;
    v_work  NUMBER;
    v_std   NUMBER;
  BEGIN
    SELECT NVL(SUM(hours),0),
           NVL(SUM(CASE WHEN is_leave = 'Y' THEN hours END),0),
           NVL(SUM(CASE WHEN is_leave = 'N' THEN hours END),0),
           NVL(MAX(standard_hours),0)
      INTO v_total, v_leave, v_work, v_std
      FROM oc_ts_entry
     WHERE ts_week_id = p_ts_week_id
       AND entry_date = TRUNC(p_entry_date)
       AND entry_type IN ('Actual','Default');

    IF v_total > 24 THEN
      RAISE_APPLICATION_ERROR(-20003, 'Cannot enter more than 24 hours in a day.');
    END IF;

    -- RULE-008: a day wholly taken by leave carries no worked hours.
    --
    -- Without this the grid happily held 8h of work beside 8h of leave on the
    -- same date -- 16 hours against a standard of 8 -- and the manager approved
    -- hours for a day the person was provably absent in HCM. The 24-hour rule
    -- above does not catch it: 16 is under 24.
    --
    -- FULL day only. A half-day absence leaves the rest genuinely workable, and
    -- refusing it would send someone to their manager to record hours they did
    -- work. Zero standard hours is a weekend or holiday, where there is no
    -- standard to reach, so any leave takes the day.
    IF v_leave > 0 AND v_work > 0
       AND (v_std <= 0 OR v_leave >= v_std) THEN
      RAISE_APPLICATION_ERROR(-20002,
        'This day is full-day leave from HR Absence, so no hours can be booked '
        || 'against it. If the leave is wrong, correct it in Absence '
        || 'Management and the timesheet will follow.');
    END IF;
  END validate_day;


  -- RULE-004 / RULE-007. A week is editable when its period is open, the
  -- delivery cut-off has not passed, the week is not in the future, and the
  -- week is not locked by defaulting.
  PROCEDURE assert_editable(p_ts_week_id IN NUMBER) IS
    v_ws       DATE;
    v_status   oc_ts_week.week_status%TYPE;
    v_locked   oc_ts_week.locked_flag%TYPE;
    v_pstatus  oc_time_period.status%TYPE;
    v_delivery oc_time_period.delivery_cutoff%TYPE;
    v_reopen   NUMBER;
  BEGIN
    SELECT w.week_start, w.week_status, w.locked_flag, p.status, p.delivery_cutoff
      INTO v_ws, v_status, v_locked, v_pstatus, v_delivery
      FROM oc_ts_week w
      JOIN oc_time_period p ON p.period_id = w.period_id
     WHERE w.ts_week_id = p_ts_week_id;

    -- RULE-004: future weeks are visible but frozen (SC-02). Checked before the
    -- salary-hold reopen below, because a hold can never justify filling in a
    -- week that has not happened.
    IF v_ws > week_start_of(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(-20004, 'Future weeks cannot be filled.');
    END IF;

    -- SALARY-HOLD REOPEN (PROC-007, functional owner 10-Aug-2026): the employee
    -- "will see the defaulted week timesheet after the payroll cutoff is over
    -- and will be able to resubmit it".
    --
    -- Every gate below this point would otherwise refuse exactly that week, and
    -- for good reasons in the normal case: it is locked because defaulting
    -- locked it, and the delivery cut-off has long passed. But a salary hold
    -- exists precisely to give this person a bounded second chance, and a
    -- correction window they cannot type into is not a correction window.
    --
    -- Deliberately narrow, so this is a keyhole and not a hole:
    --   * only a week with a HELD or REJECTED hold day against it
    --   * only inside the 60 calendar days (CFG-012) -- the same expiry the
    --     screen and the correction procedure read, so all three agree
    --   * the week must still be the employee's to change; Approved,
    --     Overridden and Closed are checked below and are NOT reopened
    --
    -- EXISTS is SQL-only (PLS-00204), hence the SELECT INTO.
    SELECT CASE WHEN EXISTS (
             SELECT 1
               FROM oc_ts_salary_hold_day d
               JOIN oc_ts_salary_hold     h ON h.hold_id = d.hold_id
              WHERE d.ts_week_id  = p_ts_week_id
                AND d.day_status IN ('Held','Rejected')
                AND h.salary_status = 'Held'
                AND (h.window_expires_on IS NULL
                     OR TRUNC(SYSDATE) <= h.window_expires_on))
           THEN 1 ELSE 0 END
      INTO v_reopen FROM dual;

    IF v_reopen = 1 THEN
      -- Still refuse the three states that are somebody else's decision. A
      -- hold reopens an UNSUBMITTED week; it does not undo an approval.
      IF v_status IN ('Approved','Overridden and approved','Closed') THEN
        RAISE_APPLICATION_ERROR(-20007,
          'This week has already been approved and cannot be changed, even '
          || 'though pay is held. Ask your manager to send it back.');
      END IF;
      RETURN;
    END IF;

    IF v_locked = 'Y' THEN
      RAISE_APPLICATION_ERROR(-20007,
        'This week is locked. Only a manager can edit a defaulted timesheet.');
    END IF;

    IF v_status IN ('Approved','Overridden and approved','Closed') THEN
      RAISE_APPLICATION_ERROR(-20007, 'This week can no longer be edited.');
    END IF;

    IF v_pstatus <> 'Open'
       OR (v_delivery IS NOT NULL AND TRUNC(SYSDATE) > v_delivery) THEN
      RAISE_APPLICATION_ERROR(-20007, 'This week can no longer be edited.');
    END IF;
  END assert_editable;


  -- RULE-015: a manager's own time is approved by their reporting manager.
  PROCEDURE assert_not_self(p_employee_id IN VARCHAR2, p_actor_emp_id IN VARCHAR2) IS
  BEGIN
    IF p_actor_emp_id IS NOT NULL AND p_employee_id = p_actor_emp_id THEN
      RAISE_APPLICATION_ERROR(-20015,
        'A manager''s own time is approved by their reporting manager.');
    END IF;
  END assert_not_self;


  -- RULE-001: warning only — returned so the UI can surface it.
  FUNCTION allocation_pct(p_employee_id IN VARCHAR2) RETURN NUMBER IS
    v_pct NUMBER;
  BEGIN
    SELECT NVL(SUM(alloc_pct),0) INTO v_pct
      FROM oc_time_allocation
     WHERE employee_id = p_employee_id AND status = 'Active';
    RETURN v_pct;
  END allocation_pct;


  -- ═══════════════════════════════════════════════════════════
  -- Population (PROC-001)
  -- ═══════════════════════════════════════════════════════════

  -- Runs 1-2 days before the next period opens. For every active allocation it
  -- creates the weeks and pre-populates one Default-shaped 'Actual' row per
  -- working day at the resolved standard hours x allocation %.
  -- Idempotent: an existing entry for the cell is left untouched, so re-running
  -- never overwrites employee input.
  FUNCTION populate_month(
    p_period_id   IN NUMBER,
    p_employee_id IN VARCHAR2 DEFAULT NULL,
    p_actor       IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER
  IS
    v_job      NUMBER;
    v_read     NUMBER := 0;
    v_upserted NUMBER := 0;
    v_failed   NUMBER := 0;
    v_start    DATE;
    v_end      DATE;
    v_week     NUMBER;
    v_shift    VARCHAR2(20);
    v_std      NUMBER;
    v_working  VARCHAR2(1);
    v_holiday  VARCHAR2(200);
    v_hours    NUMBER;
    v_task     NUMBER;
  BEGIN
    v_job := start_job('Monthly Population', 'MonthlyPopulation',
                       p_period_id, NULL, p_employee_id, p_actor);

    SELECT start_date, end_date INTO v_start, v_end
      FROM oc_time_period WHERE period_id = p_period_id;

    FOR a IN (SELECT al.allocation_id, al.employee_id, al.project_id, al.alloc_pct,
                     w.worker_type
                FROM oc_time_allocation al
                JOIN oc_time_worker     w ON w.employee_id = al.employee_id
               WHERE al.status = 'Active'
                 AND w.status  = 'Active'
                 AND al.start_date <= v_end
                 AND (al.end_date IS NULL OR al.end_date >= v_start)
                 AND (p_employee_id IS NULL OR al.employee_id = p_employee_id))
    LOOP
      v_read := v_read + 1;
      BEGIN
        -- The default task is the project's first chargeable WBS task. Without
        -- one there is nothing to charge to, which is a failed record rather
        -- than a hard stop (PROC-001 exception paths).
        BEGIN
          SELECT task_id INTO v_task
            FROM (SELECT task_id FROM oc_time_task
                   WHERE project_id = a.project_id
                     AND task_type  = 'WBS'
                     AND status     = 'Active'
                     -- Same pair as the LOV. Seeding a line onto a task the
                     -- employee cannot then select in the picker would be a
                     -- grid they can see and not change.
                     AND chargeable_flag = 'Y'
                     AND billable_type   = 'Billable'
                   -- task_code, not task_id. SORT_ORDER is never populated - the
                   -- extract does not carry it and the sync does not set it - so
                   -- every task sits at the default 100 and the tie-break decided
                   -- the answer. task_id is the local identity column, so "the
                   -- first chargeable task" actually meant "whichever row the
                   -- sync happened to insert first". On project 444 that was
                   -- Leave; on another project it was Development. Ordering by
                   -- the WBS number makes it the first task in the BREAKDOWN,
                   -- and matches how V_OC_TS_TASK_LOV already orders.
                   ORDER BY sort_order, task_code, task_id)
           WHERE ROWNUM = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          fail_record(v_job, 'ALLOCATION',
                      'proj=' || a.project_id || ';emp=' || a.employee_id,
                      a.employee_id,
                      'Project has no chargeable WBS task to pre-populate against.',
                      'NO_WBS_TASK');
          v_failed := v_failed + 1;
          CONTINUE;
        END;

        FOR d IN 0 .. (v_end - v_start) LOOP
          DECLARE
            v_date DATE := v_start + d;
          BEGIN
            resolve_day(a.employee_id, a.project_id, v_date,
                        v_shift, v_std, v_working, v_holiday);

            -- RULE-012: weekends and holidays default to 0 and are not seeded.
            IF v_working = 'N' THEN CONTINUE; END IF;

            -- Allocation % apportions the day, rounded to 15-minute blocks so
            -- CHK_OC_TSE_QUARTER (RULE-005) always holds.
            v_hours := ROUND(NVL(v_std,0) * NVL(a.alloc_pct,100) / 100 * 4) / 4;
            IF v_hours <= 0 THEN CONTINUE; END IF;

            v_week := ensure_week(a.employee_id, v_date, p_actor);

            INSERT INTO oc_ts_entry (
              ts_week_id, project_id, task_id, entry_date, hours, entry_type,
              shift_code, standard_hours, source, created_by)
            SELECT v_week, a.project_id, v_task, v_date, v_hours, 'Actual',
                   v_shift, v_std, 'Prepopulated', p_actor
              FROM dual
             WHERE NOT EXISTS (SELECT 1 FROM oc_ts_entry e
                                WHERE e.ts_week_id = v_week
                                  AND e.project_id = a.project_id
                                  AND e.task_id    = v_task
                                  AND e.entry_date = v_date
                                  AND e.entry_type = 'Actual');
            v_upserted := v_upserted + SQL%ROWCOUNT;
          END;
        END LOOP;

      EXCEPTION WHEN OTHERS THEN
        fail_record(v_job, 'ALLOCATION',
                    'alloc=' || a.allocation_id, a.employee_id, SQLERRM);
        v_failed := v_failed + 1;
      END;
    END LOOP;

    -- RULE-008: leave rows come from Absence, never from employee selection.
    -- Seeded as non-billable 'Leave' common-task rows with IS_LEAVE = 'Y'.
    BEGIN
      SELECT task_id INTO v_task
        FROM oc_time_task
       WHERE task_type = 'COMMON' AND UPPER(task_code) = 'LEAVE';

      FOR ab IN (SELECT ab.employee_id, ab.absence_date, ab.absence_hours,
                        ab.absence_type,
                        (SELECT MIN(al.project_id) FROM oc_time_allocation al
                          WHERE al.employee_id = ab.employee_id
                            AND al.status = 'Active') AS project_id
                   FROM oc_time_absence ab
                  WHERE ab.absence_date BETWEEN v_start AND v_end
                    AND ab.approval_status = 'Approved'
                    AND (p_employee_id IS NULL OR ab.employee_id = p_employee_id))
      LOOP
        IF ab.project_id IS NULL THEN CONTINUE; END IF;
        v_week := ensure_week(ab.employee_id, ab.absence_date, p_actor);

        MERGE INTO oc_ts_entry e
        USING (SELECT v_week AS ts_week_id, ab.project_id AS project_id,
                      v_task AS task_id, ab.absence_date AS entry_date FROM dual) s
           ON (e.ts_week_id = s.ts_week_id AND e.project_id = s.project_id
           AND e.task_id    = s.task_id    AND e.entry_date = s.entry_date
           AND e.entry_type = 'Actual')
         WHEN MATCHED THEN UPDATE
              SET e.hours = ab.absence_hours, e.is_leave = 'Y',
                  e.absence_type = ab.absence_type, e.updated_by = p_actor
         WHEN NOT MATCHED THEN
              INSERT (ts_week_id, project_id, task_id, entry_date, hours,
                      entry_type, is_leave, absence_type, source, created_by)
              VALUES (v_week, ab.project_id, v_task, ab.absence_date,
                      ab.absence_hours, 'Actual', 'Y', ab.absence_type,
                      'Prepopulated', p_actor);
        v_upserted := v_upserted + 1;

        -- RULE-008: a full day of leave takes the whole day, so the work this
        -- job seeded from the allocation has to come back off.
        --
        -- The allocation loop above runs FIRST and knows nothing about absence,
        -- so it has already written a standard day against every active
        -- project. Left alone that produced 8h of work beside 8h of leave on
        -- the same date -- observed on RI2824, 07-Aug-2026, a 16-hour Friday
        -- against a standard of 8 -- and validate_day would then refuse every
        -- later save on that day, making it unsavable rather than merely wrong.
        --
        -- Only rows this job created ('Prepopulated') are touched. Hours the
        -- employee or a manager typed are theirs; if they conflict with a new
        -- absence that is a correction for a person to make, not for a
        -- scheduled job to silently erase.
        UPDATE oc_ts_entry e
           SET e.hours = 0, e.updated_by = p_actor
         WHERE e.ts_week_id = v_week
           AND e.entry_date = ab.absence_date
           AND e.is_leave   = 'N'
           AND e.entry_type IN ('Actual','Default')
           AND e.source     = 'Prepopulated'
           AND e.hours      > 0
           AND ab.absence_hours >= NVL((SELECT MAX(s.standard_hours)
                                          FROM oc_ts_entry s
                                         WHERE s.ts_week_id = v_week
                                           AND s.entry_date = ab.absence_date), 0);
      END LOOP;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      fail_record(v_job, 'TASK', 'COMMON/LEAVE', NULL,
                  'Common task LEAVE is not seeded; absence rows were skipped.',
                  'NO_LEAVE_TASK');
      v_failed := v_failed + 1;
    END;

    finish_job(v_job, v_read, v_upserted, v_failed);
    COMMIT;
    RETURN v_job;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    -- SQLERRM is a PL/SQL function and cannot be referenced inside a SQL
    -- statement (ORA-00904). Capture it into a local first, then write that.
    DECLARE
      v_err VARCHAR2(2000) := SUBSTR(SQLERRM, 1, 2000);
    BEGIN
      UPDATE oc_time_sync_job
         SET job_status = 'Failed', finished_on = SYSTIMESTAMP,
             message = v_err
       WHERE job_run_id = v_job;
    END;
    COMMIT;
    RAISE;
  END populate_month;


  -- PROC-001 daily process: allocation change, new hire, exit, termination
  -- reversal, deputation, transfer, shift update. Re-runs population for the
  -- affected employees only, for the open period from the action date forward.
  FUNCTION populate_daily(
    p_action_date IN DATE,
    p_scope_key   IN VARCHAR2 DEFAULT NULL,
    p_actor       IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER
  IS
    v_job    NUMBER;
    v_period NUMBER;
    v_read   NUMBER := 0;
    v_up     NUMBER := 0;
    v_failed NUMBER := 0;
  BEGIN
    -- The period the action date falls in, not "the open period". With several
    -- months open at once the latter is a guess, and this job already knows the
    -- exact date it is processing (RA-003).
    v_period := get_period_for_date(p_action_date);
    v_job := start_job('Daily Action-date Process', 'DailyActionDate',
                       v_period, TRUNC(p_action_date), p_scope_key, p_actor);

    FOR w IN (SELECT DISTINCT al.employee_id
                FROM oc_time_allocation al
                JOIN oc_time_worker     wk ON wk.employee_id = al.employee_id
               WHERE al.status = 'Active'
                 AND (p_scope_key IS NULL
                      OR NVL(wk.deputed_country, wk.base_country) = p_scope_key)
                 AND (TRUNC(al.updated_on) = TRUNC(p_action_date)
                   OR TRUNC(al.created_on) = TRUNC(p_action_date)
                   OR TRUNC(wk.updated_on) = TRUNC(p_action_date)
                   OR TRUNC(wk.created_on) = TRUNC(p_action_date)))
    LOOP
      v_read := v_read + 1;
      BEGIN
        -- Reuse the monthly logic for one employee; it is idempotent.
        v_up := v_up + 1;
        DECLARE v_child NUMBER; BEGIN
          v_child := populate_month(v_period, w.employee_id, p_actor);
        END;
      EXCEPTION WHEN OTHERS THEN
        fail_record(v_job, 'WORKER', w.employee_id, w.employee_id, SQLERRM);
        v_failed := v_failed + 1;
      END;
    END LOOP;

    finish_job(v_job, v_read, v_up, v_failed);
    COMMIT;
    RETURN v_job;
  END populate_daily;


  -- ═══════════════════════════════════════════════════════════
  -- Employee entry (PROC-002)
  -- ═══════════════════════════════════════════════════════════

  PROCEDURE save_entry(
    p_ts_week_id     IN NUMBER,
    p_project_id     IN NUMBER,
    p_task_id        IN NUMBER,
    p_entry_date     IN DATE,
    p_hours          IN NUMBER,
    p_source         IN VARCHAR2 DEFAULT 'Employee',
    p_unbilled_reason IN VARCHAR2 DEFAULT NULL,
    p_actor          IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
    v_emp     oc_ts_week.employee_id%TYPE;
    v_ok      NUMBER;
    v_shift   VARCHAR2(20);
    v_std     NUMBER;
    v_working VARCHAR2(1);
    v_holiday VARCHAR2(200);
  BEGIN
    -- A manager editing a locked defaulted sheet is legitimate (ACT-025), so
    -- the editability gate is skipped for manager-sourced writes.
    IF p_source = 'Employee' THEN
      assert_editable(p_ts_week_id);
    END IF;

    SELECT employee_id INTO v_emp FROM oc_ts_week WHERE ts_week_id = p_ts_week_id;

    -- RULE-010: the task must belong to this project's WBS or be a common task.
    SELECT COUNT(*) INTO v_ok
      FROM oc_time_task t
     WHERE t.task_id = p_task_id
       AND t.status  = 'Active'
       AND (t.project_id = p_project_id OR t.task_type = 'COMMON');
    IF v_ok = 0 THEN
      RAISE_APPLICATION_ERROR(-20010, 'Select a valid task.');
    END IF;

    -- RULE-008: Leave is never employee-selectable.
    SELECT COUNT(*) INTO v_ok
      FROM oc_time_task
     WHERE task_id = p_task_id AND selectable_flag = 'N';
    IF v_ok > 0 AND p_source = 'Employee' THEN
      RAISE_APPLICATION_ERROR(-20010,
        'Leave and Billing Loss are system-maintained and cannot be selected.');
    END IF;

    resolve_day(v_emp, p_project_id, p_entry_date,
                v_shift, v_std, v_working, v_holiday);

    MERGE INTO oc_ts_entry e
    USING (SELECT p_ts_week_id AS ts_week_id, p_project_id AS project_id,
                  p_task_id AS task_id, TRUNC(p_entry_date) AS entry_date
             FROM dual) s
       ON (e.ts_week_id = s.ts_week_id AND e.project_id = s.project_id
       AND e.task_id    = s.task_id    AND e.entry_date = s.entry_date
       AND e.entry_type = 'Actual')
     WHEN MATCHED THEN UPDATE
          SET e.hours           = p_hours,
              e.unbilled_reason = NVL(p_unbilled_reason, e.unbilled_reason),
              e.shift_code      = v_shift,
              e.standard_hours  = v_std,
              e.source          = p_source,
              e.updated_by      = p_actor
     WHEN NOT MATCHED THEN
          INSERT (ts_week_id, project_id, task_id, entry_date, hours, entry_type,
                  unbilled_reason, shift_code, standard_hours, source, created_by)
          VALUES (p_ts_week_id, p_project_id, p_task_id, TRUNC(p_entry_date),
                  p_hours, 'Actual', p_unbilled_reason, v_shift, v_std,
                  p_source, p_actor);

    -- RULE-003 is a cross-line rule, so it is checked after the write.
    validate_day(p_ts_week_id, p_entry_date);
  END save_entry;


  PROCEDURE remove_line(
    p_ts_week_id IN NUMBER,
    p_project_id IN NUMBER,
    p_task_id    IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
  BEGIN
    assert_editable(p_ts_week_id);

    -- Never remove an HR-sourced leave row; it is not the employee's to delete.
    DELETE FROM oc_ts_entry
     WHERE ts_week_id = p_ts_week_id
       AND project_id = p_project_id
       AND task_id    = p_task_id
       AND entry_type = 'Actual'
       AND is_leave   = 'N';
  END remove_line;


  PROCEDURE submit_week(
    p_ts_week_id IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id   IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp      oc_ts_week.employee_id%TYPE;
    v_period   oc_ts_week.period_id%TYPE;
    v_status   oc_ts_week.week_status%TYPE;
    v_ws       DATE;
    v_we       DATE;
    v_type     oc_time_worker.worker_type%TYPE;
    v_cutday   oc_time_period.ts_cutoff_day%TYPE;
    v_cuttime  oc_time_period.ts_cutoff_time%TYPE;
    v_late     VARCHAR2(1) := 'N';
    v_corr     VARCHAR2(1) := 'N';
    v_unbilled NUMBER;
    v_missing  NUMBER;
    v_new      oc_ts_week.week_status%TYPE;
  BEGIN
    assert_editable(p_ts_week_id);

    SELECT w.employee_id, w.period_id, w.week_status, w.week_start, w.week_end,
           wk.worker_type, p.ts_cutoff_day, p.ts_cutoff_time
      INTO v_emp, v_period, v_status, v_ws, v_we, v_type, v_cutday, v_cuttime
      FROM oc_ts_week      w
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
      JOIN oc_time_period  p  ON p.period_id    = w.period_id
     WHERE w.ts_week_id = p_ts_week_id;

    -- RULE-002: every non-billable hour must carry an unbilled reason. The
    -- table CHECK covers a single row; this catches the whole week at submit.
    SELECT COUNT(*) INTO v_missing
      FROM oc_ts_entry
     WHERE ts_week_id      = p_ts_week_id
       AND billable_type   = 'Non-billable'
       AND hours          <> 0
       AND unbilled_reason IS NULL;
    IF v_missing > 0 THEN
      RAISE_APPLICATION_ERROR(-20013,
        'An unbilled reason is required for non-billable hours.');
    END IF;

    -- RULE-003 across every day of the week.
    FOR d IN (SELECT DISTINCT entry_date FROM oc_ts_entry
               WHERE ts_week_id = p_ts_week_id) LOOP
      validate_day(p_ts_week_id, d.entry_date);
    END LOOP;

    -- RULE-007: after the weekly cut-off a submission is accepted but flagged
    -- Late submission. The cut-off is <weekday time> AFTER the week end, in the
    -- base location's local time (the job runs per country, CFG-010).
    IF v_cutday IS NOT NULL THEN
      IF SYSDATE > NEXT_DAY(v_we, v_cutday)
                 + NVL(TO_NUMBER(SUBSTR(v_cuttime,1,2)),17)/24 THEN
        v_late := 'Y';
      END IF;
    END IF;

    -- A resubmission after rejection carries the Correction flag (SC-16).
    IF v_status = 'Rejected' THEN v_corr := 'Y'; END IF;

    -- RULE-021: a contractor logging non-billable time needs an exception
    -- approval, surfaced to the manager through this flag (NOTIF-007).
    v_unbilled := 0;
    IF v_type = 'Contractor' THEN
      SELECT NVL(SUM(hours),0) INTO v_unbilled
        FROM oc_ts_entry
       WHERE ts_week_id    = p_ts_week_id
         AND billable_type = 'Non-billable'
         AND is_leave      = 'N';
    END IF;

    -- A submission is ALWAYS 'Submitted' (revised 30-Jul-2026). Landing after the
    -- weekly cut-off no longer changes the status — it raises the Late submission
    -- FLAG instead. 'Defaulted' is now produced only by the defaulting jobs.
    UPDATE oc_ts_week
       SET week_status          = 'Submitted',
           submitted_by         = p_actor,
           submitted_on         = SYSTIMESTAMP,
           late_submission_flag = GREATEST(late_submission_flag, v_late),
           reject_reason        = NULL,
           reject_remarks       = NULL,
           updated_by           = p_actor
     WHERE ts_week_id = p_ts_week_id;

    -- Every day goes back to Pending for the manager to act on.
    UPDATE oc_ts_entry
       SET day_status     = 'Pending',
           reject_reason  = NULL,
           reject_remarks = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    -- SALARY HOLD: resubmitting the week IS the correction (PROC-007). The
    -- functional owner described the employee screen as seeing "the defaulted
    -- week timesheet after the payroll cutoff is over" and being "able to
    -- resubmit it" -- so the correction is the timesheet itself, not a second
    -- form beside it. Marking the held dates here means the employee corrects
    -- in one place and the manager approves in one place, instead of the same
    -- hours being entered twice and the two copies disagreeing.
    --
    -- corrected_hours is the day's actual submitted total, which is what
    -- CHK_OC_TSSHD_CORR requires and what payroll needs to see.
    UPDATE oc_ts_salary_hold_day d
       SET d.day_status        = 'Corrected',
           d.corrected_hours   = NVL((SELECT SUM(e.hours) FROM oc_ts_entry e
                                       WHERE e.ts_week_id = p_ts_week_id
                                         AND e.entry_date = d.work_date
                                         AND e.entry_type IN ('Actual','Default')), 0),
           d.correction_reason = NVL(d.correction_reason,
                                     'Week resubmitted by the employee.'),
           d.corrected_by      = p_actor,
           d.corrected_on      = SYSTIMESTAMP,
           d.reject_remarks    = NULL,
           d.updated_by        = p_actor,
           d.updated_on        = SYSTIMESTAMP
     WHERE d.ts_week_id  = p_ts_week_id
       AND d.day_status IN ('Held','Rejected');

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'WEEK', NULL,
              CASE WHEN v_corr = 'Y' THEN 'Resubmit' ELSE 'Submit' END,
              NULL, NULL, v_emp, p_trace_id);
  END submit_week;


  PROCEDURE revoke_week(
    p_ts_week_id IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id   IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp     oc_ts_week.employee_id%TYPE;
    v_period  oc_ts_week.period_id%TYPE;
    v_status  oc_ts_week.week_status%TYPE;
    v_pstatus oc_time_period.status%TYPE;
  BEGIN
    SELECT w.employee_id, w.period_id, w.week_status, p.status
      INTO v_emp, v_period, v_status, v_pstatus
      FROM oc_ts_week     w
      JOIN oc_time_period p ON p.period_id = w.period_id
     WHERE w.ts_week_id = p_ts_week_id;

    -- Only a week that is still waiting on the manager. Approved, Overridden
    -- and approved, and Closed are all decisions somebody else has taken, and
    -- Defaulted is the cut-off job's — reversing any of those is a manager
    -- send-back, not a revoke.
    IF v_status <> 'Submitted' THEN
      RAISE_APPLICATION_ERROR(-20021,
        'Only a submitted week can be revoked. This week is ' || v_status ||
        '. Ask your manager to send it back.');
    END IF;

    -- assert_editable is deliberately NOT used: it refuses a Submitted week,
    -- which is precisely the state being undone here. The period gate still
    -- applies — a closed month is corrected by a retro adjustment (RULE-019),
    -- never by reopening a week inside it.
    IF v_pstatus <> 'Open' THEN
      RAISE_APPLICATION_ERROR(-20022,
        'The period is not open, so this week cannot be revoked. Raise a '
        || 'backdated adjustment instead.');
    END IF;

    UPDATE oc_ts_week
       SET week_status  = 'Not yet submitted',
           submitted_by = NULL,
           submitted_on = NULL,
           updated_by   = p_actor
     WHERE ts_week_id = p_ts_week_id;

    -- Days stay 'Pending'. There is NO draft day status: CHK_OC_TSE_DSTAT
    -- allows only Pending/Approved/Rejected, and DAY_STATUS defaults to
    -- 'Pending' from the moment population creates the row. Submitted-ness
    -- lives on the WEEK, not the day — which is the whole reason revoking only
    -- has to move week_status. Setting it explicitly anyway so a day left
    -- Rejected by an earlier round is cleared along with its reason.
    --
    -- late_submission_flag is deliberately LEFT SET — the week did land after
    -- the cut-off, and revoking it does not un-happen that.
    UPDATE oc_ts_entry
       SET day_status     = 'Pending',
           reject_reason  = NULL,
           reject_remarks = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'WEEK', NULL,
              'Revoke', NULL, NULL, v_emp, p_trace_id);
  END revoke_week;


  -- RULE-006: at the weekly cut-off an unsubmitted week is auto-submitted with
  -- default hours, marked Defaulted and locked. Only Defaulted stops salary
  -- later (RULE-016).
  FUNCTION run_weekly_defaulting(
    p_period_id IN NUMBER,
    p_as_of     IN DATE     DEFAULT SYSDATE,
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER
  IS
    v_job   NUMBER;
    v_read  NUMBER := 0;
    v_up    NUMBER := 0;
    v_fail  NUMBER := 0;
    v_cutday  oc_time_period.ts_cutoff_day%TYPE;
    v_cuttime oc_time_period.ts_cutoff_time%TYPE;
  BEGIN
    v_job := start_job('Weekly Defaulting', 'WeeklyDefaulting',
                       p_period_id, TRUNC(p_as_of), NULL, p_actor);

    SELECT ts_cutoff_day, ts_cutoff_time INTO v_cutday, v_cuttime
      FROM oc_time_period WHERE period_id = p_period_id;

    FOR w IN (SELECT ts_week_id, employee_id, week_end
                FROM oc_ts_week
               WHERE period_id   = p_period_id
                 AND week_status = 'Not yet submitted'
                 AND week_end    < TRUNC(p_as_of))
    LOOP
      v_read := v_read + 1;
      BEGIN
        -- Only default once the cut-off for that week has actually passed.
        IF v_cutday IS NOT NULL
           AND p_as_of <= NEXT_DAY(w.week_end, v_cutday)
                        + NVL(TO_NUMBER(SUBSTR(v_cuttime,1,2)),17)/24 THEN
          CONTINUE;
        END IF;

        -- The pre-populated rows ARE the default hours; retag them so the
        -- accrual hand-off can tell Actual from Default (INT-014 ENTRY_TYPE).
        UPDATE oc_ts_entry
           SET entry_type = 'Default', source = 'Job', updated_by = p_actor
         WHERE ts_week_id = w.ts_week_id
           AND entry_type = 'Actual'
           AND source     = 'Prepopulated';

        UPDATE oc_ts_week
           SET week_status     = 'Defaulted',
               defaulted_flag  = 'Y',
               -- The employee missed their own cut-off, so this is the default
               -- that holds pay (RULE-016) and locks the week — only a manager
               -- can edit it now.
               defaulted_by    = 'EMPLOYEE',
               locked_flag     = 'Y',
               submitted_by    = p_actor,
               submitted_on    = SYSTIMESTAMP,
               updated_by      = p_actor
         WHERE ts_week_id = w.ts_week_id;

        log_event(w.ts_week_id, w.employee_id, NULL, p_period_id, 'WEEK', NULL,
                  'Default', NULL, 'Auto-submitted at weekly cut-off',
                  w.employee_id, NULL);
        v_up := v_up + 1;
      EXCEPTION WHEN OTHERS THEN
        fail_record(v_job, 'TS_WEEK', TO_CHAR(w.ts_week_id), w.employee_id, SQLERRM);
        v_fail := v_fail + 1;
      END;
    END LOOP;

    finish_job(v_job, v_read, v_up, v_fail);
    COMMIT;
    RETURN v_job;
  END run_weekly_defaulting;


  -- The delivery cut-off: the MANAGER never decided on a submitted week.
  --
  -- Three deliberate differences from weekly defaulting, all from
  -- TIMESHEET_FLOW.html §01:
  --
  --   * DEFAULTED_BY is 'MANAGER', and run_salary_stopping ignores those. The
  --     employee did their part; holding their pay because their manager was
  --     slow would invert RULE-016, whose whole point is that "awaiting
  --     approval does not stop salary".
  --   * The week is NOT locked. The manager is late, not barred — they can
  --     still approve it, and the flow expects exactly that ("manager approves
  --     late" -> Approved).
  --   * Only 'Submitted' weeks are touched. A week that was never submitted is
  --     the employee's default, already handled by the weekly job, and must not
  --     be reclassified as the manager's.
  FUNCTION run_delivery_defaulting(
    p_period_id IN NUMBER,
    p_as_of     IN DATE     DEFAULT SYSDATE,
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER
  IS
    v_job     NUMBER;
    v_read    NUMBER := 0;
    v_up      NUMBER := 0;
    v_fail    NUMBER := 0;
    v_cutoff  DATE;
  BEGIN
    v_job := start_job('Delivery Defaulting', 'DeliveryDefaulting',
                       p_period_id, TRUNC(p_as_of), NULL, p_actor);

    SELECT delivery_cutoff INTO v_cutoff
      FROM oc_time_period WHERE period_id = p_period_id;

    -- No delivery cut-off configured means there is nothing to miss. Finish the
    -- job cleanly rather than defaulting every open week against a null date.
    IF v_cutoff IS NULL OR TRUNC(p_as_of) <= v_cutoff THEN
      finish_job(v_job, 0, 0, 0);
      COMMIT;
      RETURN v_job;
    END IF;

    FOR w IN (SELECT ts_week_id, employee_id
                FROM oc_ts_week
               WHERE period_id   = p_period_id
                 AND week_status = 'Submitted')
    LOOP
      v_read := v_read + 1;
      BEGIN
        UPDATE oc_ts_week
           SET week_status    = 'Defaulted',
               defaulted_flag = 'Y',
               defaulted_by   = 'MANAGER',
               updated_by     = p_actor,
               updated_on     = SYSTIMESTAMP
         WHERE ts_week_id = w.ts_week_id;

        log_event(w.ts_week_id, w.employee_id, NULL, p_period_id, 'WEEK', NULL,
                  'Default', NULL,
                  'Delivery cut-off passed with no manager decision',
                  w.employee_id, NULL);
        v_up := v_up + 1;
      EXCEPTION WHEN OTHERS THEN
        fail_record(v_job, 'TS_WEEK', TO_CHAR(w.ts_week_id), w.employee_id, SQLERRM);
        v_fail := v_fail + 1;
      END;
    END LOOP;

    finish_job(v_job, v_read, v_up, v_fail);
    COMMIT;
    RETURN v_job;
  END run_delivery_defaulting;


  -- ═══════════════════════════════════════════════════════════
  -- Manager approval
  -- ═══════════════════════════════════════════════════════════

  PROCEDURE approve_week(
    p_ts_week_id   IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp    oc_ts_week.employee_id%TYPE;
    v_period oc_ts_week.period_id%TYPE;
    v_over   oc_ts_week.overridden_flag%TYPE;
  BEGIN
    SELECT employee_id, period_id, overridden_flag
      INTO v_emp, v_period, v_over
      FROM oc_ts_week WHERE ts_week_id = p_ts_week_id;

    assert_not_self(v_emp, p_actor_emp_id);

    -- ACT-014: approving the week marks every working day approved.
    UPDATE oc_ts_entry
       SET day_status  = 'Approved',
           approved_by = p_actor,
           approved_on = SYSTIMESTAMP,
           updated_by  = p_actor
     WHERE ts_week_id = p_ts_week_id
       AND day_status <> 'Approved';

    UPDATE oc_ts_week
       SET week_status = CASE WHEN v_over = 'Y'
                              THEN 'Overridden and approved' ELSE 'Approved' END,
           approved_by = p_actor,
           approved_on = SYSTIMESTAMP,
           updated_by  = p_actor
     WHERE ts_week_id = p_ts_week_id;

    -- SALARY HOLD: approving the resubmitted week approves its held dates, and
    -- if that was the last one the hold releases here rather than waiting for
    -- the nightly job. This is somebody's pay -- "it will clear tonight" is not
    -- good enough, and the manager has just done the only thing that was
    -- outstanding.
    UPDATE oc_ts_salary_hold_day
       SET day_status  = 'Approved',
           approved_by = p_actor_emp_id,
           approved_on = SYSTIMESTAMP,
           updated_by  = p_actor,
           updated_on  = SYSTIMESTAMP
     WHERE ts_week_id  = p_ts_week_id
       AND day_status  = 'Corrected';

    UPDATE oc_ts_salary_hold h
       SET h.salary_status = 'Released',
           h.released_by   = p_actor_emp_id,
           h.released_on   = SYSTIMESTAMP,
           h.remarks       = 'Released: every held date resubmitted and approved.'
     WHERE h.salary_status = 'Held'
       AND EXISTS (SELECT 1 FROM oc_ts_salary_hold_day d
                    WHERE d.hold_id = h.hold_id
                      AND d.ts_week_id = p_ts_week_id)
       AND NOT EXISTS (SELECT 1 FROM oc_ts_salary_hold_day d
                        WHERE d.hold_id = h.hold_id
                          AND d.day_status <> 'Approved');

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'WEEK', NULL,
              'Approve', NULL, NULL, p_actor_emp_id, p_trace_id);
  END approve_week;


  PROCEDURE reject_week(
    p_ts_week_id   IN NUMBER,
    p_reason       IN VARCHAR2,
    p_remarks      IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp    oc_ts_week.employee_id%TYPE;
    v_period oc_ts_week.period_id%TYPE;
  BEGIN
    -- RULE-013: reason is mandatory and constrained to the BRD LOV.
    IF p_reason IS NULL OR p_reason NOT IN ('Manager','Client','Absence') THEN
      RAISE_APPLICATION_ERROR(-20013, 'Select a rejection reason.');
    END IF;

    SELECT employee_id, period_id INTO v_emp, v_period
      FROM oc_ts_week WHERE ts_week_id = p_ts_week_id;

    assert_not_self(v_emp, p_actor_emp_id);

    UPDATE oc_ts_entry
       SET day_status     = 'Rejected',
           reject_reason  = p_reason,
           reject_remarks = p_remarks,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    -- Back with the employee: unlock so they can correct and resubmit
    -- (PROC-005 / RULE-007).
    UPDATE oc_ts_week
       SET week_status    = 'Rejected',
           reject_reason  = p_reason,
           reject_remarks = p_remarks,
           locked_flag    = 'N',
           approved_by    = NULL,
           approved_on    = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'WEEK', NULL,
              'Reject', p_reason, p_remarks, p_actor_emp_id, p_trace_id);
  END reject_week;


  -- ACT-017: date-wise approval. The week closes automatically once every day
  -- is approved.
  PROCEDURE approve_day(
    p_ts_week_id   IN NUMBER,
    p_entry_date   IN DATE,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp     oc_ts_week.employee_id%TYPE;
    v_period  oc_ts_week.period_id%TYPE;
    v_over    oc_ts_week.overridden_flag%TYPE;
    v_pending NUMBER;
  BEGIN
    SELECT employee_id, period_id, overridden_flag
      INTO v_emp, v_period, v_over
      FROM oc_ts_week WHERE ts_week_id = p_ts_week_id;

    assert_not_self(v_emp, p_actor_emp_id);

    UPDATE oc_ts_entry
       SET day_status  = 'Approved',
           approved_by = p_actor,
           approved_on = SYSTIMESTAMP,
           updated_by  = p_actor
     WHERE ts_week_id = p_ts_week_id
       AND entry_date = TRUNC(p_entry_date);

    SELECT COUNT(*) INTO v_pending
      FROM oc_ts_entry
     WHERE ts_week_id = p_ts_week_id AND day_status <> 'Approved';

    IF v_pending = 0 THEN
      UPDATE oc_ts_week
         SET week_status = CASE WHEN v_over = 'Y'
                                THEN 'Overridden and approved' ELSE 'Approved' END,
             approved_by = p_actor,
             approved_on = SYSTIMESTAMP,
             updated_by  = p_actor
       WHERE ts_week_id = p_ts_week_id;
    END IF;

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'DAY', TRUNC(p_entry_date),
              'Approve', NULL, NULL, p_actor_emp_id, p_trace_id);
  END approve_day;


  PROCEDURE reject_day(
    p_ts_week_id   IN NUMBER,
    p_entry_date   IN DATE,
    p_reason       IN VARCHAR2,
    p_remarks      IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp    oc_ts_week.employee_id%TYPE;
    v_period oc_ts_week.period_id%TYPE;
  BEGIN
    IF p_reason IS NULL OR p_reason NOT IN ('Manager','Client','Absence') THEN
      RAISE_APPLICATION_ERROR(-20013, 'Select a rejection reason.');
    END IF;

    SELECT employee_id, period_id INTO v_emp, v_period
      FROM oc_ts_week WHERE ts_week_id = p_ts_week_id;

    assert_not_self(v_emp, p_actor_emp_id);

    UPDATE oc_ts_entry
       SET day_status     = 'Rejected',
           reject_reason  = p_reason,
           reject_remarks = p_remarks,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id
       AND entry_date = TRUNC(p_entry_date);

    -- Any rejected day puts the whole week back with the employee, and the
    -- rejected dates are what NOTIF-004 shows them (#5).
    UPDATE oc_ts_week
       SET week_status    = 'Rejected',
           reject_reason  = p_reason,
           reject_remarks = p_remarks,
           locked_flag    = 'N',
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'DAY', TRUNC(p_entry_date),
              'Reject', p_reason, p_remarks, p_actor_emp_id, p_trace_id);
  END reject_day;


  -- Undo an Approve or a Reject on one day.
  --
  -- Without this a mis-click is unrecoverable from the screen: approve_day only
  -- ever writes 'Approved' and reject_day only 'Rejected', and neither will move
  -- a day back to Pending, so the buttons that produced the mistake cannot
  -- correct it.
  --
  -- The week status is RECOMPUTED from the days rather than assumed. reject_day
  -- sets the week to 'Rejected' on the first rejected day, so undoing that one
  -- day has to ask what the remaining days now say - otherwise a week with every
  -- rejection revoked would still read Rejected to the employee and be sent back
  -- for nothing.
  PROCEDURE revoke_decision(
    p_ts_week_id   IN NUMBER,
    p_entry_date   IN DATE,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_emp      oc_ts_week.employee_id%TYPE;
    v_period   oc_ts_week.period_id%TYPE;
    v_wstatus  oc_ts_week.week_status%TYPE;
    v_over     oc_ts_week.overridden_flag%TYPE;
    v_pstatus  oc_time_period.status%TYPE;
    v_decided  NUMBER;
    v_rejected NUMBER;
    v_pending  NUMBER;
    v_reason   oc_ts_entry.reject_reason%TYPE;
    v_remarks  oc_ts_entry.reject_remarks%TYPE;
  BEGIN
    SELECT w.employee_id, w.period_id, w.week_status, w.overridden_flag, p.status
      INTO v_emp, v_period, v_wstatus, v_over, v_pstatus
      FROM oc_ts_week     w
      JOIN oc_time_period p ON p.period_id = w.period_id
     WHERE w.ts_week_id = p_ts_week_id;

    assert_not_self(v_emp, p_actor_emp_id);

    -- A confirmed month has already been handed to accrual (RULE-020), so the
    -- hours behind it are committed elsewhere. Correcting one now is a retro
    -- adjustment (RULE-019), not an undo.
    IF v_wstatus = 'Closed' THEN
      RAISE_APPLICATION_ERROR(-20023,
        'This week is closed and has gone to accrual. Raise a backdated '
        || 'adjustment instead.');
    END IF;

    IF v_pstatus <> 'Open' THEN
      RAISE_APPLICATION_ERROR(-20024,
        'The period is not open, so this decision cannot be undone. Raise a '
        || 'backdated adjustment instead.');
    END IF;

    -- Nothing to undo is an error, not a no-op: the button would otherwise
    -- report success for a day it never touched.
    SELECT COUNT(*) INTO v_decided
      FROM oc_ts_entry
     WHERE ts_week_id = p_ts_week_id
       AND entry_date = TRUNC(p_entry_date)
       AND day_status IN ('Approved','Rejected');

    IF v_decided = 0 THEN
      RAISE_APPLICATION_ERROR(-20025,
        'There is no approval or rejection on '
        || TO_CHAR(TRUNC(p_entry_date),'DD-Mon-YYYY') || ' to undo.');
    END IF;

    UPDATE oc_ts_entry
       SET day_status     = 'Pending',
           reject_reason  = NULL,
           reject_remarks = NULL,
           approved_by    = NULL,
           approved_on    = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id
       AND entry_date = TRUNC(p_entry_date);

    SELECT COUNT(CASE WHEN day_status = 'Rejected' THEN 1 END),
           COUNT(CASE WHEN day_status <> 'Approved' THEN 1 END)
      INTO v_rejected, v_pending
      FROM oc_ts_entry
     WHERE ts_week_id = p_ts_week_id;

    IF v_rejected > 0 THEN
      -- Still rejected somewhere. Carry the reason of a day that IS still
      -- rejected, so the week does not keep quoting the one just undone.
      SELECT MAX(reject_reason), MAX(reject_remarks)
        INTO v_reason, v_remarks
        FROM oc_ts_entry
       WHERE ts_week_id = p_ts_week_id AND day_status = 'Rejected';

      UPDATE oc_ts_week
         SET week_status    = 'Rejected',
             reject_reason  = v_reason,
             reject_remarks = v_remarks,
             approved_by    = NULL,
             approved_on    = NULL,
             updated_by     = p_actor
       WHERE ts_week_id = p_ts_week_id;

    ELSIF v_pending = 0 THEN
      UPDATE oc_ts_week
         SET week_status    = CASE WHEN v_over = 'Y'
                                   THEN 'Overridden and approved' ELSE 'Approved' END,
             reject_reason  = NULL,
             reject_remarks = NULL,
             updated_by     = p_actor
       WHERE ts_week_id = p_ts_week_id;

    ELSE
      -- Back with the manager. 'Submitted' and not 'Not yet submitted': the
      -- employee did submit, and undoing a manager decision must never quietly
      -- put the week back in their drafts where they would have to send it
      -- again.
      UPDATE oc_ts_week
         SET week_status    = 'Submitted',
             reject_reason  = NULL,
             reject_remarks = NULL,
             approved_by    = NULL,
             approved_on    = NULL,
             updated_by     = p_actor
       WHERE ts_week_id = p_ts_week_id;
    END IF;

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'DAY', TRUNC(p_entry_date),
              'Revoke', NULL, NULL, p_actor_emp_id, p_trace_id);
  END revoke_decision;


  -- Undo a whole week's worth of decisions.
  --
  -- Deliberately a loop over revoke_decision rather than one bulk UPDATE: every
  -- guard (closed week, closed period, never your own timesheet) and the week
  -- status recompute live in there, and a second implementation of the same
  -- rules is how the two drift apart. One audit row per day is also the honest
  -- record - the manager approved those days individually or in a batch, and
  -- either way each one is being undone.
  PROCEDURE revoke_week_decision(
    p_ts_week_id   IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_done NUMBER := 0;
  BEGIN
    FOR d IN (SELECT DISTINCT entry_date
                FROM oc_ts_entry
               WHERE ts_week_id = p_ts_week_id
                 AND day_status IN ('Approved','Rejected')
               ORDER BY entry_date) LOOP
      revoke_decision(p_ts_week_id, d.entry_date, p_actor_emp_id, p_actor, p_trace_id);
      v_done := v_done + 1;
    END LOOP;

    IF v_done = 0 THEN
      RAISE_APPLICATION_ERROR(-20025,
        'There is no approval or rejection on this week to undo.');
    END IF;
  END revoke_week_decision;


  -- PROC-004: the manager corrects the hours and approves in one step. The
  -- original is retained by TRG_OC_TSE_AUDIT_CAPTURE because SOURCE='Manager'.
  PROCEDURE override_approve(
    p_ts_entry_id  IN NUMBER,
    p_new_hours    IN NUMBER,
    p_reason       IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
    v_week   NUMBER;
    v_emp    oc_ts_week.employee_id%TYPE;
    v_period oc_ts_week.period_id%TYPE;
    v_date   DATE;
  BEGIN
    SELECT e.ts_week_id, e.entry_date, w.employee_id, w.period_id
      INTO v_week, v_date, v_emp, v_period
      FROM oc_ts_entry e
      JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
     WHERE e.ts_entry_id = p_ts_entry_id;

    assert_not_self(v_emp, p_actor_emp_id);

    UPDATE oc_ts_entry
       SET hours      = p_new_hours,
           source     = 'Manager',       -- drives the audit capture
           updated_by = p_actor
     WHERE ts_entry_id = p_ts_entry_id;

    validate_day(v_week, v_date);

    -- Record the manager's stated reason against the audit row just written.
    UPDATE oc_ts_audit
       SET change_reason = p_reason, trace_id = p_trace_id
     WHERE audit_id = (SELECT MAX(audit_id) FROM oc_ts_audit
                        WHERE ts_entry_id = p_ts_entry_id);

    UPDATE oc_ts_week
       SET overridden_flag = 'Y', updated_by = p_actor
     WHERE ts_week_id = v_week;

    log_event(v_week, v_emp, NULL, v_period, 'DAY', v_date,
              'Override', NULL, p_reason, p_actor_emp_id, p_trace_id);
  END override_approve;


  -- Called after the last override_approve of a session to close the week.
  PROCEDURE finish_override(
    p_ts_week_id   IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
  BEGIN
    approve_week(p_ts_week_id, p_actor_emp_id, p_actor);
  END finish_override;


  -- ACT-012 / ACT-019: approve every pending week the employee has in the
  -- month, for the project the manager is acting on.
  PROCEDURE approve_employee_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_employee_id  IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
  BEGIN
    assert_not_self(p_employee_id, p_actor_emp_id);

    FOR w IN (SELECT DISTINCT w.ts_week_id
                FROM oc_ts_week  w
                JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
               WHERE w.employee_id = p_employee_id
                 AND w.period_id   = p_period_id
                 AND e.project_id  = p_project_id
                 AND w.week_status NOT IN
                     ('Approved','Overridden and approved','Closed'))
    LOOP
      approve_week(w.ts_week_id, p_actor_emp_id, p_actor, p_trace_id);
    END LOOP;

    log_event(NULL, p_employee_id, p_project_id, p_period_id, 'MONTH', NULL,
              'Approve', NULL, NULL, p_actor_emp_id, p_trace_id);
  END approve_employee_month;


  PROCEDURE reject_employee_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_employee_id  IN VARCHAR2,
    p_reason       IN VARCHAR2,
    p_remarks      IN VARCHAR2,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
  BEGIN
    IF p_reason IS NULL OR p_reason NOT IN ('Manager','Client','Absence') THEN
      RAISE_APPLICATION_ERROR(-20013, 'Select a rejection reason.');
    END IF;

    assert_not_self(p_employee_id, p_actor_emp_id);

    FOR w IN (SELECT DISTINCT w.ts_week_id
                FROM oc_ts_week  w
                JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
               WHERE w.employee_id = p_employee_id
                 AND w.period_id   = p_period_id
                 AND e.project_id  = p_project_id
                 AND w.week_status NOT IN ('Closed'))
    LOOP
      reject_week(w.ts_week_id, p_reason, p_remarks, p_actor_emp_id,
                  p_actor, p_trace_id);
    END LOOP;

    log_event(NULL, p_employee_id, p_project_id, p_period_id, 'MONTH', NULL,
              'Reject', p_reason, p_remarks, p_actor_emp_id, p_trace_id);
  END reject_employee_month;


  -- PROC-010 / ACT-024: advance-approve a future month at MONTH level. Defaulted
  -- hours are treated as approved; later actuals arrive as flagged adjustments.
  PROCEDURE advance_approve_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_employee_id  IN VARCHAR2 DEFAULT NULL,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL)
  IS
  BEGIN
    FOR w IN (SELECT DISTINCT w.ts_week_id, w.employee_id
                FROM oc_ts_week  w
                JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
               WHERE w.period_id  = p_period_id
                 AND e.project_id = p_project_id
                 AND (p_employee_id IS NULL OR w.employee_id = p_employee_id)
                 AND w.week_status NOT IN
                     ('Approved','Overridden and approved','Closed'))
    LOOP
      assert_not_self(w.employee_id, p_actor_emp_id);

      UPDATE oc_ts_entry
         SET day_status = 'Approved', approved_by = p_actor,
             approved_on = SYSTIMESTAMP, updated_by = p_actor
       WHERE ts_week_id = w.ts_week_id;

      UPDATE oc_ts_week
         SET week_status          = 'Approved',
             advance_closure_flag = 'Y',
             approved_by          = p_actor,
             approved_on          = SYSTIMESTAMP,
             updated_by           = p_actor
       WHERE ts_week_id = w.ts_week_id;

      log_event(w.ts_week_id, w.employee_id, p_project_id, p_period_id,
                'MONTH', NULL, 'AdvanceApprove', NULL,
                'Advance closure', p_actor_emp_id, p_trace_id);
    END LOOP;
  END advance_approve_month;


  -- ═══════════════════════════════════════════════════════════
  -- Leave-loss coverage (PROC-006)
  -- ═══════════════════════════════════════════════════════════

  -- Builds the absentee list for an FCP + Leave Loss = Yes project. LOP and
  -- maternity absences are excluded (RULE-014).
  FUNCTION generate_llc_lines(
    p_project_id IN NUMBER,
    p_period_id  IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'SYSTEM') RETURN NUMBER
  IS
    v_count NUMBER := 0;
    v_ok    NUMBER;
    v_start DATE;
    v_end   DATE;
  BEGIN
    SELECT COUNT(*) INTO v_ok
      FROM oc_time_project
     WHERE project_id      = p_project_id
       AND revenue_model   = 'FCP'
       AND leave_loss_flag = 'Y';
    IF v_ok = 0 THEN
      RAISE_APPLICATION_ERROR(-20014,
        'Leave-loss coverage applies only to FCP projects with Leave Loss = Yes.');
    END IF;

    SELECT start_date, end_date INTO v_start, v_end
      FROM oc_time_period WHERE period_id = p_period_id;

    INSERT INTO oc_ts_leave_loss_cover (
      project_id, period_id, absent_employee_id, absence_date,
      absence_hours, absence_type, llc_status, created_by)
    SELECT p_project_id, p_period_id, ab.employee_id, ab.absence_date,
           ab.absence_hours, ab.absence_type, 'Open', p_actor
      FROM oc_time_absence    ab
      JOIN oc_time_allocation al ON al.employee_id = ab.employee_id
                               AND al.project_id  = p_project_id
                               AND al.status      = 'Active'
     WHERE ab.absence_date BETWEEN v_start AND v_end
       AND ab.approval_status = 'Approved'
       AND ab.is_lop       = 'N'          -- RULE-014
       AND ab.is_maternity = 'N'          -- RULE-014
       AND NOT EXISTS (SELECT 1 FROM oc_ts_leave_loss_cover x
                        WHERE x.project_id         = p_project_id
                          AND x.absent_employee_id = ab.employee_id
                          AND x.absence_date       = ab.absence_date);
    v_count := SQL%ROWCOUNT;
    RETURN v_count;
  END generate_llc_lines;


  PROCEDURE assign_cover(
    p_llc_id            IN NUMBER,
    p_cover_employee_id IN VARCHAR2,
    p_actor             IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
    v_project NUMBER;
    v_date    DATE;
    v_absent  VARCHAR2(50);
    v_ok      NUMBER;
    v_clash   NUMBER;
  BEGIN
    SELECT project_id, absence_date, absent_employee_id
      INTO v_project, v_date, v_absent
      FROM oc_ts_leave_loss_cover WHERE llc_id = p_llc_id;

    -- RULE-014: unbilled on the same project, not absent that day, not already
    -- assigned. Checked here as well as in the LOV so an API caller cannot
    -- bypass the filter.
    SELECT COUNT(*) INTO v_ok
      FROM oc_time_allocation al
     WHERE al.project_id     = v_project
       AND al.employee_id    = p_cover_employee_id
       AND al.status         = 'Active'
       AND al.billing_status = 'Unbilled';

    -- Is the candidate themselves absent that day, or already covering someone
    -- else on it? EXISTS is a SQL construct and cannot appear in a PL/SQL IF
    -- (PLS-00204), so both tests are evaluated in SQL. CASE WHEN EXISTS rather
    -- than COUNT(*) keeps the short-circuit: it stops at the first hit instead
    -- of counting every match.
    SELECT CASE WHEN EXISTS (SELECT 1 FROM oc_time_absence ab
                              WHERE ab.employee_id  = p_cover_employee_id
                                AND ab.absence_date = v_date)
                THEN 1 ELSE 0 END
         + CASE WHEN EXISTS (SELECT 1 FROM oc_ts_leave_loss_cover c
                              WHERE c.cover_employee_id = p_cover_employee_id
                                AND c.absence_date      = v_date
                                AND c.llc_id           <> p_llc_id)
                THEN 1 ELSE 0 END
      INTO v_clash
      FROM dual;

    IF v_ok = 0
       OR p_cover_employee_id = v_absent
       OR v_clash > 0 THEN
      RAISE_APPLICATION_ERROR(-20014,
        'This colleague cannot cover (billed, absent, or already assigned).');
    END IF;

    UPDATE oc_ts_leave_loss_cover
       SET cover_employee_id = p_cover_employee_id,
           llc_status        = 'Assigned',
           assigned_by       = p_actor,
           assigned_on       = SYSTIMESTAMP,
           updated_by        = p_actor
     WHERE llc_id = p_llc_id;
  END assign_cover;


  PROCEDURE approve_cover(
    p_llc_id       IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
    v_cover VARCHAR2(50);
  BEGIN
    SELECT cover_employee_id INTO v_cover
      FROM oc_ts_leave_loss_cover WHERE llc_id = p_llc_id;

    IF v_cover IS NULL THEN
      RAISE_APPLICATION_ERROR(-20014, 'Assign a covering colleague first.');
    END IF;

    -- The trigger sets BILLED_FLAG and APPROVED_ON: approved cover means the
    -- absence hours count as billed for the FCP project (PROC-006).
    UPDATE oc_ts_leave_loss_cover
       SET llc_status  = 'Approved',
           approved_by = p_actor,
           updated_by  = p_actor
     WHERE llc_id = p_llc_id;
  END approve_cover;


  -- ═══════════════════════════════════════════════════════════
  -- Salary stopping (PROC-007)
  -- ═══════════════════════════════════════════════════════════

  -- RULE-016: at the payroll cut-off, hold salary for employees with at least
  -- one Defaulted week. 'Submitted / awaiting approval' does NOT hold pay.
  FUNCTION run_salary_stopping(
    p_period_id IN NUMBER,
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER',
    p_from      IN DATE     DEFAULT NULL) RETURN NUMBER
  IS
    v_job  NUMBER;
    v_read NUMBER := 0;
    v_up   NUMBER := 0;
    -- THE LAST DATE THAT CAN LEGITIMATELY BE HELD.
    --
    -- The payroll cut-off lands BEFORE the month ends -- typically the 25th,
    -- while the delivery cut-off for the same month is the 10th of the NEXT
    -- one. Running on the 26th of July and asking "which dates were not
    -- submitted" therefore sweeps in 26-31 July, which have not happened yet.
    -- Holding somebody's pay for failing to submit a timesheet for next
    -- Thursday is indefensible, and nothing downstream would have caught it:
    -- the rows look exactly like real ones.
    --
    -- LEAST of the two bounds, so it is right whichever way they sit:
    --   * never on or after the payroll cut-off itself
    --   * never in the future, whenever the job is actually run
    -- and TRUNC(SYSDATE) alone if the period has no payroll cut-off set.
    v_upto DATE;
    -- THE PAYROLL PERIOD IS NOT THE CALENDAR MONTH, and scoping this job by
    -- PERIOD_ID was wrong (corrected 10-Aug-2026).
    --
    -- Payroll for "July" runs roughly 26-Jun to 26-Jul. So the window crosses
    -- a calendar boundary in both directions: 26-30 June belong to the July
    -- payroll run but to the JUNE period row, and 27-31 July belong to the
    -- NEXT run. Filtering on w.period_id = p_period_id therefore held the wrong
    -- days at both ends -- it missed the late-June days entirely and swept in
    -- end-of-July days that payroll had not reached.
    --
    -- The window is derived from consecutive payroll cut-offs rather than a new
    -- column, because that is already the fact that defines it: the run covers
    -- everything after the last cut-off up to this one. When the accrual
    -- control period arrives with an explicit start date, p_from below is where
    -- it plugs in and nothing else changes.
    v_from DATE;
  BEGIN
    SELECT LEAST(NVL(payroll_cutoff, TRUNC(SYSDATE)), TRUNC(SYSDATE))
      INTO v_upto
      FROM oc_time_period WHERE period_id = p_period_id;

    IF p_from IS NOT NULL THEN
      v_from := p_from;
    ELSE
      -- The day after the previous period's payroll cut-off. NVL to the start
      -- of this period when there is no earlier cut-off to chain from, so a
      -- first run is bounded rather than unbounded.
      SELECT NVL(MAX(prev.payroll_cutoff) + 1,
                 (SELECT start_date FROM oc_time_period WHERE period_id = p_period_id))
        INTO v_from
        FROM oc_time_period prev
       WHERE prev.payroll_cutoff IS NOT NULL
         AND prev.payroll_cutoff < (SELECT NVL(payroll_cutoff, TRUNC(SYSDATE))
                                      FROM oc_time_period
                                     WHERE period_id = p_period_id);
    END IF;

    v_job := start_job('Salary Stopping', 'SalaryStopping',
                       p_period_id, TRUNC(SYSDATE), NULL, p_actor);

    -- REWRITTEN 10-Aug-2026 to the functional owner's instruction: run at
    -- PAYROLL CUT-OFF + 1 and record "the dates for which the time is not yet
    -- submitted by the employee". Three things changed from the week-based
    -- version, and each was explicit:
    --
    --   * the test is SUBMITTED_ON IS NULL, not "defaulted". A week the
    --     employee never submitted holds pay whether or not the defaulting job
    --     has run yet -- the payroll cut-off does not wait for it. This still
    --     honours RULE-016 for free: a submitted week has a stamp, so a manager
    --     who has not yet approved can never cause a hold.
    --
    --   * contractors are INCLUDED. Assumption RA-012 excluded them; the owner
    --     was asked about "employees/contractors" and answered yes to all,
    --     irrespective of grade. RA-012 is retired.
    --
    --   * day rows are written under the header, because the correction the
    --     employee is given is "by date".
    FOR e IN (SELECT w.employee_id,
                     COUNT(*) AS weeks_total,
                     SUM(CASE WHEN w.submitted_on IS NULL
                              THEN 1 ELSE 0 END)                 AS weeks_def,
                     SUM(CASE WHEN w.submitted_on IS NULL
                              THEN 0 ELSE 1 END)                 AS weeks_sub,
                     SUM(CASE WHEN w.submitted_on IS NULL
                              THEN 0 ELSE w.total_hours END)     AS applied_hrs,
                     SUM(CASE WHEN w.submitted_on IS NULL
                              THEN w.total_hours ELSE 0 END)     AS default_hrs
                FROM oc_ts_week     w
                JOIN oc_time_worker k ON k.employee_id = w.employee_id
               WHERE k.status = 'Active'
                 -- Any week OVERLAPPING the payroll window, whichever calendar
                 -- period it belongs to. Overlap, not containment: a week that
                 -- straddles the cut-off contributes its earlier days.
                 AND w.week_start <= v_upto
                 AND w.week_end   >= v_from
               GROUP BY w.employee_id
              HAVING SUM(CASE WHEN w.submitted_on IS NULL THEN 1 ELSE 0 END) > 0)
    LOOP
      v_read := v_read + 1;

      MERGE INTO oc_ts_salary_hold h
      USING (SELECT e.employee_id AS employee_id, p_period_id AS period_id FROM dual) s
         ON (h.employee_id = s.employee_id AND h.period_id = s.period_id)
       WHEN MATCHED THEN UPDATE
            SET h.weeks_total     = e.weeks_total,
                h.weeks_submitted = e.weeks_sub,
                h.weeks_defaulted = e.weeks_def,
                h.applied_hours   = e.applied_hrs,
                h.default_hours   = e.default_hrs
          WHERE h.salary_status = 'Held'
       WHEN NOT MATCHED THEN
            INSERT (employee_id, period_id, weeks_total, weeks_submitted,
                    weeks_defaulted, applied_hours, default_hours, salary_status)
            VALUES (e.employee_id, p_period_id, e.weeks_total, e.weeks_sub,
                    e.weeks_def, e.applied_hrs, e.default_hrs, 'Held');

      -- The 60 calendar days the employee gets to correct (CFG-012). Stamped
      -- only when the hold is first opened: re-running the job must not keep
      -- pushing the deadline out, or the window never closes.
      UPDATE oc_ts_salary_hold h
         SET h.hold_release_days = NVL(h.hold_release_days,
               (SELECT NVL(p.hold_release_days, 60) FROM oc_time_period p
                 WHERE p.period_id = p_period_id)),
             h.window_expires_on = NVL(h.window_expires_on,
               TRUNC(SYSDATE) + NVL((SELECT NVL(p.hold_release_days, 60)
                                       FROM oc_time_period p
                                      WHERE p.period_id = p_period_id), 60))
       WHERE h.employee_id = e.employee_id
         AND h.period_id   = p_period_id;

      -- ── the dates themselves ─────────────────────────────────
      -- One row per unsubmitted DAY. INSERT ... WHERE NOT EXISTS rather than a
      -- MERGE so a day the employee has already corrected is never reset by a
      -- later run of the job -- losing somebody's correction because the
      -- scheduler ran twice would be unforgivable and entirely silent.
      INSERT INTO oc_ts_salary_hold_day
             (hold_id, employee_id, period_id, work_date, ts_week_id,
              expected_hours, day_status, created_by)
      SELECT h.hold_id, e.employee_id, p_period_id, d.entry_date, d.ts_week_id,
             d.std_hours, 'Held', p_actor
        FROM (SELECT en.ts_week_id, en.entry_date,
                     NVL(MAX(en.standard_hours),0) AS std_hours
                FROM oc_ts_entry en
                JOIN oc_ts_week  wk ON wk.ts_week_id = en.ts_week_id
               WHERE wk.employee_id  = e.employee_id
                 AND wk.submitted_on IS NULL
                 -- The payroll window, not the calendar month. Strictly before
                 -- the cut-off: a day cannot be late on the day itself.
                 AND en.entry_date  >= v_from
                 AND en.entry_date   < v_upto
               GROUP BY en.ts_week_id, en.entry_date
              HAVING NVL(MAX(en.standard_hours),0) > 0) d
        CROSS JOIN (SELECT hold_id FROM oc_ts_salary_hold
                     WHERE employee_id = e.employee_id
                       AND period_id   = p_period_id) h
       WHERE NOT EXISTS (SELECT 1 FROM oc_ts_salary_hold_day x
                          WHERE x.employee_id = e.employee_id
                            AND x.work_date   = d.entry_date);
      v_up := v_up + 1;
    END LOOP;

    -- The window closing is a state, not an absence of one. Without this a
    -- lapsed row stays 'Held' for ever and nothing distinguishes "still has
    -- time" from "too late" except arithmetic the reader has to do.
    UPDATE oc_ts_salary_hold_day d
       SET d.day_status = 'Expired', d.updated_by = p_actor,
           d.updated_on = SYSTIMESTAMP
     WHERE d.period_id  = p_period_id
       AND d.day_status IN ('Held','Rejected')
       AND EXISTS (SELECT 1 FROM oc_ts_salary_hold h
                    WHERE h.hold_id = d.hold_id
                      AND TRUNC(SYSDATE) > h.window_expires_on);

    -- An employee with no employee-caused default left is released
    -- automatically: the reason for the hold has gone. Same filter as above —
    -- a manager-caused default must not keep a hold alive any more than it may
    -- create one.
    UPDATE oc_ts_salary_hold h
       SET salary_status = 'Released',
           released_by   = p_actor,
           released_on   = SYSTIMESTAMP,
           remarks       = 'Auto-released: every week has now been submitted.'
     WHERE h.period_id     = p_period_id
       AND h.salary_status = 'Held'
       AND NOT EXISTS (SELECT 1 FROM oc_ts_week w
                        WHERE w.employee_id  = h.employee_id
                          AND w.submitted_on IS NULL
                          AND w.week_start  <= v_upto
                          AND w.week_end    >= v_from);

    finish_job(v_job, v_read, v_up, 0);
    COMMIT;
    RETURN v_job;
  END run_salary_stopping;


  -- The employee corrects one held DATE. PROC-007, functional owner 10-Aug-2026:
  -- "displayed to employee for a period of 60 calendar days to correct by date
  -- and get it approved".
  --
  -- Deliberately takes no actor_emp_id and calls no assert_not_self. RULE-015
  -- stops a manager APPROVING their own time; it has nothing to say about a
  -- person entering their own hours, which is what every employee does on the
  -- timesheet anyway. The control here is the manager's sign-off in
  -- decide_salary_hold_day, not a restriction on who may type.
  PROCEDURE correct_salary_hold_day(
    p_hold_day_id IN NUMBER,
    p_hours       IN NUMBER,
    p_reason      IN VARCHAR2,
    p_actor       IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
    v_status  oc_ts_salary_hold_day.day_status%TYPE;
    v_expires DATE;
    v_date    DATE;
  BEGIN
    SELECT d.day_status, h.window_expires_on, d.work_date
      INTO v_status, v_expires, v_date
      FROM oc_ts_salary_hold_day d
      JOIN oc_ts_salary_hold     h ON h.hold_id = d.hold_id
     WHERE d.hold_day_id = p_hold_day_id;

    -- Already decided. Correcting an approved day would silently reopen a
    -- release payroll has already been told about.
    IF v_status NOT IN ('Held','Rejected') THEN
      RAISE_APPLICATION_ERROR(-20005,
        'This date is ' || v_status || ' and can no longer be corrected.');
    END IF;

    -- The 60 days are the whole point of the window; past it this is a payroll
    -- conversation, not a self-service one.
    IF v_expires IS NOT NULL AND TRUNC(SYSDATE) > v_expires THEN
      RAISE_APPLICATION_ERROR(-20006,
        'The 60-day correction window for this date closed on '
        || TO_CHAR(v_expires,'DD-Mon-YYYY') || '. Contact payroll.');
    END IF;

    IF p_hours IS NULL OR p_hours < 0 OR p_hours > 24 THEN
      RAISE_APPLICATION_ERROR(-20003, 'Enter between 0 and 24 hours.');
    END IF;

    IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) = 0 THEN
      RAISE_APPLICATION_ERROR(-20013,
        'Give a reason for the correction — your manager approves it on the '
        || 'strength of it.');
    END IF;

    UPDATE oc_ts_salary_hold_day
       SET day_status        = 'Corrected',
           corrected_hours   = p_hours,
           correction_reason = p_reason,
           corrected_by      = p_actor,
           corrected_on      = SYSTIMESTAMP,
           reject_remarks    = NULL,
           updated_by        = p_actor,
           updated_on        = SYSTIMESTAMP
     WHERE hold_day_id = p_hold_day_id;
  END correct_salary_hold_day;


  -- The manager's decision. Approve frees that date; Reject sends it back and
  -- it stays held, which is why Rejected is still a correctable state above.
  PROCEDURE decide_salary_hold_day(
    p_hold_day_id  IN NUMBER,
    p_approve      IN VARCHAR2,
    p_remarks      IN VARCHAR2 DEFAULT NULL,
    p_actor_emp_id IN VARCHAR2,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
    v_emp    VARCHAR2(50);
    v_status oc_ts_salary_hold_day.day_status%TYPE;
    v_hold   NUMBER;
    v_left   NUMBER;
  BEGIN
    SELECT employee_id, day_status, hold_id
      INTO v_emp, v_status, v_hold
      FROM oc_ts_salary_hold_day
     WHERE hold_day_id = p_hold_day_id;

    -- RULE-015 applies here: this IS an approval.
    assert_not_self(v_emp, p_actor_emp_id);

    IF v_status <> 'Corrected' THEN
      RAISE_APPLICATION_ERROR(-20005,
        'Only a corrected date can be decided. This one is ' || v_status || '.');
    END IF;

    IF NVL(p_approve,'N') = 'Y' THEN
      UPDATE oc_ts_salary_hold_day
         SET day_status = 'Approved', approved_by = p_actor_emp_id,
             approved_on = SYSTIMESTAMP, updated_by = p_actor,
             updated_on = SYSTIMESTAMP
       WHERE hold_day_id = p_hold_day_id;
    ELSE
      IF p_remarks IS NULL OR LENGTH(TRIM(p_remarks)) = 0 THEN
        RAISE_APPLICATION_ERROR(-20013,
          'Say why it is being sent back (RULE-013).');
      END IF;
      UPDATE oc_ts_salary_hold_day
         SET day_status = 'Rejected', reject_remarks = p_remarks,
             approved_by = NULL, approved_on = NULL,
             updated_by = p_actor, updated_on = SYSTIMESTAMP
       WHERE hold_day_id = p_hold_day_id;
    END IF;

    -- When every held date is approved the hold itself has nothing left to
    -- hold, so it releases. Done here rather than waiting for the nightly job:
    -- this is somebody's pay, and "it will clear tonight" is not good enough.
    SELECT COUNT(*) INTO v_left
      FROM oc_ts_salary_hold_day
     WHERE hold_id = v_hold AND day_status <> 'Approved';

    IF v_left = 0 THEN
      UPDATE oc_ts_salary_hold
         SET salary_status = 'Released', released_by = p_actor_emp_id,
             released_on = SYSTIMESTAMP,
             remarks = 'Released: every held date corrected and approved.'
       WHERE hold_id = v_hold AND salary_status = 'Held';
    END IF;
  END decide_salary_hold_day;


  PROCEDURE release_salary_hold(
    p_hold_id      IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_remarks      IN VARCHAR2 DEFAULT NULL,
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
  IS
    v_emp    VARCHAR2(50);
    v_period NUMBER;
    v_def    NUMBER;
  BEGIN
    SELECT employee_id, period_id INTO v_emp, v_period
      FROM oc_ts_salary_hold WHERE hold_id = p_hold_id;

    assert_not_self(v_emp, p_actor_emp_id);

    -- ACT-026 precondition: the defaulted timesheet must be corrected first.
    SELECT COUNT(*) INTO v_def
      FROM oc_ts_week
     WHERE employee_id = v_emp AND period_id = v_period
       AND week_status = 'Defaulted';

    IF v_def > 0 THEN
      RAISE_APPLICATION_ERROR(-20016,
        'Correct the defaulted timesheet before releasing the salary hold.');
    END IF;

    UPDATE oc_ts_salary_hold
       SET salary_status = 'Released',
           released_by   = p_actor,
           released_on   = SYSTIMESTAMP,
           remarks       = p_remarks
     WHERE hold_id = p_hold_id;

    log_event(NULL, v_emp, NULL, v_period, 'MONTH', NULL,
              'Release', NULL, p_remarks, p_actor_emp_id, NULL);
  END release_salary_hold;


  -- ═══════════════════════════════════════════════════════════
  -- Retro adjustments (PROC-008)
  -- ═══════════════════════════════════════════════════════════

  -- The employee enters the new line and reverses the old one, per DAY. Nothing
  -- posts until the manager approves (ACT-021) — the row is created
  -- 'Awaiting Approval' and materialises into OC_TS_ENTRY only on approval.
  FUNCTION apply_adjustment(
    p_employee_id    IN VARCHAR2,
    p_work_date      IN DATE,
    p_old_project_id IN NUMBER,
    p_old_task_id    IN NUMBER,
    p_old_hours      IN NUMBER,
    p_new_project_id IN NUMBER,
    p_new_task_id    IN NUMBER,
    p_new_hours      IN NUMBER,
    p_reason         IN VARCHAR2,
    p_adj_kind       IN VARCHAR2 DEFAULT 'RetroWBS',
    p_actor          IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id       IN VARCHAR2 DEFAULT NULL) RETURN NUMBER
  IS
    v_id     NUMBER;
    v_source NUMBER;
    v_post   NUMBER;
  BEGIN
    v_post := get_open_period_id;

    -- The period the work actually happened in.
    SELECT period_id INTO v_source
      FROM oc_time_period
     WHERE period_year  = EXTRACT(YEAR  FROM p_work_date)
       AND period_month = EXTRACT(MONTH FROM p_work_date)
       AND ROWNUM = 1;

    -- TRG_OC_TSADJ_WINDOW enforces RULE-019 on the way in.
    INSERT INTO oc_ts_adjustment (
      employee_id, work_date, source_period_id, post_period_id, adj_kind,
      old_project_id, old_task_id, old_hours,
      new_project_id, new_task_id, new_hours,
      status, reason, applied_by, trace_id)
    VALUES (
      p_employee_id, TRUNC(p_work_date), v_source, v_post, p_adj_kind,
      p_old_project_id, p_old_task_id, p_old_hours,
      p_new_project_id, p_new_task_id, NVL(p_new_hours,0),
      'Awaiting Approval', p_reason, p_actor, p_trace_id)
    RETURNING adjustment_id INTO v_id;

    RETURN v_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20017,
      'No period is defined for ' || TO_CHAR(p_work_date,'MON-YYYY') || '.');
  END apply_adjustment;


  -- On approval the net-off is materialised in the OPEN period as a paired
  -- Reversal(-) / Adjustment(+), which is exactly what the accrual hand-off
  -- reads (INT-014). The closed book is never touched.
  PROCEDURE approve_adjustment(
    p_adjustment_id IN NUMBER,
    p_actor_emp_id  IN VARCHAR2,
    p_actor         IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id      IN VARCHAR2 DEFAULT NULL)
  IS
    r        oc_ts_adjustment%ROWTYPE;
    v_week   NUMBER;
    v_shift  VARCHAR2(20);
    v_std    NUMBER;
    v_work   VARCHAR2(1);
    v_hol    VARCHAR2(200);
    v_oldmgr VARCHAR2(50);
    v_newmgr VARCHAR2(50);
  BEGIN
    SELECT * INTO r FROM oc_ts_adjustment WHERE adjustment_id = p_adjustment_id;

    assert_not_self(r.employee_id, p_actor_emp_id);

    IF r.posted_flag = 'Y' THEN
      RETURN;                      -- already materialised; approval is idempotent
    END IF;

    SELECT project_manager_id INTO v_oldmgr
      FROM oc_time_project WHERE project_id = r.old_project_id;
    v_newmgr := NULL;
    IF r.new_project_id IS NOT NULL THEN
      SELECT project_manager_id INTO v_newmgr
        FROM oc_time_project WHERE project_id = r.new_project_id;
    END IF;

    -- RA-014: both the old and the new project manager see it. Whichever acts
    -- is stamped; the row posts once both sides that exist have approved.
    UPDATE oc_ts_adjustment
       SET old_mgr_approved_by = CASE WHEN p_actor_emp_id = v_oldmgr
                                      THEN p_actor ELSE old_mgr_approved_by END,
           old_mgr_approved_on = CASE WHEN p_actor_emp_id = v_oldmgr
                                      THEN SYSTIMESTAMP ELSE old_mgr_approved_on END,
           new_mgr_approved_by = CASE WHEN p_actor_emp_id = v_newmgr
                                      THEN p_actor ELSE new_mgr_approved_by END,
           new_mgr_approved_on = CASE WHEN p_actor_emp_id = v_newmgr
                                      THEN SYSTIMESTAMP ELSE new_mgr_approved_on END,
           action_date         = TRUNC(SYSDATE)
     WHERE adjustment_id = p_adjustment_id;

    SELECT * INTO r FROM oc_ts_adjustment WHERE adjustment_id = p_adjustment_id;

    IF r.old_mgr_approved_by IS NULL
       OR (v_newmgr IS NOT NULL AND v_newmgr <> v_oldmgr
           AND r.new_mgr_approved_by IS NULL) THEN
      -- Still waiting on the other manager.
      log_event(NULL, r.employee_id, r.old_project_id, r.post_period_id,
                'DAY', r.work_date, 'Approve', NULL,
                'Partial approval - awaiting the other project manager',
                p_actor_emp_id, p_trace_id);
      RETURN;
    END IF;

    -- Post into the OPEN period, on the ORIGINAL work date, so the accrual
    -- extract keeps day-level fidelity (#10 day-wise).
    v_week := ensure_week(r.employee_id, r.work_date, p_actor);
    resolve_day(r.employee_id, r.old_project_id, r.work_date,
                v_shift, v_std, v_work, v_hol);

    -- Reversal (-) the old line.
    MERGE INTO oc_ts_entry e
    USING (SELECT v_week AS w, r.old_project_id AS p, r.old_task_id AS t,
                  r.work_date AS d FROM dual) s
       ON (e.ts_week_id = s.w AND e.project_id = s.p AND e.task_id = s.t
       AND e.entry_date = s.d AND e.entry_type = 'Reversal')
     WHEN MATCHED THEN UPDATE
          SET e.hours = -ABS(r.old_hours), e.adjustment_id = r.adjustment_id,
              e.updated_by = p_actor
     WHEN NOT MATCHED THEN
          INSERT (ts_week_id, project_id, task_id, entry_date, hours, entry_type,
                  shift_code, standard_hours, day_status, source,
                  adjustment_id, created_by)
          VALUES (v_week, r.old_project_id, r.old_task_id, r.work_date,
                  -ABS(r.old_hours), 'Reversal', v_shift, v_std, 'Approved',
                  'Manager', r.adjustment_id, p_actor);

    -- Adjustment (+) the new line, when hours actually move.
    IF NVL(r.new_hours,0) > 0 AND r.new_project_id IS NOT NULL THEN
      MERGE INTO oc_ts_entry e
      USING (SELECT v_week AS w, r.new_project_id AS p, r.new_task_id AS t,
                    r.work_date AS d FROM dual) s
         ON (e.ts_week_id = s.w AND e.project_id = s.p AND e.task_id = s.t
         AND e.entry_date = s.d AND e.entry_type = 'Adjustment')
       WHEN MATCHED THEN UPDATE
            SET e.hours = ABS(r.new_hours), e.adjustment_id = r.adjustment_id,
                e.updated_by = p_actor
       WHEN NOT MATCHED THEN
            INSERT (ts_week_id, project_id, task_id, entry_date, hours, entry_type,
                    shift_code, standard_hours, day_status, source,
                    adjustment_id, created_by)
            VALUES (v_week, r.new_project_id, r.new_task_id, r.work_date,
                    ABS(r.new_hours), 'Adjustment', v_shift, v_std, 'Approved',
                    'Manager', r.adjustment_id, p_actor);
    END IF;

    UPDATE oc_ts_adjustment
       SET status = 'Approved', posted_flag = 'Y', posted_on = SYSTIMESTAMP
     WHERE adjustment_id = p_adjustment_id;

    INSERT INTO oc_ts_audit (
      ts_week_id, employee_id, entry_date, change_type,
      old_project_id, old_task_id, old_hours,
      new_project_id, new_task_id, new_hours,
      change_reason, changed_by, trace_id)
    VALUES (
      v_week, r.employee_id, r.work_date,
      CASE r.adj_kind WHEN 'DefaultCorrection'
           THEN 'DefaultCorrection' ELSE 'Adjustment' END,
      r.old_project_id, r.old_task_id, r.old_hours,
      r.new_project_id, r.new_task_id, r.new_hours,
      r.reason, p_actor, p_trace_id);

    log_event(v_week, r.employee_id, r.old_project_id, r.post_period_id,
              'DAY', r.work_date, 'Approve', NULL,
              'Retro adjustment approved and posted', p_actor_emp_id, p_trace_id);
  END approve_adjustment;


  -- ═══════════════════════════════════════════════════════════
  -- Month confirmation & accrual hand-off (PROC-009)
  -- ═══════════════════════════════════════════════════════════

  FUNCTION confirm_month(
    p_project_id   IN NUMBER,
    p_period_id    IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_confirm_type IN VARCHAR2 DEFAULT 'Normal',
    p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id     IN VARCHAR2 DEFAULT NULL) RETURN NUMBER
  IS
    v_emps     NUMBER;
    v_appr     NUMBER;
    v_confirm  NUMBER;
    v_batch    VARCHAR2(64);
    v_rows     NUMBER := 0;
    v_year     NUMBER;
    v_month    NUMBER;
    v_pname    VARCHAR2(30);
  BEGIN
    SELECT period_year, period_month, period_name
      INTO v_year, v_month, v_pname
      FROM oc_time_period WHERE period_id = p_period_id;

    -- RULE-020: every employee on the project must be Approved. This is a
    -- single all-employees-at-once action; there is no per-employee send.
    SELECT COUNT(*),
           SUM(CASE WHEN month_status = 'Approved' THEN 1 ELSE 0 END)
      INTO v_emps, v_appr
      FROM v_oc_ts_month_summary
     WHERE project_id = p_project_id AND period_id = p_period_id;

    IF NVL(v_emps,0) = 0 THEN
      RAISE_APPLICATION_ERROR(-20020,
        'There is no approved time on this project for the period.');
    END IF;

    IF v_emps <> NVL(v_appr,0) THEN
      RAISE_APPLICATION_ERROR(-20020,
        'Approve every employee''s month before confirming to accrual.');
    END IF;

    v_batch := 'O2CTIME-' || TO_CHAR(p_project_id) || '-' ||
               TO_CHAR(p_period_id) || '-' || TO_CHAR(SYSTIMESTAMP,'YYYYMMDDHH24MISSFF3');

    MERGE INTO oc_ts_month_confirm c
    USING (SELECT p_project_id AS project_id, p_period_id AS period_id FROM dual) s
       ON (c.project_id = s.project_id AND c.period_id = s.period_id)
     WHEN MATCHED THEN UPDATE
          SET c.confirm_type   = p_confirm_type,
              c.confirmed_by   = p_actor,
              c.confirmed_on   = SYSTIMESTAMP,
              c.accrual_status = 'Pending',
              c.trace_id       = p_trace_id
     WHEN NOT MATCHED THEN
          INSERT (project_id, period_id, period_year, period_month,
                  confirm_type, confirmed_by, trace_id)
          VALUES (p_project_id, p_period_id, v_year, v_month,
                  p_confirm_type, p_actor, p_trace_id);

    SELECT confirm_id INTO v_confirm
      FROM oc_ts_month_confirm
     WHERE project_id = p_project_id AND period_id = p_period_id;

    -- Fill the interface table with the CONSOLIDATED timesheet
    -- (employee x project x WBS x day) plus the day-wise Reversal(-)/
    -- Adjustment(+) rows. Manager-approved data only.
    INSERT INTO xx_o2c_timesheet_accrual_if (
      period, period_year, period_month, confirm_id,
      employee_id, employee_name, worker_type,
      project_number, project_name, customer_name, revenue_model,
      wbs_task, wbs_task_name, work_date,
      billable_hours, non_billable_hours, leave_hours, unbilled_reason,
      entry_type, flag, action_date,
      source_ts_id, source_adj_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           -- The workflow flag that explains this row to the accrual reader.
           -- Ordered most-specific first: the row's own entry type wins, then the
           -- week-level flags. Correction and Contractor Unbilled hours were
           -- dropped on 30-Jul-2026 and no longer appear here.
           CASE
             WHEN e.entry_type = 'Reversal'              THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'            THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y'           THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y'           THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y'           THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y'           THEN 'Late submission'
             ELSE NULL
           END,
           NVL(TRUNC(CAST(w.approved_on AS DATE)), TRUNC(SYSDATE)),
           e.ts_entry_id, e.adjustment_id, v_batch, p_trace_id
      FROM oc_ts_week      w
      JOIN oc_ts_entry     e  ON e.ts_week_id  = w.ts_week_id
      JOIN oc_time_project p  ON p.project_id  = e.project_id
      JOIN oc_time_task    t  ON t.task_id     = e.task_id
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
     WHERE w.period_id  = p_period_id
       AND e.project_id = p_project_id
       AND e.hours     <> 0
       -- Only manager-approved data posts (INT-014).
       AND e.day_status = 'Approved'
       AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                        WHERE i.confirm_id   = v_confirm
                          AND i.source_ts_id = e.ts_entry_id
                          AND i.entry_type   = e.entry_type);
    v_rows := SQL%ROWCOUNT;

    UPDATE oc_ts_month_confirm c
       SET (c.employee_count, c.billable_hours, c.non_billable_hours,
            c.leave_hours, c.adjustment_hours) =
           (SELECT COUNT(DISTINCT i.employee_id),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                                THEN i.billable_hours END),0),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                                THEN i.non_billable_hours END),0),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                                THEN i.leave_hours END),0),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Reversal','Adjustment')
                                THEN i.billable_hours + i.non_billable_hours
                                     + i.leave_hours END),0)
              FROM xx_o2c_timesheet_accrual_if i
             WHERE i.confirm_id = c.confirm_id),
           c.accrual_status    = 'Success',
           c.accrual_rows      = (SELECT COUNT(*) FROM xx_o2c_timesheet_accrual_if i
                                   WHERE i.confirm_id = c.confirm_id),
           c.accrual_pushed_on = SYSTIMESTAMP,
           c.accrual_message   = 'Interface table filled; batch ' || v_batch
     WHERE c.confirm_id = v_confirm;

    -- The month is closed for the employees involved.
    UPDATE oc_ts_week w
       SET w.week_status = 'Closed', w.updated_by = p_actor
     WHERE w.period_id = p_period_id
       AND w.week_status IN ('Approved','Overridden and approved')
       AND EXISTS (SELECT 1 FROM oc_ts_entry e
                    WHERE e.ts_week_id = w.ts_week_id
                      AND e.project_id = p_project_id);

    log_event(NULL, '-', p_project_id, p_period_id, 'MONTH', NULL,
              'Confirm', NULL,
              'Confirmed ' || v_emps || ' employees; ' || v_rows ||
              ' interface rows in batch ' || v_batch,
              p_actor_emp_id, p_trace_id);

    RETURN v_confirm;
  END confirm_month;


  -- Called by the O2C accrual application once it has consumed a batch, so we
  -- can prove the hand-off completed (OBS-005) and never re-serve those rows.
  PROCEDURE mark_accrual_pulled(
    p_batch_id IN VARCHAR2,
    p_status   IN VARCHAR2 DEFAULT 'Y',
    p_message  IN VARCHAR2 DEFAULT NULL,
    p_actor    IN VARCHAR2 DEFAULT 'ACCRUAL')
  IS
  BEGIN
    UPDATE xx_o2c_timesheet_accrual_if
       SET processed_flag  = p_status,
           pulled_on       = SYSTIMESTAMP,
           pulled_by       = p_actor,
           process_message = p_message
     WHERE batch_id = p_batch_id
       AND processed_flag = 'N';

    IF p_status = 'E' THEN
      UPDATE oc_ts_month_confirm c
         SET c.accrual_status  = 'Failed',
             c.accrual_message = SUBSTR(p_message,1,2000)
       WHERE c.confirm_id IN (SELECT DISTINCT confirm_id
                                FROM xx_o2c_timesheet_accrual_if
                               WHERE batch_id = p_batch_id);
    END IF;
  END mark_accrual_pulled;


  -- ═══════════════════════════════════════════════════════════
  -- ACT-033 accrual top-up
  -- ═══════════════════════════════════════════════════════════

  FUNCTION run_accrual_top_up(
    p_period_id IN NUMBER,
    p_actor     IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id  IN VARCHAR2 DEFAULT NULL) RETURN NUMBER
  IS
    v_job   NUMBER;
    v_read  NUMBER := 0;
    v_rows  NUMBER := 0;
    v_fail  NUMBER := 0;
    v_batch VARCHAR2(40);
  BEGIN
    v_job := start_job('Accrual Top-up', 'AccrualTopUp',
                       p_period_id, TRUNC(SYSDATE), NULL, p_actor);

    -- One batch id for the whole run, so the consumer can acknowledge
    -- everything this job posted in a single call, exactly as it does for the
    -- batch confirm_month writes.
    v_batch := 'TOPUP-' || p_period_id || '-' ||
               TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISS');

    FOR c IN (SELECT confirm_id, project_id, period_id
                FROM oc_ts_month_confirm
               WHERE period_id = p_period_id)
    LOOP
      v_read := v_read + 1;
      BEGIN
        -- Deliberately the Reversal/Adjustment types only. An Actual or Default
        -- row that is not already in the interface was not approved when the
        -- month was confirmed, and posting it here would slip hours into
        -- accrual without the RULE-020 gate confirm_month applies.
        --
        -- The NOT EXISTS is the same three-column guard confirm_month uses, so
        -- running this twice posts nothing the second time.
        INSERT INTO xx_o2c_timesheet_accrual_if (
          period, period_year, period_month, confirm_id,
          employee_id, employee_name, worker_type,
          project_number, project_name, customer_name, revenue_model,
          wbs_task, wbs_task_name, work_date,
          billable_hours, non_billable_hours, leave_hours, unbilled_reason,
          entry_type, flag, action_date,
          source_ts_id, source_adj_id, batch_id, trace_id)
        SELECT pe.period_name, pe.period_year, pe.period_month, c.confirm_id,
               w.employee_id, wk.employee_name, wk.worker_type,
               p.project_number, p.project_name, p.customer_name, p.revenue_model,
               t.task_code, t.task_name, e.entry_date,
               CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                    THEN e.hours ELSE 0 END,
               CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                    THEN e.hours ELSE 0 END,
               CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
               e.unbilled_reason,
               e.entry_type,
               e.entry_type,          -- Reversal / Adjustment, its own flag
               -- ACTION_DATE, not the work date: RULE-019 makes the action date
               -- the thing accrual posts against, so a retro adjustment lands in
               -- the period it was decided in rather than the one it corrects.
               -- Falls back to the posting timestamp, then today, so the column
               -- is never null for a consumer that keys on it.
               NVL(a.action_date,
                   NVL(TRUNC(CAST(a.posted_on AS DATE)), TRUNC(SYSDATE))),
               e.ts_entry_id, e.adjustment_id, v_batch, p_trace_id
          FROM oc_ts_entry      e
          JOIN oc_ts_week       w  ON w.ts_week_id  = e.ts_week_id
          JOIN oc_ts_adjustment a  ON a.adjustment_id = e.adjustment_id
          JOIN oc_time_project  p  ON p.project_id  = e.project_id
          JOIN oc_time_task     t  ON t.task_id     = e.task_id
          JOIN oc_time_worker   wk ON wk.employee_id = w.employee_id
          JOIN oc_time_period   pe ON pe.period_id  = c.period_id
         WHERE w.period_id  = c.period_id
           AND e.project_id = c.project_id
           AND e.entry_type IN ('Reversal', 'Adjustment')
           AND e.hours     <> 0
           AND a.status     = 'Approved'
           AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                            WHERE i.confirm_id   = c.confirm_id
                              AND i.source_ts_id = e.ts_entry_id
                              AND i.entry_type   = e.entry_type);

        v_rows := v_rows + SQL%ROWCOUNT;

        -- Refresh the confirmation's own totals so the Accrual Integration page
        -- reports what the interface actually holds. adjustment_hours sums the
        -- signed values, so a Reversal(-) and its Adjustment(+) net off exactly
        -- as they will for the consumer.
        UPDATE oc_ts_month_confirm mc
           SET mc.adjustment_hours =
                 (SELECT NVL(SUM(CASE WHEN i.entry_type IN ('Reversal','Adjustment')
                                      THEN i.billable_hours + i.non_billable_hours
                                           + i.leave_hours END), 0)
                    FROM xx_o2c_timesheet_accrual_if i
                   WHERE i.confirm_id = mc.confirm_id),
               mc.accrual_rows =
                 (SELECT COUNT(*) FROM xx_o2c_timesheet_accrual_if i
                   WHERE i.confirm_id = mc.confirm_id)
         WHERE mc.confirm_id = c.confirm_id;

      EXCEPTION WHEN OTHERS THEN
        fail_record(v_job, 'MONTH_CONFIRM', TO_CHAR(c.confirm_id), NULL, SQLERRM);
        v_fail := v_fail + 1;
      END;
    END LOOP;

    finish_job(v_job, v_read, v_rows, v_fail);
    COMMIT;
    RETURN v_job;
  END run_accrual_top_up;

END oc_time_pkg;
/

PROMPT
PROMPT Compilation errors, if any:
SHOW ERRORS PACKAGE oc_time_pkg
SHOW ERRORS PACKAGE BODY oc_time_pkg

PROMPT
PROMPT ============================================================
PROMPT time/09_pkg_oc_time complete.
PROMPT ============================================================
--== END 09_pkg_oc_time.sql ==

-- ── Reference seed ───────────────────────────────────────────
PROMPT >>> 10 seed (dictionaries, common tasks, PRJ-ORG, config, periods)

--==============================================================
-- BEGIN 10_seed.sql
--==============================================================
--==============================================================
-- time/10_seed.sql
-- O2C Timesheet Module — Reference seed data
--
-- Everything here comes verbatim from the Data_Dictionaries and
-- Environment_Config sheets. Re-runnable: every insert is guarded by a NOT
-- EXISTS so re-seeding never duplicates and never overwrites a value finance
-- has since changed.
--
-- Seeds:
--   1  timesheet_status      9 statuses
--   2  flag                  8 workflow flags
--   3  rejection_reason      Manager / Client / Absence
--   4  unbilled_reason       common tasks + Billing Loss
--   5  shift_type            Regular / Night / Early / Split
--   6  accrual_entry_type    Actual / Default / Reversal / Adjustment
--   7  cutoff_type, period_status, billing_type, project_model, project_type
--   8  INTEGRATION           the PAGE-012 reference catalogue (INT-001..015)
--   9  OC_TIME_TASK          the 4 common non-billable tasks + Leave
--  10  OC_TIME_PROJECT       the Organization (Non-Billable) project, PRJ-ORG
--  11  OC_TIME_CONFIG        CFG-010 .. CFG-015
--
-- Idempotent. Depends on: time/01 .. time/09
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/11] timesheet_status — the 7 statuses
PROMPT ============================================================

-- Revised 30-Jul-2026, down from 9. 'Late submission' became a FLAG (the week is
-- still 'Submitted' because the manager must act on it), and 'Manager Defaulted'
-- folded into 'Defaulted' with DEFAULTED_BY recording which cut-off was missed.
DECLARE
  TYPE t_row IS RECORD (c VARCHAR2(60), m VARCHAR2(200), n VARCHAR2(400), o NUMBER);
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('Not yet submitted',       'Employee has not submitted',                     'Time (7 statuses)', 10),
    t_row('Submitted',               'Submitted, pending manager',                     'Time', 20),
    t_row('Approved',                'Approved by manager',                            'Time', 30),
    t_row('Rejected',                'Rejected by manager, back with the employee',    'Time', 40),
    t_row('Defaulted',               'A cut-off was missed - see DEFAULTED_BY',        'Time', 50),
    t_row('Overridden and approved', 'Manager edited then approved',                   'Time', 60),
    t_row('Closed',                  'Month confirmed / period closed',                'Time', 70));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'TIMESHEET_STATUS', v(i).c, v(i).m, v(i).n, v(i).o FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'TIMESHEET_STATUS'
                          AND lookup_code = v(i).c);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('timesheet_status seeded.');
END;
/

PROMPT ============================================================
PROMPT [2/11] flag — the 6 workflow flags
PROMPT ============================================================

-- Revised 30-Jul-2026, down from 8:
--   'Cancel'                   -> renamed 'Reversal'
--   'Correction'               -> dropped; OC_TS_APPROVAL logs a 'Resubmit'
--                                 action, which IS the audit trail
--   'Contractor Unbilled hours'-> dropped; out of scope for the time module
--
-- The first four are sticky (they record that something happened). Reversal and
-- Adjustment are derived from the week's entries by TRG_OC_TSW_TOTALS.
DECLARE
  TYPE t_row IS RECORD (c VARCHAR2(60), m VARCHAR2(200), o NUMBER);
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('Defaulted',             'Weekly or delivery cut-off missed',           10),
    t_row('Late submission',       'Submitted/resubmitted after the weekly cut-off; status stays Submitted', 20),
    t_row('Advance closure',       'Approved early (month-level)',                30),
    t_row('Overridden & approved', 'Manager edited & approved',                   40),
    t_row('Reversal',              'Old line reversed (-) retro',                 50),
    t_row('Adjustment',            'New line added (+) retro',                    60));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'WORKFLOW_FLAG', v(i).c, v(i).m, 'Flags', v(i).o FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'WORKFLOW_FLAG' AND lookup_code = v(i).c);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('workflow flags seeded.');
END;
/

PROMPT ============================================================
PROMPT [3/11] rejection_reason (FLD-057 / RULE-013)
PROMPT ============================================================

DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(60);
  v t_tab := t_tab('Manager','Client','Absence');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'REJECTION_REASON', v(i), v(i) || '-driven rejection', 'Approval', i * 10 FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'REJECTION_REASON' AND lookup_code = v(i));
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [4/11] unbilled_reason
PROMPT ============================================================

-- 'Billing Loss' is SELECTABLE='N': it is the automatic shortfall reason and is
-- never editable (RULE-009 / FLD-015).
DECLARE
  TYPE t_row IS RECORD (c VARCHAR2(60), m VARCHAR2(200), s VARCHAR2(1), o NUMBER);
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('Onboarding',     'Onboarding (non-billable)',        'Y', 10),
    t_row('Training',       'Training (non-billable)',          'Y', 20),
    t_row('Travel',         'Travel (non-billable)',            'Y', 30),
    -- Code left as 'Client Holiday'. The functional owner wrote "customer
    -- holiday" (10-Aug-2026) and that is the same bucket, but this VALUE is
    -- what OC_TS_ENTRY.UNBILLED_REASON stores and what the matching common
    -- task is called (RULE-002: the reason IS the task), so renaming it is a
    -- data migration plus a task rename, not a label change. The wording is
    -- carried in the meaning instead. Confirm before renaming the code.
    t_row('Client Holiday', 'Customer site closed (non-billable)','Y', 40),
    -- The fifth SELECTABLE reason, held open deliberately (functional owner,
    -- 10-Aug-2026: "Travel, training, onboarding, customer holiday, last one is
    -- open for future use"). Seeded rather than left absent so the screen shows
    -- five buckets from day one and adding the real reason is a rename, not a
    -- release.
    t_row('Other',          'Reserved - name this before use',  'Y', 50),
    -- NOT one of the five. Billing Loss is the automatic RULE-009 shortfall,
    -- computed rather than chosen, which is why SELECTABLE is 'N'. Absence is
    -- likewise not an unbilled reason - leave is its own row from HR (RULE-008).
    t_row('Billing Loss',   'Auto shortfall - non-editable',    'N', 60));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note,
                                selectable, sort_order)
    SELECT 'UNBILLED_REASON', v(i).c, v(i).m, 'Time entry', v(i).s, v(i).o FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'UNBILLED_REASON' AND lookup_code = v(i).c);
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [5/11] shift_type, accrual_entry_type, and the small dictionaries
PROMPT ============================================================

DECLARE
  PROCEDURE seed(p_type VARCHAR2, p_code VARCHAR2, p_meaning VARCHAR2,
                 p_note VARCHAR2, p_order NUMBER) IS
  BEGIN
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT p_type, p_code, p_meaning, p_note, p_order FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = p_type AND lookup_code = p_code);
  END;
BEGIN
  -- SHIFT_TYPE is deliberately NOT seeded.
  --
  -- Shifts, workday patterns, work schedules and the calendar are all Fusion
  -- data (RA-005). This dictionary used to seed 'Regular / Night / Early /
  -- Split', which matches nothing in Fusion — the real categories on
  -- HTS_SHIFTS_VL.SHIFT_CATEGORY are ORA_HTS_SHIFT_DAY, ORA_HTS_SHIFT_NIGHT and
  -- customer-specific codes such as GSE_HTS_SHIFT_24HR. Invented codes in a
  -- lookup table are worse than no codes: they read as authoritative and they
  -- would never join to a real shift.
  --
  -- Nothing consumed it either. The app resolves a day's shift from
  -- OC_TIME_CALENDAR.SHIFT_CODE (OC_TIME_PKG.resolve_day), which the Fusion sync
  -- fills — the type is display metadata carried alongside, not a validation
  -- list. See integration/bip: SHIFTS, WORK_PATTERNS, WORK_SCHEDULES,
  -- WORKER_SHIFTS.

  -- accrual_entry_type (INT-014 ENTRY_TYPE)
  seed('ACCRUAL_ENTRY_TYPE','Actual',
       'Actual submitted hours','Accrual table ENTRY_TYPE',10);
  seed('ACCRUAL_ENTRY_TYPE','Default',
       'Auto-defaulted hours (missed cut-off)','Accrual table ENTRY_TYPE',20);
  seed('ACCRUAL_ENTRY_TYPE','Reversal',
       'Reversal (-) of prior entry (retro / default correction)','Accrual table ENTRY_TYPE',30);
  seed('ACCRUAL_ENTRY_TYPE','Adjustment',
       'Re-post (+) to the corrected project/task/day','Accrual table ENTRY_TYPE',40);

  -- cutoff_type
  seed('CUTOFF_TYPE','Weekly',  'Timesheet weekly cut-off','Period Definition',10);
  seed('CUTOFF_TYPE','Delivery','Manager approve by',      'Period Definition',20);
  seed('CUTOFF_TYPE','Finance', 'Finance cut-off',         'Period Definition',30);
  seed('CUTOFF_TYPE','Book',    'Book closure',            'Period Definition',40);
  seed('CUTOFF_TYPE','MEC',     'Month-end close',         'Period Definition',50);
  seed('CUTOFF_TYPE','Payroll', 'Payroll cut-off',         'Period Definition',60);
  seed('CUTOFF_TYPE','Client',  'Client cut-off (MSA; SOW overrides)','Period Definition',70);

  -- period_status
  seed('PERIOD_STATUS','Open',  'Period open (one at a time)','Period Control',10);
  seed('PERIOD_STATUS','Closed','Period closed',              'Period Control',20);

  -- billing_type
  seed('BILLING_TYPE','Billable',    'Billable time',    'Time',10);
  seed('BILLING_TYPE','Non-billable','Non-billable time','Time',20);

  -- project_model (revenue models)
  seed('PROJECT_MODEL','T&M',      'Time & Material',      'Projects',10);
  seed('PROJECT_MODEL','FCP',      'Fixed Capacity',       'Projects',20);
  seed('PROJECT_MODEL','Milestone','Milestone-based',      'Projects',30);

  -- project_type
  seed('PROJECT_TYPE','Billable',
       'Employee''s own project; log common tasks in-project','Projects',10);
  seed('PROJECT_TYPE','Organization',
       'Common project assigned to ALL employees; non-billable staff log here','Projects (PRJ-ORG)',20);

  -- calendar_precedence (single informational row rendered on PAGE-009)
  seed('CALENDAR_PRECEDENCE','Shift > Client > Project > Corporate',
       'Override order','Calendar (BRD 4.1)',10);

  -- access_role
  seed('ACCESS_ROLE','ROLE_TIME_EMPLOYEE',  'Employee',  'Personas',10);
  seed('ACCESS_ROLE','ROLE_TIME_CONTRACTOR','Contractor','Personas',20);
  seed('ACCESS_ROLE','ROLE_TIME_MANAGER',   'Manager',   'Personas',30);
  seed('ACCESS_ROLE','ROLE_TIME_ADMIN',     'Admin',     'Personas',40);
  seed('ACCESS_ROLE','ROLE_TIME_NONE',      'None',      'Personas',50);

  DBMS_OUTPUT.PUT_LINE('small dictionaries seeded.');
END;
/

PROMPT ============================================================
PROMPT [6/11] INTEGRATION — PAGE-012 reference catalogue
PROMPT ============================================================

-- MEANING is a pipe-delimited quad that V_OC_TIME_INTEGRATION splits into
-- FLD-110..FLD-113: fusion_source | object_usage | rest_resource | load_pattern
-- LOOKUP_CODE is 'INT-xxx|Area'.
DECLARE
  PROCEDURE seed(p_code VARCHAR2, p_meaning VARCHAR2, p_note VARCHAR2, p_order NUMBER) IS
  BEGIN
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'INTEGRATION', p_code, p_meaning, p_note, p_order FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'INTEGRATION' AND lookup_code = p_code);
  END;
BEGIN
  seed('INT-001|Prepopulate',
       'Fusion HCM|Worker & assignment master|/hcmRestApi/../workers|Incremental upsert on PersonNumber',
       'Use workers (not emps) for contingent/terminated. PersonNumber->PersonId hop.', 10);
  seed('INT-002|Prepopulate',
       'Fusion PPM|WBS tasks - the chargeable COLUMNS of the grid|/fscmRestApi/../projects/{ProjectId}/child/Tasks|Incremental upsert on task id',
       'Project x WBS task.', 20);
  seed('INT-003|Prepopulate',
       'Fusion PPM|Project resource assignments - what each employee can charge to|/fscmRestApi/../projectResourceAssignments|Incremental upsert on assignment id',
       'Combine with Tasks to build the grid.', 30);
  seed('INT-004|Prepopulate',
       'Fusion HCM|Work schedules - which days & expected hours|/hcmRestApi/../timeRecordGroups?groupType=Schedule|Scheduled sync',
       'Confirm read path via /describe; scheduleRequests may be write-only.', 40);
  seed('INT-005|Prepopulate',
       'Fusion HCM|Org / absence calendars - holidays & working patterns|/hcmRestApi/../absenceCalendars|Scheduled sync',
       'Needed only if the app computes expected hours itself.', 50);
  seed('INT-006|Prepopulate',
       'Fusion HCM|Approved absences so employees do not double-enter|/hcmRestApi/../absences|Incremental by personId + startDate',
       'Feeds Leave rows & Leave-Loss. Leave is HR-sourced, not selectable.', 60);
  seed('INT-007|Push',
       'Fusion OTL (HCM)|SYSTEM OF RECORD - push approved time|/hcmRestApi/../timeRecordEventRequests|POST processMode TIME_SUBMIT',
       'Primary surface. OTL then feeds Project Costing & Payroll natively.', 70);
  seed('INT-008|Readback',
       'Fusion OTL (HCM)|Statuses / messages / attributes back from OTL|/hcmRestApi/../timeRecordGroups (+ timeRecords, timeAttributes)|GET by personNumber & date range',
       'Reconciliation read-back.', 80);
  seed('INT-009|Push',
       'Fusion OTL (HCM)|Mark entries transferred after a consumer takes the data|/hcmRestApi/../statusChangeRequests|POST consumerCode e.g. PYR',
       'Status reconcile.', 90);
  seed('INT-010|Audit',
       'Fusion PPM|Project costing - auto-populated once OTL is interfaced|/fscmRestApi/../projectCosts, /projectExpenditureBatches|GET only (no external create)',
       'Query/audit only.', 100);
  seed('INT-011|Reference',
       'Fusion HCM|Payroll reference / validation|/hcmRestApi/../payrollRelationships/../payrollAssignments|GET reference',
       'Payroll consumes via OTL extract/load, not a direct write.', 110);
  seed('INT-012|Audit',
       'Fusion Financials|AR / GL audit visibility|/fscmRestApi/../receivablesInvoices, /journalBatches/child/journalHeaders|GET audit',
       'Confirms approved time reached billing/GL.', 120);
  seed('INT-013|Investigate',
       'Fusion Enterprise Contracts|CLM - NOT a direct time consumer|(contracts / project billing config)|GET (investigate)',
       'Contract-billing terms live in Projects/Project Billing.', 130);
  seed('INT-014|Accrual',
       'O2C Accrual (this platform)|Consolidated timesheet + day-wise adjustments|ACCRUAL.XX_O2C_TIMESHEET_ACCRUAL_IF|Interface table filled on confirm; accrual PULLS',
       'Manager-confirmed months only. Default-hour corrections post as adjustments.', 140);
  seed('INT-015|Persistence',
       'O2C Time (ATP)|The app''s own transactional store|ORDS oc.time / oc.time.approval / oc.time.admin|Bidirectional REST',
       'Harden anonymous -> key/OAuth for PROD (RA-002).', 150);
  DBMS_OUTPUT.PUT_LINE('integration catalogue seeded.');
END;
/

PROMPT ============================================================
PROMPT [7/11] OC_TIME_TASK — common non-billable tasks
PROMPT ============================================================

-- These four appear in EVERY project and in the Organization project
-- (V_OC_TS_TASK_LOV cross-joins them). 'Leave' is seeded too but with
-- SELECTABLE_FLAG='N' so it can hold HR-sourced absence hours while never
-- appearing in the employee LOV (RULE-008).
DECLARE
  PROCEDURE seed(p_code VARCHAR2, p_name VARCHAR2, p_sel VARCHAR2, p_order NUMBER) IS
  BEGIN
    INSERT INTO oc_time_task (project_id, task_code, task_name, task_type,
                              billable_type, unbilled_reason, selectable_flag,
                              sort_order, created_by)
    SELECT NULL, p_code, p_name, 'COMMON', 'Non-billable', p_name, p_sel,
           p_order, 'SEED'
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_task
                        WHERE task_type = 'COMMON'
                          AND UPPER(task_code) = UPPER(p_code));
  END;
BEGIN
  seed('ONBOARDING',     'Onboarding',     'Y', 10);
  seed('TRAINING',       'Training',       'Y', 20);
  seed('TRAVEL',         'Travel',         'Y', 30);
  seed('CLIENT_HOLIDAY', 'Client Holiday', 'Y', 40);
  seed('LEAVE',          'Leave',          'N', 50);   -- HR-sourced only
  seed('BILLING_LOSS',   'Billing Loss',   'N', 60);   -- automatic shortfall
  DBMS_OUTPUT.PUT_LINE('common tasks seeded.');
END;
/

PROMPT ============================================================
PROMPT [8/11] OC_TIME_PROJECT — Organization (Non-Billable) project
PROMPT ============================================================

BEGIN
  INSERT INTO oc_time_project (
    project_number, project_name, project_type, revenue_model,
    leave_loss_flag, status, created_by)
  SELECT 'PRJ-ORG', 'Organization (Non-Billable)', 'Organization', NULL,
         'N', 'Active', 'SEED'
    FROM dual
   WHERE NOT EXISTS (SELECT 1 FROM oc_time_project WHERE project_number = 'PRJ-ORG');
  DBMS_OUTPUT.PUT_LINE('PRJ-ORG seeded (' || SQL%ROWCOUNT || ' row).');
END;
/

PROMPT ============================================================
PROMPT [9/11] OC_TIME_CONFIG — business configuration
PROMPT ============================================================

DECLARE
  PROCEDURE seed(p_name VARCHAR2, p_type VARCHAR2, p_value VARCHAR2, p_desc VARCHAR2) IS
  BEGIN
    INSERT INTO oc_time_config (config_name, config_type, config_value, description, created_by)
    SELECT p_name, p_type, p_value, p_desc, 'SEED' FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_config
                        WHERE config_name = p_name AND scope_key = 'GLOBAL');
  END;
BEGIN
  seed('weeklyCutoffDayTime',   'business',    'Monday 17:00',
       'CFG-010 Timesheet cut-off; the defaulting job runs in base-location local time.');
  seed('backdatingWindowMonths','business',    '3',
       'CFG-011 Adjustment / backdated Project-WBS window (BRD 4.2.1).');
  seed('salaryHoldReleaseDays', 'business',    '60',
       'CFG-012 Days an employee/contractor can resubmit a defaulted timesheet.');
  seed('standardHoursSource',   'business',    'HCM/Corporate by country',
       'CFG-013 Standard hours by country of work.');
  seed('apiTimeoutMs',          'timeout',     '8000',
       'CFG-014 Default REST timeout.');
  seed('featureWeekendEditable','feature_flag','true',
       'CFG-015 Sat/Sun editable, default 0 (RULE-012).');
  seed('contractorResubmitDays','business',    '60',
       'FLD-087 Days a contractor can resubmit a defaulted timesheet.');
  seed('maxClientDocBytes',     'business',    '26214400',
       'Security PAGE-002 attachment policy: 25MB ceiling.');
  -- POET's E. Configuration rather than a per-task value, and that is a finding
  -- rather than a shortcut: expenditure type is not an attribute of the task in
  -- Fusion, it comes from transaction controls — and PJF_TXN_CONTROLS does not
  -- exist on this pod (verified 02-Aug-2026; only PJC_TXN_CONTROLS_STAGE, a
  -- staging table). So there is nothing per task to read.
  --
  -- 'Regular Labor' is one of 30 types on the pod carrying UOM = HOURS, which is
  -- the constraint that matters: several types named '...Labor' are DOLLARS
  -- (Craft Labor Straight Time, Consultant Labor...) and would be wrong for a
  -- timesheet. Run the EXP_TYPES extract to see the legal values before
  -- changing this.
  seed('defaultExpenditureType','business',    'Regular Labor',
       'POET expenditure type for the OTL push (INT-007). Must be a Fusion '
       || 'expenditure type with UOM = HOURS; see the EXP_TYPES extract.');
  DBMS_OUTPUT.PUT_LINE('config seeded.');
END;
/

PROMPT ============================================================
PROMPT [10/11] OC_TIME_PERIOD — the current and next period
PROMPT ============================================================

-- Bootstrap so the app is usable immediately: the current month Open and the
-- next month Closed. RULE-017 guarantees only one Open row, so the guard also
-- protects against seeding a second Open period into a live environment.
DECLARE
  v_open NUMBER;

  PROCEDURE seed_period(p_base DATE, p_status VARCHAR2) IS
    v_start DATE := TRUNC(p_base,'MM');
    v_end   DATE := LAST_DAY(TRUNC(p_base,'MM'));
    v_name  VARCHAR2(30) := UPPER(TO_CHAR(v_start,'MON-YYYY'));
  BEGIN
    INSERT INTO oc_time_period (
      period_name, period_year, period_month, status,
      start_date, end_date, accounting_date,
      ts_cutoff_day, ts_cutoff_time,
      delivery_cutoff, finance_cutoff, book_closure, mec_close,
      client_cutoff, payroll_cutoff,
      advance_close, contractor_resubmit_days, hold_release_days,
      adjustment_months, backdated_months, created_by)
    SELECT v_name,
           EXTRACT(YEAR FROM v_start), EXTRACT(MONTH FROM v_start), p_status,
           v_start, v_end, v_end,
           'Monday', '17:00',
           v_end + 3,     -- delivery cut-off
           v_end + 5,     -- finance cut-off
           v_end + 7,     -- book closure
           v_end + 8,     -- MEC close
           v_end + 10,    -- client cut-off
           v_end + 2,     -- payroll cut-off
           'N', 60, 60, 3, 3, 'SEED'
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_period WHERE period_name = v_name);
  END;
BEGIN
  SELECT COUNT(*) INTO v_open FROM oc_time_period WHERE status = 'Open';

  -- Only claim 'Open' if nothing is open yet. Kept after RULE-017 was relaxed
  -- (04-Aug-2026): several months MAY now be open, but a seed run should not
  -- decide that — opening a month is a deliberate act, see 13_open_periods.sql.
  seed_period(SYSDATE, CASE WHEN v_open = 0 THEN 'Open' ELSE 'Closed' END);
  seed_period(ADD_MONTHS(SYSDATE, 1),  'Closed');
  seed_period(ADD_MONTHS(SYSDATE, -1), 'Closed');
  DBMS_OUTPUT.PUT_LINE('periods seeded.');
END;
/

PROMPT ============================================================
PROMPT [11/11] Corporate calendar — NOT seeded (sourced from Fusion)
PROMPT ============================================================

-- Deliberately empty.
--
-- Working days, shifts, work patterns and holidays are Fusion data (RA-005:
-- "calendars are sourced from Oracle Fusion; no calendar authoring in the Time
-- module"). Seeding a Mon-Fri baseline here would put rows in the CORPORATE
-- layer that look authoritative but are invented, and because the loader
-- upserts on (layer, scope_key, cal_date) those invented rows would then block
-- the real ones for the same days.
--
-- The four Fusion sources and how they arrive:
--
--   work shift      HTS_SHIFTS_VL               -> SHIFTS extract
--   work pattern    HTS_WORK_PATTERNS_VL        -> WORK_PATTERNS extract
--                   + HTS_WORK_PATTERN_SHIFTS
--   work schedule   PER_SCHEDULE_ASSIGNMENTS    -> WORK_SCHEDULES extract
--   work calendar   PER_CALENDAR_EVENTS         -> CALENDAR extract
--
--   resolved day    HTS_SCHEDULE_SHIFTS_VL      -> WORKER_SHIFTS extract
--                   (person x date x shift, already expanded by Fusion)
--
-- Load them with integration/bip/run_extract.py, then
--   POST /oc/time/admin/calendar/sync/{CORPORATE|PROJECT|CLIENT|SHIFT}
--
-- For a local dev database with no Fusion behind it, 90_test_seed.sql has a
-- Mon-Fri fallback. It is test data and is not part of this installer.

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM oc_time_calendar;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'calendar: empty - load from Fusion before running population, or run '
      || '90_test_seed.sql for a dev fallback.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('calendar: ' || v_n || ' day(s) already present.');
  END IF;
END;
/

COMMIT;

PROMPT
PROMPT ============================================================
PROMPT time/10_seed complete.
PROMPT ============================================================
--== END 10_seed.sql ==

-- ── Sign-in ──────────────────────────────────────────────────
-- After 09/10 because V_OC_TIME_SIGNIN reads OC_TIME_WORKER, OC_TIME_ALLOCATION
-- and OC_TIME_PERIOD; before the ORDS surface, which calls its hash function.
PROMPT >>> 11 auth (OC_TIME_USER, OC_TIME_SESSION, hash, sign-in view)

--==============================================================
-- BEGIN 11_auth.sql
--==============================================================
--==============================================================
-- time/11_auth.sql
-- O2C Timesheet Module — application sign-in
--
-- Matches the O2C main application's auth model so the two behave identically
-- and credentials can be aligned later: same SHA-256 over
-- LOWER(email) || ':' || password, same 64-hex random session token, same
-- Invited / Active / Inactive lifecycle.
--
-- Three access levels, as specified:
--   resource   ROLE_TIME_EMPLOYEE | ROLE_TIME_CONTRACTOR
--   manager    ROLE_TIME_MANAGER
--   admin      ROLE_TIME_ADMIN            (the common admin login)
--
-- The role is NOT duplicated here. It is read from OC_TIME_WORKER.APP_ROLE,
-- which already drives the menu (RULE-022) and carries the manager hierarchy
-- (RULE-015). Two copies of a role would eventually disagree, and the one the
-- approval rules read is the worker's.
--
-- APP_ROLE on OC_TIME_USER is an OVERRIDE, normally null. It exists for the
-- common admin, who is a real login but not necessarily a worker in HCM and so
-- may have no OC_TIME_WORKER row to take a role from.
--
-- NO GRANTS BEYOND THE ORDINARY ONES. Nothing here needs DBMS_CRYPTO — see the
-- note on oc_time_hash_password and oc_time_new_token below, and §  SECURITY
-- DEBT at the foot of this file. That was a deliberate decision on
-- 01-Aug-2026 to avoid a DBA round trip; the hash side costs nothing, the token
-- side is weaker and is written down as debt rather than hidden.
--
-- Requirement refs: PER-001..005, RULE-022, NFR-005, Security sheet (JWT/RBAC)
-- Idempotent. Depends on: time/02_time_master.sql
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/5] OC_TIME_USER — one login per person
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_user (
      USER_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EMPLOYEE_ID    VARCHAR2(50 CHAR),
      EMAIL          VARCHAR2(255 CHAR) NOT NULL,
      PASSWORD_HASH  VARCHAR2(128 CHAR),
      FULL_NAME      VARCHAR2(200 CHAR) NOT NULL,
      APP_ROLE       VARCHAR2(30 CHAR),
      STATUS         VARCHAR2(20 CHAR) DEFAULT 'Invited' NOT NULL,
      LAST_LOGIN_ON  TIMESTAMP,
      FAILED_COUNT   NUMBER(3) DEFAULT 0 NOT NULL,
      CREATED_BY     VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY     VARCHAR2(100),
      UPDATED_ON     TIMESTAMP,
      CONSTRAINT uk_oc_tu_email  UNIQUE (email),
      CONSTRAINT uk_oc_tu_emp    UNIQUE (employee_id),
      CONSTRAINT chk_oc_tu_status CHECK (status IN ('Invited','Active','Inactive')),
      CONSTRAINT chk_oc_tu_role  CHECK (app_role IS NULL OR app_role IN
        ('ROLE_TIME_EMPLOYEE','ROLE_TIME_CONTRACTOR','ROLE_TIME_MANAGER',
         'ROLE_TIME_ADMIN','ROLE_TIME_NONE')),
      -- An Active account with no hash could never authenticate, so the state is
      -- made unrepresentable rather than left to fail at the login attempt.
      CONSTRAINT chk_oc_tu_hash  CHECK (status <> 'Active' OR password_hash IS NOT NULL)
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_USER created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_USER already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tu_status ON oc_time_user(status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [2/5] OC_TIME_SESSION — bearer tokens
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_session (
      SESSION_ID   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      USER_ID      NUMBER            NOT NULL,
      TOKEN        VARCHAR2(64 CHAR) NOT NULL,
      CREATED_ON   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      EXPIRES_ON   TIMESTAMP         NOT NULL,
      LAST_SEEN_ON TIMESTAMP,
      CLIENT_INFO  VARCHAR2(400 CHAR),
      CONSTRAINT uk_oc_tsess_token UNIQUE (token),
      CONSTRAINT fk_oc_tsess_user  FOREIGN KEY (user_id)
        REFERENCES oc_time_user(user_id) ON DELETE CASCADE
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SESSION created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SESSION already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE
  'CREATE INDEX ix_oc_tsess_expiry ON oc_time_session(expires_on)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/5] OC_TIME_HASH_PASSWORD
PROMPT ============================================================

-- Deliberately identical to the main application's oc_hash_password: SHA-256
-- over LOWER(email) || ':' || password. The email is the salt, so two people
-- with the same password do not share a hash, and a hash lifted from one row is
-- useless against another.
--
-- Same algorithm as the main app on purpose - if the two user stores are ever
-- merged, the hashes are directly comparable and nobody has to reset a password.
--
-- STANDARD_HASH, not DBMS_CRYPTO.HASH. This is a pure substitution, not a
-- compromise: both hash the same bytes with the same algorithm and return the
-- same 64 hex characters, so a hash written by either function verifies against
-- the other and the main app's stored hashes still compare directly. The only
-- difference is that STANDARD_HASH is a SQL built-in needing no grant, while
-- DBMS_CRYPTO is a SYS package that is not granted to PUBLIC.
--
--   RAWTOHEX(DBMS_CRYPTO.HASH(UTL_RAW.CAST_TO_RAW(s), DBMS_CRYPTO.HASH_SH256))
--   = RAWTOHEX(STANDARD_HASH(s, 'SHA256'))
--
-- Deterministic, so it is fine in the SQL of a MERGE (90_test_seed.sql does
-- exactly that) without a DETERMINISTIC hint being load-bearing.
--
-- STANDARD_HASH is a SQL function, NOT a PL/SQL one, so it cannot appear in a
-- PL/SQL expression — `RETURN RAWTOHEX(STANDARD_HASH(...))` fails to compile
-- with PLS-00201 "identifier must be declared". It has to be reached through a
-- SQL statement, hence SELECT ... INTO ... FROM dual. Same family as SQLERRM
-- (SQL-only in reverse) and EXISTS.
CREATE OR REPLACE FUNCTION oc_time_hash_password(
  p_email    VARCHAR2,
  p_password VARCHAR2
) RETURN VARCHAR2 DETERMINISTIC
IS
  v_hash VARCHAR2(128 CHAR);
BEGIN
  SELECT RAWTOHEX(
           STANDARD_HASH(LOWER(p_email) || ':' || p_password, 'SHA256'))
    INTO v_hash
    FROM dual;
  RETURN v_hash;
END oc_time_hash_password;
/

PROMPT ============================================================
PROMPT [4/5] OC_TIME_NEW_TOKEN — session token generator
PROMPT ============================================================

-- Returns a 64-character hex session token, the same shape the main
-- application's oc_auth issues, so nothing downstream changes.
--
-- ─────────────────────────────────────────────────────────────
-- THIS IS THE WEAK PART. Read before changing anything here.
-- ─────────────────────────────────────────────────────────────
--
-- The right way to make a bearer token is DBMS_CRYPTO.RANDOMBYTES(32) — a
-- cryptographically secure generator, 256 bits of real entropy. It is not used
-- because DBMS_CRYPTO needs a grant we chose not to ask for (01-Aug-2026).
--
-- What is here instead mixes the unpredictability that IS available without a
-- grant, then hashes it so the output is uniform and the inputs cannot be read
-- back off the token:
--
--   SYS_GUID()        unique, but on many platforms partly derived from host,
--                     process and time — so not unpredictable on its own
--   DBMS_RANDOM       a PRNG, not a CSPRNG; seeded from time and session
--   SYSTIMESTAMP      nanosecond precision, but an attacker can guess the
--                     rough window a session was created in
--
-- Hashing does NOT add entropy. It only spreads what the inputs have across all
-- 256 bits and hides their structure. So a determined attacker who knows
-- roughly when a session began has a smaller search space than 2^256. In
-- practice guessing a live token is still very hard; cryptographically, it is
-- not a guarantee.
--
-- What limits the damage meanwhile: tokens expire in 24 hours, are deleted on
-- logout and on any password change, and every session row is per-user, so a
-- guessed token buys one person's timesheet for less than a day.
--
-- TO PUT THIS RIGHT — one line, once the grant exists:
--
--   GRANT EXECUTE ON DBMS_CRYPTO TO O2C_TIME;
--
--   RETURN RAWTOHEX(DBMS_CRYPTO.RANDOMBYTES(32));
--
-- Existing sessions keep working; the column and the length do not change.
-- Do this before PROD (NFR-005, Security sheet).
-- As with oc_time_hash_password: STANDARD_HASH is SQL-only, so it is reached
-- through SELECT ... FROM dual rather than called directly.
CREATE OR REPLACE FUNCTION oc_time_new_token RETURN VARCHAR2
IS
  v_seed  VARCHAR2(400 CHAR);
  v_token VARCHAR2(64 CHAR);
BEGIN
  v_seed := RAWTOHEX(SYS_GUID())
         || RAWTOHEX(SYS_GUID())
         || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF9')
         || DBMS_RANDOM.STRING('X', 32);

  SELECT RAWTOHEX(STANDARD_HASH(v_seed, 'SHA256'))
    INTO v_token
    FROM dual;
  RETURN v_token;
END oc_time_new_token;
/

PROMPT ============================================================
PROMPT [5/5] V_OC_TIME_SIGNIN — the resolved identity
PROMPT ============================================================

-- What a valid token resolves to. One place decides the effective role, so the
-- login response, the menu and every RBAC check cannot drift apart.
--
-- EFFECTIVE_ROLE: the user override if present (the common admin, who may have
-- no worker row), otherwise the worker's APP_ROLE, otherwise no access. A login
-- that resolves to nothing is ROLE_TIME_NONE rather than an error - the shell
-- already renders an empty menu with an explanation for that.
CREATE OR REPLACE VIEW v_oc_time_signin AS
SELECT s.token,
       s.expires_on,
       u.user_id,
       u.status                            AS user_status,
       NVL(u.employee_id, w.employee_id)   AS employee_id,
       NVL(w.employee_name, u.full_name)   AS employee_name,
       u.email,
       NVL(u.app_role, NVL(w.app_role, 'ROLE_TIME_NONE')) AS effective_role,
       w.worker_type,
       w.manager_emp_id,
       w.base_country,
       w.deputed_country,
       w.std_hours_per_day,
       w.status                            AS worker_status,
       (SELECT NVL(SUM(al.alloc_pct),0)
          FROM oc_time_allocation al
         WHERE al.employee_id = NVL(u.employee_id, w.employee_id)
           AND al.status = 'Active')       AS total_alloc_pct,
       -- NOT oc_time_pkg.get_open_period_id: that raises when nothing is Open,
       -- and sign-in must never depend on a period existing.
       (SELECT period_id FROM (
         SELECT p.period_id
           FROM oc_time_period p
          WHERE p.status = 'Open'
          ORDER BY CASE WHEN TRUNC(SYSDATE)
             BETWEEN p.start_date AND p.end_date
                THEN 0 ELSE 1 END, p.start_date)
        WHERE ROWNUM = 1) AS open_period_id
  FROM oc_time_session s
  JOIN oc_time_user    u ON u.user_id = s.user_id
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 WHERE s.expires_on > SYSTIMESTAMP
   AND u.status = 'Active';

PROMPT
PROMPT ============================================================
PROMPT time/11_auth complete.
PROMPT ============================================================
--== END 11_auth.sql ==


--==============================================================
-- BEGIN 12_revoke.sql
--==============================================================
-- ============================================================
-- 12_revoke.sql — allow a submitted week to be pulled back
-- ============================================================
-- An employee who submits by mistake currently has no way out: the week is
-- frozen the moment it is Submitted, and only a manager rejection could move
-- it. That makes the manager do administrative work for someone else's typo,
-- and it puts a rejection in the audit trail that never happened.
--
-- Revoke returns a Submitted week to 'Not yet submitted' so the employee can
-- correct and resubmit. It stops at Approved: once the manager has acted the
-- decision is theirs to undo, which is a rejection (send-back), not a revoke.
--
-- Idempotent and re-runnable, like every other script here. Order against
-- 09_pkg_oc_time.sql does not matter for compilation — the package only writes
-- 'Revoke' at run time — but BOTH must be run before the button will work, or
-- the first revoke fails on CHK_OC_TSA_ACTION.
-- ============================================================

SET DEFINE OFF

PROMPT ============================================================
PROMPT [1/1] OC_TS_APPROVAL — add 'Revoke' to the action domain
PROMPT ============================================================

-- CHK_OC_TSA_ACTION is created inline by 04_approval_audit.sql, which is
-- skipped once the table exists (ORA-00955), so the domain has to be widened
-- here rather than by editing the CREATE TABLE.
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSA_ACTION';

  IF v_count > 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_approval DROP CONSTRAINT chk_oc_tsa_action';
  END IF;

  EXECUTE IMMEDIATE q'~
    ALTER TABLE oc_ts_approval ADD CONSTRAINT chk_oc_tsa_action CHECK (action IN
      ('Approve','Reject','Override','AdvanceApprove','Confirm',
       'Submit','Resubmit','Default','Release','Revoke'))~';

  DBMS_OUTPUT.PUT_LINE('CHK_OC_TSA_ACTION now allows Revoke.');
EXCEPTION
  WHEN OTHERS THEN
    -- A row already violating the widened domain is impossible (it is a
    -- superset), so anything here is worth seeing rather than swallowing.
    DBMS_OUTPUT.PUT_LINE('CHK_OC_TSA_ACTION: ' || SQLERRM);
    RAISE;
END;
/

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN search_condition_vc FORMAT A78
SELECT search_condition_vc
  FROM user_constraints
 WHERE constraint_name = 'CHK_OC_TSA_ACTION';
--== END 12_revoke.sql ==

-- ── Post-baseline changes, in the order they were decided ────
-- 13 was missing from this installer until 09-Aug-2026, so a fresh schema came
-- up still enforcing one-open-period while the running environments did not —
-- the two would have diverged silently on the next rebuild.
PROMPT >>> 13 several periods may be Open (RULE-017 relaxed)

--==============================================================
-- BEGIN 13_open_periods.sql
--==============================================================
-- ============================================================
-- 13_open_periods.sql — hold JUL-2026 and AUG-2026 open together
-- ============================================================
-- RULE-017 ("only one period may be Open at a time") is RELAXED as of
-- 04-Aug-2026, by decision. This script carries that change:
--
--   1. drop UK_OC_TP_SINGLE_OPEN       the unique index that enforced the rule
--   2. open JUL-2026 and AUG-2026      both, together
--   3. extend July's delivery cut-off  or July is Open but still not editable
--   4. populate AUG-2026               it has no weeks at all yet
--
-- RUN db/09_pkg_oc_time.sql FIRST, or step 2 leaves the database in a state the
-- old package cannot read: get_open_period_id was a bare SELECT INTO and raises
-- TOO_MANY_ROWS the moment a second month is Open. The new version orders and
-- takes one row, and populate_daily now resolves the period from its action
-- date instead of asking which month is "the" open one.
--
-- What relaxing the rule costs, on the record:
--   * "the open period" is now a choice, not a fact. get_open_period_id picks
--     the month containing today, else the earliest open one.
--   * run_accrual_top_up posts a late adjustment into that chosen month. With
--     both open it picks August while August contains today — confirm that is
--     intended before running a top-up.
--   * the sign-in views resolve openPeriodId the same way, so the landing month
--     is stable rather than whichever row the optimiser happened to return.
--
-- Idempotent and re-runnable. Nothing is deleted; population skips entries that
-- already exist.
-- ============================================================

SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] Drop UK_OC_TP_SINGLE_OPEN — RULE-017 relaxed
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX uk_oc_tp_single_open';
  DBMS_OUTPUT.PUT_LINE('UK_OC_TP_SINGLE_OPEN dropped.');
EXCEPTION
  WHEN OTHERS THEN
    -- ORA-01418: index does not exist, so a re-run is a no-op.
    IF SQLCODE = -1418 THEN
      DBMS_OUTPUT.PUT_LINE('UK_OC_TP_SINGLE_OPEN already absent.');
    ELSE
      RAISE;
    END IF;
END;
/

PROMPT ============================================================
PROMPT [2/4] Open JUL-2026 and AUG-2026
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_period
     SET status = 'Open', updated_by = 'ADMIN'
   WHERE period_year = 2026
     AND period_month IN (7, 8)
     AND status <> 'Open';
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' period(s) moved to Open.');
END;
/

PROMPT ============================================================
PROMPT [3/4] Extend July's delivery cut-off so it is actually editable
PROMPT ============================================================

-- Status alone is not enough. V_OC_TS_MY_PERIODS returns editable_flag = 'N'
-- once TRUNC(SYSDATE) > delivery_cutoff (RULE-007), and July's was 03-Aug-2026
-- — yesterday. Opening July without this leaves it Open and still read-only,
-- which looks exactly like the change not having worked.
--
-- 30-Sep-2026 IS A TESTING DATE, NOT A BUSINESS ONE, and re-running this
-- script will impose it again.
--
-- The real shape (confirmed 10-Aug-2026) is different and matters, because the
-- two cut-offs sit either side of month end:
--
--     payroll cut-off   25-Jul   BEFORE the month has even finished
--     delivery cut-off  ~10-Aug  AFTER it, once managers have had a chance
--
-- So this UPDATE will overwrite a correctly-set July delivery cut-off with
-- 30-Sep. The guard below only skips rows already LATER than 30-Sep, which a
-- real 10-Aug value is not.
--
-- BEFORE RE-RUNNING THE INSTALLER ON AN ENVIRONMENT WITH REAL CUT-OFFS, either
-- change the date here or comment this statement out. Everything else in the
-- installer is idempotent; this one is opinionated.
-- DISABLED 10-Aug-2026. The delivery cut-off is not ours to invent: it comes
-- from the ACCRUAL close calendar, and July's real value is around 10-Aug, not
-- 30-Sep. Leaving this active meant every re-run of the installer silently
-- replaced a correct date with a testing one -- and the guard did not save it,
-- because it only skipped values already LATER than 30-Sep.
--
-- Re-enable only with the real date, or better, set the cut-offs from the
-- accrual calendar and delete this block.
--
-- UPDATE oc_time_period
--    SET delivery_cutoff = DATE '2026-09-30', updated_by = 'ADMIN'
--  WHERE period_year = 2026 AND period_month = 7
--    AND delivery_cutoff < DATE '2026-09-30';
-- COMMIT;

-- Report what the cut-offs actually are, so a July that is Open but read-only
-- is diagnosable rather than mysterious. Editability is delivery-cut-off
-- driven (RULE-007), and salary stopping is payroll-cut-off driven -- the two
-- are different dates and sit either side of month end.
DECLARE
  CURSOR c IS
    SELECT period_name, status,
           TO_CHAR(delivery_cutoff,'DD-Mon-YYYY') AS del,
           TO_CHAR(payroll_cutoff,'DD-Mon-YYYY')  AS pay
      FROM oc_time_period
     WHERE period_year = 2026 AND period_month IN (6, 7, 8)
     ORDER BY period_month;
BEGIN
  DBMS_OUTPUT.PUT_LINE('period    status  delivery      payroll');
  FOR r IN c LOOP
    DBMS_OUTPUT.PUT_LINE(RPAD(r.period_name,10) || RPAD(r.status,8)
      || RPAD(NVL(r.del,'(not set)'),14) || NVL(r.pay,'(not set)'));
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(
    'If delivery is in the past the month is Open and READ-ONLY (RULE-007).');
END;
/

PROMPT ============================================================
PROMPT [4/4] Populate AUG-2026
PROMPT ============================================================

-- ACT-031 / PROC-001. NULL employee = every active allocation. August has zero
-- weeks today, so without this it opens editable but completely empty.
DECLARE
  v_period NUMBER;
  v_job    NUMBER;
  v_weeks  NUMBER;
  v_rows   NUMBER;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period
   WHERE period_year = 2026 AND period_month = 8;

  v_job := oc_time_pkg.populate_month(v_period, NULL, 'ADMIN');
  COMMIT;

  SELECT COUNT(*) INTO v_weeks FROM oc_ts_week WHERE period_id = v_period;
  SELECT COUNT(*) INTO v_rows
    FROM oc_ts_entry e
    JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
   WHERE w.period_id = v_period;

  DBMS_OUTPUT.PUT_LINE('job_run_id ' || v_job || ': ' || v_weeks
                       || ' weeks, ' || v_rows || ' entries.');
END;
/

PROMPT ============================================================
PROMPT Verification — BOTH July and August must read Open and editable Y
PROMPT ============================================================

-- V_OC_TS_MY_PERIODS, not V_OC_TIME_CUTOFFS. Two different views over the same
-- table and it is easy to reach for the wrong one: CUTOFFS (01_time_reference)
-- carries every cut-off DATE, while MY_PERIODS (08_views) is the one that
-- derives period_state, editable_flag and adjustment_allowed — the three
-- columns that say whether a month can be typed into. It is also what
-- getPeriods reads, so this shows exactly what the app will see.
COLUMN period_name  FORMAT A10
COLUMN status       FORMAT A7
COLUMN period_state FORMAT A7
SELECT period_name, status, period_state, editable_flag, adjustment_allowed,
       start_date, delivery_cutoff
  FROM v_oc_ts_my_periods
 ORDER BY period_year, period_month;

SELECT COUNT(*) AS open_periods FROM oc_time_period WHERE status = 'Open';

-- Which month the code will now call "the open period".
SELECT oc_time_pkg.get_open_period_id AS resolved_open_period FROM dual;

SELECT period_id, COUNT(DISTINCT employee_id) AS employees, COUNT(*) AS weeks
  FROM oc_ts_week
 GROUP BY period_id
 ORDER BY period_id;
--== END 13_open_periods.sql ==

PROMPT >>> 14 invoice annexure over the accrual hand-off

--==============================================================
-- BEGIN 14_invoice_annexure.sql
--==============================================================
--==============================================================
-- time/14_invoice_annexure.sql
-- O2C Timesheet Module — invoice annexure over the accrual hand-off
--
-- What goes out WITH the invoice: a project-level summary and the per-person
-- timesheet summary behind it, so the customer can see how the billed hours
-- were arrived at.
--
-- SOURCED FROM XX_O2C_TIMESHEET_ACCRUAL_IF, NOT FROM OC_TS_ENTRY, and that is
-- the whole design. An annexure is attached to an invoice and then never
-- changes. Reading live entries would mean a correction made next month
-- silently rewrites the annexure of an invoice already sent, so the document in
-- the customer's hand and the document the system reprints would disagree with
-- no record of why. The interface rows are written once by confirm_month,
-- carry their CONFIRM_ID, and are exactly what accrual was given — so
-- reprinting an old annexure reproduces it, and the annexure can never claim
-- hours the invoice did not bill. Same reasoning as V_OC_TS_ACCRUAL_EXTRACT:
-- "from the same rows, so the screen can never disagree with the hand-off".
--
-- CONSEQUENCE, and it is intended: a month that has not been confirmed has no
-- annexure. There is nothing to annexe to an invoice for hours nobody has
-- handed over yet.
--
-- Idempotent. Depends on: time/04, time/07
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/2] V_OC_TS_INVOICE_ANNEXURE — per person, per confirmed month
PROMPT ============================================================

-- One row per employee per project per confirmed month: the individual's
-- timesheet reduced to the numbers an invoice needs.
--
-- ACTUALS AND ADJUSTMENTS ARE SEPARATE COLUMNS, not just a net. A reversal
-- carries negative hours (CHK_XX_TSIF_SIGN), so SUM() alone gives the right
-- net and hides the fact that anything was corrected. An annexure has to show
-- the correction: a customer questioning a line needs to see 160 actual less 8
-- reversed, not a bare 152 that matches nothing they were told last month.
CREATE OR REPLACE VIEW v_oc_ts_invoice_annexure AS
SELECT i.confirm_id,
       i.period,
       i.period_year,
       i.period_month,
       i.project_number,
       i.project_name,
       i.customer_name,
       i.revenue_model,
       i.employee_id,
       i.employee_name,
       i.worker_type,
       -- The role TODAY, not the role as billed. The interface does not carry
       -- it, so this is a live join and it will change if the allocation
       -- changes. Named so nobody reads it as historical fact.
       (SELECT MIN(al.client_role)
          FROM oc_time_allocation al
          JOIN oc_time_project pr ON pr.project_id = al.project_id
         WHERE al.employee_id = i.employee_id
           AND pr.project_number = i.project_number) AS current_client_role,
       -- ── as worked ────────────────────────────────────────
       NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                    THEN i.billable_hours END),0)     AS actual_billable_hours,
       NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                    THEN i.non_billable_hours END),0) AS actual_non_billable_hours,
       NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                    THEN i.leave_hours END),0)        AS actual_leave_hours,
       -- ── corrections, shown not hidden ────────────────────
       NVL(SUM(CASE WHEN i.entry_type = 'Reversal'
                    THEN i.billable_hours END),0)     AS reversal_billable_hours,
       NVL(SUM(CASE WHEN i.entry_type = 'Adjustment'
                    THEN i.billable_hours END),0)     AS adjustment_billable_hours,
       -- ── what is actually billed ──────────────────────────
       NVL(SUM(i.billable_hours),0)                   AS net_billable_hours,
       NVL(SUM(i.non_billable_hours),0)               AS net_non_billable_hours,
       NVL(SUM(i.leave_hours),0)                      AS net_leave_hours,
       NVL(SUM(i.billable_hours + i.non_billable_hours + i.leave_hours),0)
                                                      AS net_total_hours,
       -- Days with billable time. COUNT(DISTINCT) because a day can carry
       -- several task lines and must still count once.
       COUNT(DISTINCT CASE WHEN i.billable_hours > 0 THEN i.work_date END)
                                                      AS billable_days,
       COUNT(DISTINCT i.work_date)                    AS days_on_sheet,
       MIN(TO_CHAR(i.work_date,'YYYY-MM-DD'))         AS first_work_date,
       MAX(TO_CHAR(i.work_date,'YYYY-MM-DD'))         AS last_work_date,
       CASE WHEN SUM(CASE WHEN i.entry_type IN ('Reversal','Adjustment')
                          THEN 1 ELSE 0 END) > 0 THEN 'Y' ELSE 'N' END
                                                      AS has_correction_flag,
       c.confirm_type,
       TO_CHAR(c.confirmed_on,'YYYY-MM-DD')           AS confirmed_on,
       c.accrual_status
  FROM xx_o2c_timesheet_accrual_if i
  JOIN oc_ts_month_confirm c ON c.confirm_id = i.confirm_id
 GROUP BY i.confirm_id, i.period, i.period_year, i.period_month,
          i.project_number, i.project_name, i.customer_name, i.revenue_model,
          i.employee_id, i.employee_name, i.worker_type,
          c.confirm_type, c.confirmed_on, c.accrual_status;

PROMPT ============================================================
PROMPT [2/2] V_OC_TS_INVOICE_ANNEXURE_HDR — the project-level summary
PROMPT ============================================================

-- One row per confirmed project-month: the cover sheet the per-person lines
-- add up to.
--
-- Totals are re-aggregated from the interface rather than read from
-- OC_TS_MONTH_CONFIRM's stored columns, deliberately. Those are a snapshot
-- taken by confirm_month, and run_accrual_top_up can add interface rows
-- afterwards for a retro adjustment approved once the month had closed. Reading
-- the rows means the cover sheet always equals the sum of the lines beneath it,
-- which is the one property an annexure cannot be wrong about.
CREATE OR REPLACE VIEW v_oc_ts_invoice_annexure_hdr AS
SELECT c.confirm_id,
       c.project_id,
       a.project_number,
       a.project_name,
       a.customer_name,
       a.revenue_model,
       a.period,
       c.period_year,
       c.period_month,
       COUNT(DISTINCT a.employee_id)                  AS people,
       NVL(SUM(a.actual_billable_hours),0)            AS actual_billable_hours,
       NVL(SUM(a.actual_non_billable_hours),0)        AS actual_non_billable_hours,
       NVL(SUM(a.actual_leave_hours),0)               AS actual_leave_hours,
       NVL(SUM(a.reversal_billable_hours),0)          AS reversal_billable_hours,
       NVL(SUM(a.adjustment_billable_hours),0)        AS adjustment_billable_hours,
       NVL(SUM(a.net_billable_hours),0)               AS net_billable_hours,
       NVL(SUM(a.net_non_billable_hours),0)           AS net_non_billable_hours,
       NVL(SUM(a.net_leave_hours),0)                  AS net_leave_hours,
       NVL(SUM(a.net_total_hours),0)                  AS net_total_hours,
       SUM(CASE WHEN a.has_correction_flag = 'Y' THEN 1 ELSE 0 END)
                                                      AS people_with_corrections,
       -- Leave-loss coverage bills absence hours on an FCP project and travels
       -- with the same invoice (PROC-006). Surfaced here so the cover sheet
       -- reconciles against V_OC_TS_LLC_ANNEXURE instead of the two being
       -- totalled by hand and quietly disagreeing.
       NVL((SELECT SUM(l.covered_billed_hours)
              FROM v_oc_ts_llc_annexure l
             WHERE l.project_id = c.project_id
               AND l.period_id  = c.period_id),0)     AS llc_billed_hours,
       c.confirm_type,
       c.confirmed_by,
       TO_CHAR(c.confirmed_on,'YYYY-MM-DD HH24:MI')   AS confirmed_on,
       c.accrual_status,
       c.otl_status,
       c.partner_status
  FROM oc_ts_month_confirm c
  JOIN v_oc_ts_invoice_annexure a ON a.confirm_id = c.confirm_id
 GROUP BY c.confirm_id, c.project_id, a.project_number, a.project_name,
          a.customer_name, a.revenue_model, a.period, c.period_year,
          c.period_month, c.period_id, c.confirm_type, c.confirmed_by,
          c.confirmed_on, c.accrual_status, c.otl_status, c.partner_status;

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN object_name FORMAT A34
COLUMN status      FORMAT A10

SELECT object_name, status
  FROM user_objects
 WHERE object_type = 'VIEW'
   AND object_name IN ('V_OC_TS_INVOICE_ANNEXURE','V_OC_TS_INVOICE_ANNEXURE_HDR')
 ORDER BY object_name;

-- The property that matters: the cover sheet equals the sum of its lines.
-- Any row returned here is a defect.
COLUMN check_name FORMAT A40
SELECT 'header <> sum of lines' AS check_name, h.confirm_id,
       h.net_total_hours AS header_total,
       (SELECT SUM(a.net_total_hours) FROM v_oc_ts_invoice_annexure a
         WHERE a.confirm_id = h.confirm_id) AS lines_total
  FROM v_oc_ts_invoice_annexure_hdr h
 WHERE h.net_total_hours <> NVL((SELECT SUM(a.net_total_hours)
                                   FROM v_oc_ts_invoice_annexure a
                                  WHERE a.confirm_id = h.confirm_id),0);

PROMPT Done. Two views: _HDR is the cover sheet, the other is one row per person.
--== END 14_invoice_annexure.sql ==

-- 17 before 16: the loader's FK lookup reads PROJECT_NUMBER, which 17 adds.
PROMPT >>> 17 columns the extracts send with nowhere to land

--==============================================================
-- BEGIN 17_sync_column_gaps.sql
--==============================================================
--==============================================================
-- time/17_sync_column_gaps.sql
-- O2C Timesheet Module — the columns the extracts send with nowhere to land
--
-- Measured against real BIP output on 10-Aug-2026: after the alias rename, six
-- reports still emit elements that no target column matches, so the loader
-- silently drops them. Dropping is the right default -- a report carrying an
-- extra element must not error -- but three of these are not droppable:
--
--   TIME_ENTRY_ENABLED  decides whether a project is visible to time entry at
--                       all. Without it every project looks enterable.
--   EXPENDITURE_TYPE    POET's E. Recorded in CLAUDE.md as the reason the OTL
--                       push cannot be built.
--   EXPENDITURE_ORG     POET's O, same note. The costing unit the work books
--                       to, which is NOT the legal employer.
--
-- The rest are added because they are already being extracted and verified, so
-- the only thing standing between them and being useful is a column. Adding one
-- is cheaper than re-deriving the data later.
--
-- ADDITIVE ONLY. Every statement is ALTER TABLE ADD, guarded on ORA-01430
-- (column already exists), so this is safe to re-run and cannot lose data.
--
-- Idempotent. Depends on: time/02, time/03
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/2] Add the missing columns
PROMPT ============================================================

DECLARE
  TYPE t_col IS RECORD (tab VARCHAR2(30), col VARCHAR2(30), spec VARCHAR2(80));
  TYPE t_tab IS TABLE OF t_col;
  v_added NUMBER := 0;
  v_skip  NUMBER := 0;

  v t_tab := t_tab(
    -- POET's O, resource-wise. Deliberately separate from LEGAL_EMPLOYER:
    -- the employer is who employs the person, the expenditure org is the unit
    -- that incurs the cost, and reading one for the other sends cost to the
    -- wrong place while looking entirely plausible.
    t_col('OC_TIME_WORKER',     'EXPENDITURE_ORG',    'VARCHAR2(240 CHAR)'),

    t_col('OC_TIME_PROJECT',    'ORGANIZATION',       'VARCHAR2(240 CHAR)'),
    -- TrackTimeFlag on the Fusion project team. A project with this unset is
    -- INVISIBLE to time entry, so without the column the module cannot tell.
    t_col('OC_TIME_PROJECT',    'TIME_ENTRY_ENABLED', 'CHAR(1)'),

    -- Fusion's project id on the task, so the task can be tied back to its
    -- project without a name match. The FK PROJECT_ID stays local.
    t_col('OC_TIME_TASK',       'FUSION_PROJECT_ID',  'VARCHAR2(50 CHAR)'),
    t_col('OC_TIME_TASK',       'PROJECT_NUMBER',     'VARCHAR2(60 CHAR)'),
    t_col('OC_TIME_TASK',       'WBS_LEVEL',          'NUMBER(3)'),
    t_col('OC_TIME_TASK',       'PARENT_TASK_ID',     'VARCHAR2(50 CHAR)'),
    t_col('OC_TIME_TASK',       'START_DATE',         'DATE'),
    t_col('OC_TIME_TASK',       'END_DATE',           'DATE'),
    -- POET's E.
    t_col('OC_TIME_TASK',       'EXPENDITURE_TYPE',   'VARCHAR2(80 CHAR)'),

    -- Fusion's own project id on the allocation. OC_TIME_ALLOCATION.PROJECT_ID
    -- is OUR identity surrogate and cannot be sent to OTL; this is what names
    -- the project back to Fusion for the INT-007 push.
    --
    -- The ALLOCATIONS extract used to alias Fusion's id as PROJECT_ID -- the
    -- local FK's own name -- so the loader took it as an ordinary column and
    -- skipped the FK resolution that exists to prevent exactly that. Alias is
    -- now FUSION_PROJECT_ID (extracts.py) and this is where it lands.
    t_col('OC_TIME_ALLOCATION', 'FUSION_PROJECT_ID',  'VARCHAR2(50 CHAR)'),
    t_col('OC_TIME_ALLOCATION', 'PROJECT_NUMBER',     'VARCHAR2(60 CHAR)'),
    t_col('OC_TIME_ALLOCATION', 'TRACK_TIME_FLAG',    'CHAR(1)'),

    -- Fusion's own absence status, distinct from APPROVAL_STATUS: the pod
    -- returns absenceStatusCd SUBMITTED for a leave its own screen shows as
    -- Completed, so the two are not interchangeable.
    t_col('OC_TIME_ABSENCE',    'ABSENCE_STATUS',     'VARCHAR2(30 CHAR)'),

    t_col('OC_TIME_CALENDAR',   'SHIFT_NAME',         'VARCHAR2(100 CHAR)'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE ' || v(i).tab ||
                        ' ADD (' || v(i).col || ' ' || v(i).spec || ')';
      v_added := v_added + 1;
      DBMS_OUTPUT.PUT_LINE('added   ' || RPAD(v(i).tab, 22) || v(i).col);
    EXCEPTION WHEN OTHERS THEN
      -- ORA-01430: column being added already exists. Anything else is real.
      IF SQLCODE = -1430 THEN
        v_skip := v_skip + 1;
      ELSE
        DBMS_OUTPUT.PUT_LINE('FAILED  ' || v(i).tab || '.' || v(i).col ||
                             ' - ' || SUBSTR(SQLERRM, 1, 120));
        RAISE;
      END IF;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(v_added || ' column(s) added, ' || v_skip ||
                       ' already present.');
END;
/

-- Domain guards, added separately so a re-run that skipped the column still
-- gets its constraint. Y/N because that is what Fusion sends and what every
-- other flag in this schema uses.
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_project ADD CONSTRAINT
    chk_oc_tp_timeentry CHECK (time_entry_enabled IN ('Y','N'))~';
EXCEPTION WHEN OTHERS THEN IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_allocation ADD CONSTRAINT
    chk_oc_ta_tracktime CHECK (track_time_flag IN ('Y','N'))~';
EXCEPTION WHEN OTHERS THEN IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/2] Verification — what still has nowhere to land
PROMPT ============================================================

COLUMN table_name  FORMAT A22
COLUMN column_name FORMAT A22
COLUMN data_type   FORMAT A16

SELECT table_name, column_name, data_type
  FROM user_tab_columns
 WHERE (table_name, column_name) IN (
         ('OC_TIME_WORKER','EXPENDITURE_ORG'),
         ('OC_TIME_PROJECT','ORGANIZATION'),   ('OC_TIME_PROJECT','TIME_ENTRY_ENABLED'),
         ('OC_TIME_TASK','FUSION_PROJECT_ID'), ('OC_TIME_TASK','PROJECT_NUMBER'),
         ('OC_TIME_TASK','WBS_LEVEL'),         ('OC_TIME_TASK','PARENT_TASK_ID'),
         ('OC_TIME_TASK','START_DATE'),        ('OC_TIME_TASK','END_DATE'),
         ('OC_TIME_TASK','EXPENDITURE_TYPE'),
         ('OC_TIME_ALLOCATION','FUSION_PROJECT_ID'),
         ('OC_TIME_ALLOCATION','PROJECT_NUMBER'),
         ('OC_TIME_ALLOCATION','TRACK_TIME_FLAG'),
         ('OC_TIME_ABSENCE','ABSENCE_STATUS'),
         ('OC_TIME_CALENDAR','SHIFT_NAME'))
 ORDER BY table_name, column_name;

PROMPT
PROMPT Expect 15 rows. Anything missing did not get added and the loader will
PROMPT still drop that element without complaining.
--== END 17_sync_column_gaps.sql ==

PROMPT >>> 18 OC_TIME_TASK natural key (the loader cannot merge without it)

--==============================================================
-- BEGIN 18_task_natural_key.sql
--==============================================================
--==============================================================
-- time/18_task_natural_key.sql
-- O2C Timesheet Module — OC_TIME_TASK needs a natural key
--
-- CORRECTED 10-Aug-2026. What this file first said was wrong, and the wrong
-- version was compiled, so read this before assuming the header below.
--
-- It claimed OC_TIME_TASK had "nothing but the identity primary key". It has a
-- natural key and always did -- 02_time_master.sql creates two:
--
--   UK_OC_TTSK_WBS     (project_id, UPPER(task_code))
--   UK_OC_TTSK_COMMON  (CASE WHEN task_type='COMMON' THEN UPPER(task_code) END)
--
-- Both are CREATE UNIQUE INDEX, not ALTER TABLE ADD CONSTRAINT. Oracle keeps
-- those in USER_INDEXES and NOT in USER_CONSTRAINTS, and the loader's key
-- discovery reads USER_CONSTRAINTS -- so it saw no key on a table that has two.
-- POST sync/task already keys on (project, task code) and says why: "because
-- UK_OC_TTSK_WBS is what the table actually enforces."
--
-- The merge key is therefore NOT this constraint. OC_TIME_SYNC_CONFIG.MERGE_KEY
-- declares 'PROJECT_ID,TASK_CODE' for TASKS, and the loader prefers a declared
-- key over discovery. Matching on FUSION_TASK_ID while the table enforces
-- (project, code) is worse than having no key at all: a row that misses on the
-- fusion id is treated as new and the insert collides, ORA-00001, mid-sync.
--
-- WHAT THIS FILE IS STILL FOR, and why it is kept rather than reverted:
-- FUSION_TASK_ID genuinely is unique -- it is Fusion's PROJ_ELEMENT_ID -- and
-- nothing enforced that. The constraint turns one specific silent corruption
-- into an error: a task that MOVES between projects in Fusion arrives as
-- (new project, same code), misses the merge on (project, code), and inserts.
-- Without this it becomes a second row for one Fusion task, in two projects at
-- once, and the task LOV shows both. With it, the sync fails and says so.
-- Failing is the better outcome; neither is correct handling, and a task that
-- moves project still needs a real answer.
--
-- NULLABLE, deliberately. The COMMON tasks -- Leave, Training, Travel and the
-- rest, seeded by 10_seed.sql -- have no Fusion element behind them and never
-- will. Oracle's unique constraints ignore null rows, so those coexist happily.
--
-- Idempotent. Depends on: time/02, time/17
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] Any duplicates already there?
PROMPT ============================================================

-- Adding the constraint fails on existing duplicates, and the failure would be
-- a bare ORA-02299 naming the index rather than the rows. Report first.
DECLARE
  v_dup NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_dup FROM (
    SELECT fusion_task_id FROM oc_time_task
     WHERE fusion_task_id IS NOT NULL
     GROUP BY fusion_task_id HAVING COUNT(*) > 1);

  IF v_dup = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No duplicate FUSION_TASK_ID. Safe to constrain.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(v_dup || ' duplicated FUSION_TASK_ID value(s) exist.');
    DBMS_OUTPUT.PUT_LINE('These are almost certainly from a load that ran '
                      || 'before this key existed. Review them, keep one row '
                      || 'each, then re-run:');
    FOR r IN (SELECT fusion_task_id, COUNT(*) c FROM oc_time_task
               WHERE fusion_task_id IS NOT NULL
               GROUP BY fusion_task_id HAVING COUNT(*) > 1
               FETCH FIRST 10 ROWS ONLY)
    LOOP
      DBMS_OUTPUT.PUT_LINE('   ' || r.fusion_task_id || '  x' || r.c);
    END LOOP;
  END IF;
END;
/

PROMPT ============================================================
PROMPT [2/3] The constraint
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE
    'ALTER TABLE oc_time_task ADD CONSTRAINT uk_oc_ttsk_fusion '
    || 'UNIQUE (fusion_task_id)';
  DBMS_OUTPUT.PUT_LINE('UK_OC_TTSK_FUSION created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-2261, -2264) THEN            -- already exists, either name
    DBMS_OUTPUT.PUT_LINE('UK_OC_TTSK_FUSION already exists - skipped.');
  ELSIF SQLCODE = -2299 THEN
    DBMS_OUTPUT.PUT_LINE('CANNOT ADD: duplicate FUSION_TASK_ID rows exist. '
                      || 'See the list above, clean them, then re-run.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification — the keys, from BOTH places they can live
PROMPT ============================================================
PROMPT A unique INDEX is not a unique CONSTRAINT. Listing only USER_CONSTRAINTS
PROMPT is what hid UK_OC_TTSK_WBS in the first place, so list both.

COLUMN table_name      FORMAT A22
COLUMN constraint_name FORMAT A24
COLUMN cols            FORMAT A44

-- IN PL/SQL, NOT SQL. USER_IND_EXPRESSIONS.COLUMN_EXPRESSION is a LONG, and a
-- LONG cannot appear inside NVL, LISTAGG, GROUP BY or virtually any SQL
-- expression -- only bare in a SELECT list. Wrapping it in NVL() alongside a
-- VARCHAR2 column is ORA-00932 "inconsistent datatypes: expected LONG got CHAR",
-- which reads like a column mismatch and is really "you may not touch a LONG
-- here at all". PL/SQL assigns a LONG to VARCHAR2(32760) implicitly, so reading
-- it one row at a time works where the set-based query cannot.
--
-- Same family as the SQL-only / PL/SQL-only traps already in CLAUDE.md section 5:
-- check which side of that line a thing lives on before writing the statement.
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_expr VARCHAR2(4000);
  v_cols VARCHAR2(4000);
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('TABLE', 22) || RPAD('KIND', 12) ||
                       RPAD('NAME', 24) || 'COLUMNS');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 96, '-'));

  -- Unique CONSTRAINTS: what the loader's discovery CAN see.
  FOR c IN (
    SELECT c.table_name, c.constraint_name,
           LISTAGG(cc.column_name, ', ')
             WITHIN GROUP (ORDER BY cc.position) AS cols
      FROM user_constraints c
      JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
     WHERE c.constraint_type = 'U'
       AND c.table_name IN ('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                            'OC_TIME_ALLOCATION','OC_TIME_ABSENCE',
                            'OC_TIME_CALENDAR')
     GROUP BY c.table_name, c.constraint_name
     ORDER BY c.table_name, c.constraint_name)
  LOOP
    DBMS_OUTPUT.PUT_LINE(RPAD(c.table_name, 22) || RPAD('CONSTRAINT', 12) ||
                         RPAD(c.constraint_name, 24) || c.cols);
  END LOOP;

  -- Unique INDEXES with no constraint behind them: what it CANNOT.
  FOR i IN (
    SELECT i.table_name, i.index_name
      FROM user_indexes i
     WHERE i.uniqueness = 'UNIQUE'
       AND i.table_name IN ('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                            'OC_TIME_ALLOCATION','OC_TIME_ABSENCE',
                            'OC_TIME_CALENDAR')
       AND NOT EXISTS (SELECT 1 FROM user_constraints c2
                        WHERE c2.index_name = i.index_name)
     ORDER BY i.table_name, i.index_name)
  LOOP
    v_cols := NULL;
    FOR ic IN (SELECT column_name, column_position
                 FROM user_ind_columns
                WHERE index_name = i.index_name
                ORDER BY column_position)
    LOOP
      -- A function-based column is stored as SYS_NCnnnnn$ and its real
      -- expression lives only in USER_IND_EXPRESSIONS, as a LONG.
      --
      -- No LIKE 'SYS\_NC%' ESCAPE '\' test here, deliberately. An ordinary
      -- column simply has no row in USER_IND_EXPRESSIONS, so NO_DATA_FOUND
      -- already tells us everything the name test would have — the condition
      -- was redundant, and being redundant it was pure risk: it needed a
      -- backslash to escape the underscore (an underscore is LIKE's
      -- single-character wildcard), the backslash was lost writing this file,
      -- and ESCAPE '' is a zero-length escape character — ORA-06502, thrown
      -- per row, from a block whose only job is to print a table.
      v_expr := NULL;
      BEGIN
        SELECT column_expression INTO v_expr      -- LONG -> VARCHAR2, legal here
          FROM user_ind_expressions
         WHERE index_name = i.index_name
           AND column_position = ic.column_position;
      EXCEPTION WHEN NO_DATA_FOUND THEN v_expr := NULL;   -- a plain column
      END;
      v_cols := v_cols || ', ' || NVL(v_expr, ic.column_name);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(RPAD(i.table_name, 22) || RPAD('INDEX', 12) ||
                         RPAD(i.index_name, 24) || LTRIM(v_cols, ', '));
  END LOOP;
END;
/

PROMPT
PROMPT Every row marked INDEX is a key the loader's discovery CANNOT see. If a
PROMPT feed targets one of those tables, its config row needs MERGE_KEY set
PROMPT explicitly -- discovery will either find nothing or find the wrong key.
--== END 18_task_natural_key.sql ==

PROMPT >>> 16 OIC sync config + the generic XML loader

--==============================================================
-- BEGIN 16_oic_sync_config.sql
--==============================================================
--==============================================================
-- time/16_oic_sync_config.sql
-- O2C Timesheet Module — OIC config table + the generic XML loader
--
-- Implements the two-integration design:
--
--   INT 001  schedule -> read this config -> for each row, call INT 002
--   INT 002  REST trigger -> run the BIP report at BIP_REPORT_PATH
--                         -> hand (TARGET_TABLE, raw XML) to OC_TIME_LOAD_XML
--                         -> write LASTSYNC_DATE / SYNC_STATUS back here
--
-- So OIC carries no mapping and no SQL. It knows a report path, a table name
-- and a date. Everything about what the columns are and how a row is matched
-- lives here, next to the tables it writes.
--
-- Idempotent. Depends on: time/01, time/02, time/06 (OC_TIME_SYNC_JOB/FAILED)
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] OC_TIME_SYNC_CONFIG — what INT 001 loops over
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_sync_config (
      CONFIG_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      BIP_REPORT_NAME  VARCHAR2(60 CHAR)  NOT NULL,
      PURPOSE          VARCHAR2(400 CHAR),
      BIP_REPORT_PATH  VARCHAR2(400 CHAR) NOT NULL,
      -- Nullable on purpose. All eleven reports are registered here, including
      -- the four that have nowhere to load and the one that is read live, so
      -- the config is the complete inventory. A missing row is invisible; a
      -- disabled row with a PURPOSE explains itself.
      TARGET_TABLE     VARCHAR2(30 CHAR),
      -- LASTSYNC_DATE is BOTH the bookmark and the parameter: INT 002 sends it
      -- to the report as :P_LAST_SYNC and writes the new one back on success.
      -- Advanced only on Success -- a Partial must not move it, or the rows
      -- that failed are never seen again.
      LASTSYNC_DATE    DATE,
      SYNC_MODE        VARCHAR2(12 CHAR) DEFAULT 'INCREMENTAL' NOT NULL,
      SYNC_STATUS      VARCHAR2(12 CHAR) DEFAULT 'Ready' NOT NULL,
      -- Daily / Monthly / Both. INT 001 runs on both schedules and filters.
      SCHEDULE_TAG     VARCHAR2(10 CHAR) DEFAULT 'Both' NOT NULL,
      -- ORDER IS NOT COSMETIC. OC_TIME_ALLOCATION has foreign keys to both
      -- worker and project, so an allocation whose worker has not loaded lands
      -- in OC_TIME_SYNC_FAILED instead of the table. INT 001 must ORDER BY
      -- this and process serially, not fan out.
      RUN_ORDER        NUMBER(3) DEFAULT 100 NOT NULL,
      ENABLED_FLAG     CHAR(1) DEFAULT 'Y' NOT NULL,
      -- ── foreign-key resolution ───────────────────────────────
      -- ORDERING ALONE DOES NOT FIX A FOREIGN KEY, and conflating the two
      -- wastes a day. Loading projects before tasks guarantees the PARENT ROW
      -- EXISTS; it does nothing about the fact that the report sends Fusion's
      -- project id (300000123456789) while OC_TIME_TASK.PROJECT_ID is our own
      -- GENERATED ALWAYS identity (47). Different id spaces, so the value
      -- matches nothing however carefully you sequence the loads.
      --
      -- FK_COLUMN is the local column to fill; FK_LOOKUP_SQL is a scalar
      -- subquery that finds it from something the XML DOES carry. Both null
      -- for entities that need no resolution.
      --
      -- Ordering is still required -- the lookup can only succeed once the
      -- parent is loaded -- so the two work together rather than one replacing
      -- the other.
      FK_COLUMN        VARCHAR2(30 CHAR),
      FK_LOOKUP_SQL    VARCHAR2(1000 CHAR),
      -- The columns the MERGE matches on, comma separated. Optional: when null
      -- the loader discovers the key from the table's primary or unique
      -- CONSTRAINTS.
      --
      -- It is here because discovery cannot see everything. OC_TIME_TASK is
      -- keyed by UK_OC_TTSK_WBS on (PROJECT_ID, UPPER(TASK_CODE)) -- a unique
      -- INDEX, not a constraint, so it never appears in USER_CONSTRAINTS. The
      -- loader found no key at all, and once given one on FUSION_TASK_ID it
      -- matched on that instead, which is a DIFFERENT key from the one the
      -- table enforces: a row can miss on the fusion id, be treated as new,
      -- and then collide on (project, code) with ORA-00001.
      --
      -- POST sync/task already keys on (project, task code) for exactly this
      -- reason. Declaring it makes the two agree instead of each guessing.
      MERGE_KEY        VARCHAR2(200 CHAR),
      -- ── last run, for the operator ───────────────────────────
      LAST_RUN_ON      TIMESTAMP,
      LAST_ROWS_READ   NUMBER(10),
      LAST_ROWS_MERGED NUMBER(10),
      LAST_ROWS_FAILED NUMBER(10),
      LAST_MESSAGE     VARCHAR2(2000 CHAR),
      LAST_JOB_RUN_ID  NUMBER,
      CREATED_BY       VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY       VARCHAR2(100),
      UPDATED_ON       TIMESTAMP,
      CONSTRAINT chk_oc_tsc_mode   CHECK (sync_mode   IN ('FULL','INCREMENTAL')),
      CONSTRAINT chk_oc_tsc_status CHECK (sync_status IN
        ('Ready','Running','Success','Partial','Failed')),
      CONSTRAINT chk_oc_tsc_sched  CHECK (schedule_tag IN ('Daily','Monthly','Both')),
      CONSTRAINT chk_oc_tsc_enab   CHECK (enabled_flag IN ('Y','N')),
      -- Enabled means "INT 001 will hand this to the loader", and the loader
      -- needs somewhere to put it. Disabled rows may have no target.
      CONSTRAINT chk_oc_tsc_tgt    CHECK (enabled_flag = 'N'
                                          OR target_table IS NOT NULL),
      CONSTRAINT uk_oc_tsc_name    UNIQUE (bip_report_name)
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CONFIG created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CONFIG already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- Already-installed schemas: relax TARGET_TABLE and add the guard. Separate
-- blocks so one already being done does not skip the other.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_config MODIFY (target_table NULL)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1451 THEN NULL;   -- already nullable
  ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_sync_config ADD CONSTRAINT
    chk_oc_tsc_tgt CHECK (enabled_flag = 'N' OR target_table IS NOT NULL)~';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -2264 THEN NULL;   -- constraint name already used
  ELSE RAISE; END IF;
END;
/

-- One ALTER PER COLUMN, not one ALTER adding three.
--
-- A combined ADD is atomic: on a schema where fk_column already exists -- which
-- is every schema that ran the previous version of this file -- Oracle raises
-- ORA-01430 for that one column and adds NONE of them. The guard below then
-- swallows it, the script reports success, and MERGE_KEY silently does not
-- exist. Every TASKS load afterwards falls back to discovery and merges on the
-- wrong key. Per-column, each add fails or succeeds on its own.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(200);
  v t_tab := t_tab(
    'fk_column VARCHAR2(30 CHAR)',
    'fk_lookup_sql VARCHAR2(1000 CHAR)',
    'merge_key VARCHAR2(200 CHAR)');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_config ADD (' || v(i) || ')';
      DBMS_OUTPUT.PUT_LINE('added   ' || v(i));
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;   -- already there
    END;
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [2/4] Seed all eleven reports — six enabled, five off with a reason
PROMPT ============================================================

-- ALL ELEVEN are registered. Six are enabled; five are off and say why in
-- PURPOSE. Leaving them out entirely was the wrong call -- an operator counting
-- eleven data models and six config rows has no way to tell whether the other
-- five are deliberate or forgotten.
DECLARE
  TYPE t_row IS RECORD (nm VARCHAR2(60), pur VARCHAR2(400),
                        tbl VARCHAR2(30), ord NUMBER, sch VARCHAR2(10),
                        en VARCHAR2(1));
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('WORKERS',      'People, their manager, standard day and status (INT-001). '
                       || 'FIRST: everything else has a worker foreign key.',
          'OC_TIME_WORKER',     10, 'Both', 'Y'),
    t_row('PROJECTS',     'Projects that track time and have a manager (INT-002).',
          'OC_TIME_PROJECT',    20, 'Both', 'Y'),
    t_row('TASKS',        'WBS tasks with chargeable/billable flags (INT-002).',
          'OC_TIME_TASK',       30, 'Both', 'Y'),
    t_row('ALLOCATIONS',  'Who may charge to what, and at what percentage (INT-003). '
                       || 'Needs WORKERS and PROJECTS already loaded.',
          'OC_TIME_ALLOCATION', 40, 'Both', 'Y'),
    t_row('CALENDAR',     'Corporate working days and holidays (INT-004/005).',
          'OC_TIME_CALENDAR',   50, 'Both', 'Y'),
    t_row('WORKER_SHIFTS','Per-person per-day shift, the SHIFT calendar layer. '
                       || 'Highest precedence, so a shift day beats a holiday.',
          'OC_TIME_CALENDAR',   60, 'Both', 'Y'),
    -- ── registered, deliberately not scheduled ───────────────
    t_row('ABSENCES',     'OFF: absence is read LIVE per person per date at page '
                       || 'load, not synced (decision 09-Aug-2026). The model is '
                       || 'kept because the leave-loss absentee list still needs '
                       || 'a bulk read. Enable only if that decision changes.',
          'OC_TIME_ABSENCE',    70, 'Both',    'N'),
    t_row('SHIFTS',       'OFF: no target table. A shift dictionary (code, '
                       || 'duration, break) with no date, so it does not fit '
                       || 'OC_TIME_CALENDAR, which is one row per day. '
                       || 'Diagnostic only.',
          NULL,                 80, 'Both',    'N'),
    t_row('WORK_PATTERNS','OFF: no target table. A pattern template keyed on '
                       || 'day-of-cycle, not a calendar date. Fusion has already '
                       || 'resolved it into WORKER_SHIFTS, which is what loads.',
          NULL,                 90, 'Both',    'N'),
    t_row('WORK_SCHEDULES','OFF: no target table. Assigns a schedule to a person '
                       || 'for a DATE RANGE; OC_TIME_CALENDAR is per day. Useful '
                       || 'for explaining why someone has the shift they have.',
          NULL,                100, 'Both',    'N'),
    t_row('EXP_TYPES',    'OFF: reference only. The legal values for expenditure '
                       || 'type. Nothing consumes it yet -- see the POET gap: '
                       || 'OC_TIME_TASK has no EXPENDITURE_TYPE column.',
          NULL,                110, 'Both',    'N'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_sync_config
           (bip_report_name, purpose, bip_report_path, target_table,
            sync_mode, schedule_tag, run_order, enabled_flag)
    SELECT v(i).nm, v(i).pur, '/Custom/O2C_TIME/O2C_' || v(i).nm || '.xdm',
           v(i).tbl, 'INCREMENTAL', v(i).sch, v(i).ord, v(i).en
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_sync_config
                        WHERE bip_report_name = v(i).nm);
  END LOOP;
  -- The two entities whose parent key arrives in the wrong id space. Both
  -- reports already emit PROJECT_NUMBER, and 17_sync_column_gaps.sql gives it
  -- a real column, so the loader decodes it and the lookup can read it.
  UPDATE oc_time_sync_config
     SET fk_column     = 'PROJECT_ID',
         fk_lookup_sql = '(SELECT p.project_id FROM oc_time_project p '
                      || 'WHERE p.project_number = x.PROJECT_NUMBER)'
   WHERE bip_report_name IN ('TASKS','ALLOCATIONS')
     AND fk_column IS NULL;

  -- CALENDAR and WORKER_SHIFTS run on BOTH schedules, not Monthly only.
  --
  -- A holiday added mid-month, a shift reassigned, a working pattern changed --
  -- each moves the hours a default produces for days that have not happened
  -- yet, and on Monthly-only they would not be seen until the next month was
  -- built. By then the days they affect are already populated with the old
  -- calendar, and correcting them is an adjustment rather than a prepopulation.
  --
  -- Cheap to do daily: 142 and 2351 rows, and both are incremental.
  UPDATE oc_time_sync_config
     SET schedule_tag = 'Both'
   WHERE bip_report_name IN ('CALENDAR','WORKER_SHIFTS')
     AND schedule_tag <> 'Both';

  -- Match what UK_OC_TTSK_WBS enforces, not what discovery happens to find.
  UPDATE oc_time_sync_config
     SET merge_key = 'PROJECT_ID,TASK_CODE'
   WHERE bip_report_name = 'TASKS' AND merge_key IS NULL;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Sync config seeded.');
END;
/

PROMPT ============================================================
PROMPT [3/4] OC_TIME_LOAD_XML — decode the BIP XML and merge it
PROMPT ============================================================

-- INT 002 calls this with a table name and the report's raw XML. It returns
-- counts and a status, so the integration can write SYNC_STATUS back without
-- interpreting anything.
--
-- FIVE THINGS THIS HAS TO GET RIGHT, and four of them fail SILENTLY if wrong.
--
-- 1. THE ROW TAG IS /DATA_DS/ROWSET/ROW.
--    The data models declare a group called G_1 and BIP does NOT use it in the
--    output -- it emits ROWSET/ROW regardless. Decoding G_1 returns zero rows
--    and reports success, which is indistinguishable from "the report found
--    nothing". This is recorded in integration/bip/bip_client.py for the same
--    reason.
--
-- 2. THE TABLE NAME IS VALIDATED AGAINST THE CONFIG, not just against
--    USER_TABLES. This builds dynamic SQL, so an unchecked name is an
--    injection point; restricting it to tables the config actually targets is
--    both the security check and a typo check.
--
-- 3. IT MERGES, IT DOES NOT INSERT. Every target has a natural key and the
--    whole design re-reads overlapping windows, so a plain INSERT would fail
--    with ORA-00001 on the second run of anything. The key is read from the
--    table's own primary or unique constraint rather than configured, so it
--    cannot drift from the table it protects.
--
-- 4. ONLY COLUMNS PRESENT IN BOTH THE XML AND THE TABLE ARE TOUCHED. A report
--    carrying an extra element must not error, and a table column the report
--    does not send must keep its value rather than be nulled.
--
--    WHICH MAKES THE ALIAS THE CONTRACT: the report's SELECT alias must equal
--    the table's column name, exactly. There is no mapping layer, by design --
--    a mapping table would be a third place for the same fact to be wrong.
--
--    MEASURED 10-Aug-2026 AGAINST THE CURRENT EXTRACTS, AND IT DOES NOT HOLD:
--
--      WORKERS        11/12 columns match  -> loads
--      PROJECTS        6/11               -> loads, but silently without
--                                            TIME_ENTRY_ENABLED, START/END_DATE
--      TASKS           4/12               -> loads, but WITHOUT BILLABLE_FLAG,
--                                            which the billable+chargeable rule
--                                            depends on entirely
--      ALLOCATIONS     7/9                -> loads
--      ABSENCES        4/6                -> loads, but DURATION_HOURS is
--                                            dropped, so every absence arrives
--                                            with zero hours
--      CALENDAR        5/7                -> BLOCKED: CALENDAR_DATE is not
--                                            CAL_DATE, so the key is uncovered
--      WORKER_SHIFTS   3/7                -> BLOCKED: CALENDAR_DATE and
--                                            EMPLOYEE_ID are not CAL_DATE and
--                                            SCOPE_KEY
--
--    The two BLOCKED ones fail loudly here, which is right. The dangerous ones
--    are TASKS and ABSENCES: they load, report success, and are wrong. Fix by
--    renaming the aliases in integration/bip/extracts.py to the table's column
--    names and redeploying the models -- mechanical, and it also collapses the
--    extract-versus-loader contract clash in the OIC design document into a
--    single canonical name per field.
--
-- 5. APP-OWNED COLUMNS ARE NEVER OVERWRITTEN. APP_ROLE is the obvious one --
--    it is the module's own, not Fusion's, and a sync that reset it would lock
--    people out of their own menus.
CREATE OR REPLACE PROCEDURE oc_time_load_xml(
  p_table_name  IN  VARCHAR2,
  p_xml         IN  CLOB,
  p_report_name IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'OIC',
  o_rows_read   OUT NUMBER,
  o_rows_merged OUT NUMBER,
  o_status      OUT VARCHAR2,
  o_message     OUT VARCHAR2)
AS
  -- Columns the module owns. Fusion has no opinion on these and a sync that
  -- wrote them would undo local decisions.
  c_never CONSTANT VARCHAR2(200) :=
    ',APP_ROLE,CREATED_BY,CREATED_ON,UPDATED_BY,UPDATED_ON,SYNC_JOB_RUN_ID,';

  v_tab      VARCHAR2(30);
  v_ok       NUMBER;
  v_cols     VARCHAR2(4000);   -- XMLTABLE column clause
  v_src      VARCHAR2(4000);   -- s.COL list
  v_set      VARCHAR2(4000);   -- UPDATE SET list
  v_ins      VARCHAR2(4000);   -- INSERT column list
  v_val      VARCHAR2(4000);   -- INSERT value list
  v_on       VARCHAR2(1000);   -- MERGE ON clause
  v_sql      CLOB;
  v_keycols  NUMBER := 0;
  v_fkcol    VARCHAR2(30);
  v_fksql    VARCHAR2(1000);
  v_mkey     VARCHAR2(200);
  v_capture  VARCHAR2(1)   := 'N';
  v_keyexpr  VARCHAR2(2000);          -- the merge key, as a printable string
  v_oldj     VARCHAR2(4000);          -- JSON_ARRAY(...) over t.<cols>
  v_newj     VARCHAR2(4000);          -- the same over s.<cols>
  v_cap      CLOB;
BEGIN
  o_rows_read := 0; o_rows_merged := 0; o_status := 'Failed';

  -- ── 2. the name must be one we target ──────────────────────
  v_tab := UPPER(TRIM(p_table_name));
  SELECT COUNT(*) INTO v_ok
    FROM oc_time_sync_config WHERE UPPER(target_table) = v_tab;

  -- The resolution rule, if this feed has one. Read by report name when given,
  -- because two reports can share a table -- CALENDAR and WORKER_SHIFTS both
  -- write OC_TIME_CALENDAR -- and only one of them may need a lookup.
  BEGIN
    SELECT MAX(fk_column), MAX(fk_lookup_sql), MAX(merge_key),
           NVL(MAX(capture_changes), 'N')
      INTO v_fkcol, v_fksql, v_mkey, v_capture
      FROM oc_time_sync_config
     WHERE UPPER(target_table) = v_tab
       AND (p_report_name IS NULL OR bip_report_name = p_report_name);
  EXCEPTION WHEN NO_DATA_FOUND THEN v_fkcol := NULL;
  END;

  IF v_ok = 0 THEN
    o_message := 'Table ' || v_tab || ' is not a target in OC_TIME_SYNC_CONFIG. '
              || 'Refusing to build SQL against it.';
    RETURN;
  END IF;

  IF p_xml IS NULL OR DBMS_LOB.GETLENGTH(p_xml) = 0 THEN
    o_message := 'The report returned no XML at all.';
    RETURN;
  END IF;

  -- ── 4. columns in BOTH the XML and the table ───────────────
  -- The XML side is read from the first ROW, so an element the report stops
  -- sending simply drops out instead of erroring.
  FOR c IN (
    SELECT t.column_name, t.data_type
      FROM user_tab_columns t
     WHERE t.table_name = v_tab
       AND INSTR(c_never, ',' || t.column_name || ',') = 0
       -- GENERATED ALWAYS columns cannot be written at all (ORA-32795), and
       -- this is not hypothetical: OC_TIME_TASK.TASK_ID and
       -- OC_TIME_PROJECT.PROJECT_ID are local identity keys while the extracts
       -- emit elements of the SAME NAME carrying Fusion's ids. Without this the
       -- merge fails outright -- and if it did not, it would be silently
       -- conflating two different id spaces. Fusion's ids belong in
       -- FUSION_TASK_ID / FUSION_PROJECT_ID; see the alias note above.
       AND t.identity_column = 'NO'
       -- A COLUMN WE RESOLVE IS NEVER READ FROM THE XML. This is the whole
       -- point of the lookup and it was previously defeated by its own guard.
       --
       -- ALLOCATIONS selects Fusion's project id as "pp.project_id AS
       -- project_id" -- the exact name of OC_TIME_ALLOCATION.PROJECT_ID, which
       -- is our LOCAL surrogate foreign key. Without this line the scan below
       -- picks PROJECT_ID up as an ordinary column, and the resolution block
       -- further down then finds it already present and SKIPS ITSELF. Fusion's
       -- 300000337787982 goes straight into the local FK: ORA-02291 if no local
       -- project happens to hold that number, and -- far worse -- a silent
       -- attachment to the WRONG project if one does.
       --
       -- TASKS was safe only by luck: its extract aliases to FUSION_PROJECT_ID,
       -- so PROJECT_ID was absent from the XML and the guard's condition held.
       -- The identity_column test above exists for this same reason; it does
       -- not cover this case because a foreign key is not an identity column.
       AND (v_fkcol IS NULL OR t.column_name <> v_fkcol)
       AND EXISTS (
             SELECT 1
               FROM XMLTABLE('/DATA_DS/ROWSET/ROW[1]/*'
                             PASSING XMLTYPE(p_xml)
                             COLUMNS nm VARCHAR2(128) PATH 'name()') x
              WHERE x.nm = t.column_name)
     ORDER BY t.column_id)
  LOOP
    -- Everything is read as a string and converted on the way in. BIP emits
    -- dates as YYYY-MM-DD text; letting Oracle guess would depend on NLS.
    v_cols := v_cols || ',' || c.column_name || ' VARCHAR2(4000) PATH ''' || c.column_name || '''';
    v_src  := v_src  || ',' ||
      CASE
        WHEN c.data_type = 'DATE'   THEN 'TO_DATE(x.' || c.column_name || ',''YYYY-MM-DD'')'
        WHEN c.data_type = 'NUMBER' THEN 'TO_NUMBER(x.' || c.column_name ||
                                         ' DEFAULT NULL ON CONVERSION ERROR)'
        ELSE 'x.' || c.column_name
      END || ' AS ' || c.column_name;
    v_ins  := v_ins  || ',' || c.column_name;
    v_val  := v_val  || ',s.' || c.column_name;
  END LOOP;

  -- Resolve the parent key. Added to the source select and the insert, but NOT
  -- to the XMLTABLE column list -- it is computed from the XML, not read out of
  -- it, and reading it would take Fusion's id straight into a local FK.
  -- Unconditional. The "only if not already present" test that used to wrap
  -- this was the bug described in the scan above: it handed control to whatever
  -- the report happened to name its columns. The scan now excludes v_fkcol
  -- outright, so the resolution is the ONLY thing that can populate it.
  IF v_fkcol IS NOT NULL AND v_fksql IS NOT NULL THEN
    v_src := v_src || ',' || v_fksql || ' AS ' || v_fkcol;
    v_ins := v_ins || ',' || v_fkcol;
    v_val := v_val || ',s.' || v_fkcol;
  END IF;

  IF v_cols IS NULL THEN
    o_message := 'No column in ' || v_tab || ' matches any element in the XML. '
              || 'Check the report''s SELECT aliases against the table.';
    RETURN;
  END IF;

  -- ── 3. the natural key ─────────────────────────────────────
  -- A declared MERGE_KEY wins. Discovery is the fallback, and it can only see
  -- what is in USER_CONSTRAINTS -- a unique INDEX is invisible to it.
  IF v_mkey IS NOT NULL THEN
    FOR k IN (SELECT TRIM(REGEXP_SUBSTR(v_mkey, '[^,]+', 1, LEVEL)) AS column_name
                FROM dual
             CONNECT BY LEVEL <= REGEXP_COUNT(v_mkey, ',') + 1)
    LOOP
      IF INSTR(',' || LTRIM(v_ins, ',') || ',', ',' || k.column_name || ',') = 0 THEN
        o_message := 'MERGE_KEY names ' || k.column_name || ', which is neither '
                  || 'in the XML nor resolved. Check the config against the report.';
        RETURN;
      END IF;
      v_on := v_on || ' AND t.' || k.column_name || ' = s.' || k.column_name;
      v_keyexpr := v_keyexpr || '||''|''||TO_CHAR(s.' || k.column_name || ')';
      v_keycols := v_keycols + 1;
    END LOOP;
  END IF;

  FOR k IN (
    SELECT cc.column_name
      FROM user_constraints c
      JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
     WHERE c.table_name = v_tab
       AND c.constraint_type IN ('P','U')
       -- The identity primary key is not a natural key and matches nothing in
       -- a feed. Prefer a constraint whose columns the XML actually carries.
       AND NOT EXISTS (SELECT 1 FROM user_tab_columns g
                        WHERE g.table_name = v_tab
                          AND g.column_name = cc.column_name
                          AND g.identity_column = 'YES')
       AND INSTR(',' || LTRIM(v_ins, ',') || ',',
                 ',' || cc.column_name || ',') > 0
     ORDER BY c.constraint_type, c.constraint_name, cc.position)
  LOOP
    EXIT WHEN v_mkey IS NOT NULL;          -- declared key already applied
    v_on := v_on || ' AND t.' || k.column_name || ' = s.' || k.column_name;
    v_keyexpr := v_keyexpr || '||''|''||TO_CHAR(s.' || k.column_name || ')';
    v_keycols := v_keycols + 1;
  END LOOP;
  IF v_set IS NULL THEN v_set := ''; END IF;

  IF v_keycols = 0 THEN
    o_message := 'No primary or unique key on ' || v_tab
              || ' is covered by the XML, so rows cannot be matched. '
              || 'A plain insert would duplicate on the next run.';
    RETURN;
  END IF;

  -- Update everything that is not part of the match.
  --
  -- EXCEPT that a Fusion identifier is never overwritten with nothing. Every
  -- other column is assigned straight from the source, which is correct: a
  -- cleared END_DATE must actually clear. A Fusion id is different in kind --
  -- it is the only thing that can name our row back to Fusion for the OTL push
  -- (INT-007), and Fusion never un-assigns one. So an empty element means the
  -- report did not send it, not that the id was withdrawn.
  --
  -- Without the NVL, <FUSION_TASK_ID></FUSION_TASK_ID> parses to NULL and the
  -- MERGE writes that NULL over a good id. Nothing would raise: the column is
  -- nullable, and UK_OC_TTSK_FUSION permits any number of NULL rows because
  -- Oracle's unique constraints ignore them. The push would simply find nothing
  -- to send, for rows that used to be fine, with no error anywhere.
  --
  -- Matched on the FUSION_% naming rather than a list so a new Fusion id column
  -- is protected the day it is added, not the day someone remembers this.
  FOR c IN (SELECT REGEXP_SUBSTR(LTRIM(v_ins, ','), '[^,]+', 1, LEVEL) AS nm
              FROM dual
           CONNECT BY LEVEL <= REGEXP_COUNT(v_ins, ','))
  LOOP
    IF INSTR(v_on, ' t.' || c.nm || ' = ') = 0 THEN
      -- SUBSTR, not LIKE 'FUSION\_%' ESCAPE '\'. The underscore is LIKE's
      -- single-character wildcard, so it needs a backslash, and a backslash in
      -- a PL/SQL literal is fragile in ways that have nothing to do with
      -- Oracle: it was lost in transit writing this file, leaving ESCAPE ''
      -- -- a zero-length escape character, ORA-06502, raised on EVERY load
      -- rather than on some unlucky column name. SUBSTR has no wildcards, no
      -- escape and no way to be silently corrupted.
      IF SUBSTR(c.nm, 1, 7) = 'FUSION_' THEN
        v_set := v_set || ',t.' || c.nm || ' = NVL(s.' || c.nm || ', t.' || c.nm || ')';
      ELSE
        v_set := v_set || ',t.' || c.nm || ' = s.' || c.nm;
      END IF;
    END IF;
  END LOOP;

  v_sql :=
    'MERGE INTO ' || v_tab || ' t USING (' ||
      'SELECT ' || LTRIM(v_src, ',') ||
      '  FROM XMLTABLE(''/DATA_DS/ROWSET/ROW'' PASSING :1 COLUMNS ' ||
           LTRIM(v_cols, ',') || ') x) s' ||
    ' ON (' || LTRIM(v_on, ' AND') || ')' ||
    CASE WHEN v_set IS NOT NULL AND LENGTH(v_set) > 0
         THEN ' WHEN MATCHED THEN UPDATE SET ' || LTRIM(v_set, ',') ELSE '' END ||
    ' WHEN NOT MATCHED THEN INSERT (' || LTRIM(v_ins, ',') ||
    ') VALUES (' || LTRIM(v_val, ',') || ')';

  SELECT COUNT(*) INTO o_rows_read
    FROM XMLTABLE('/DATA_DS/ROWSET/ROW' PASSING XMLTYPE(p_xml));

  -- ── 4. the before-image, BEFORE the merge destroys it ──────
  -- The MERGE below overwrites every non-key column. Once it has run, the
  -- previous project, task, billable type and percentage are gone, and a
  -- Reversal that must "subtract the hours from the OLD project" has nothing
  -- left to name. There is no recovering it afterwards -- only the new value
  -- exists -- so it is captured here or not at all.
  --
  -- Both sides are stored as a JSON array of {name,value}. An array rather than
  -- an object because the reader iterates unknown keys, and a whole row rather
  -- than one record per changed column because an adjustment needs the row as a
  -- coherent whole. V_OC_TIME_SYNC_CHANGE_COL derives the per-column view.
  --
  -- LEFT JOIN, so a genuinely new row is captured as INSERT with a null
  -- OLD_ROW: a new allocation is an addition and needs an Adjustment(+) just as
  -- much as a moved one needs the pair.
  --
  -- Same transaction as the MERGE. If the merge fails, the capture rolls back
  -- with it -- a recorded change that did not happen would be worse than none.
  IF v_capture = 'Y' AND v_keyexpr IS NOT NULL THEN
    FOR c IN (SELECT REGEXP_SUBSTR(LTRIM(v_ins, ','), '[^,]+', 1, LEVEL) AS nm
                FROM dual
             CONNECT BY LEVEL <= REGEXP_COUNT(v_ins, ','))
    LOOP
      v_oldj := v_oldj || ',JSON_OBJECT(''name'' VALUE ''' || c.nm ||
                ''', ''value'' VALUE TO_CHAR(t.' || c.nm || '))';
      v_newj := v_newj || ',JSON_OBJECT(''name'' VALUE ''' || c.nm ||
                ''', ''value'' VALUE TO_CHAR(s.' || c.nm || '))';
    END LOOP;

    v_cap :=
      'INSERT INTO oc_time_sync_change (report_name, target_table, row_key, '
   || '       change_type, old_row, new_row, created_by) '
   || 'SELECT :1, :2, SUBSTR(' || LTRIM(v_keyexpr, '|''') || ', 1, 400), '
   || '       CASE WHEN t.ROWID IS NULL THEN ''INSERT'' ELSE ''UPDATE'' END, '
   || '       CASE WHEN t.ROWID IS NULL THEN NULL ELSE JSON_ARRAY('
   ||            LTRIM(v_oldj, ',') || ' RETURNING CLOB) END, '
   || '       JSON_ARRAY(' || LTRIM(v_newj, ',') || ' RETURNING CLOB), :3 '
   || '  FROM (SELECT ' || LTRIM(v_src, ',')
   || '          FROM XMLTABLE(''/DATA_DS/ROWSET/ROW'' PASSING :4 COLUMNS '
   ||                LTRIM(v_cols, ',') || ') x) s '
   || '  LEFT JOIN ' || v_tab || ' t ON (' || LTRIM(v_on, ' AND') || ') '
   -- Only actual differences. Re-reading an overlapping window is normal and
   -- most rows come back identical; recording those would bury the real
   -- changes under thousands of no-ops every single night.
   || ' WHERE t.ROWID IS NULL '
   || '    OR JSON_ARRAY(' || LTRIM(v_oldj, ',') || ' RETURNING CLOB) <> '
   || '       JSON_ARRAY(' || LTRIM(v_newj, ',') || ' RETURNING CLOB)';

    BEGIN
      EXECUTE IMMEDIATE v_cap
        USING NVL(p_report_name, v_tab), v_tab, NVL(p_actor, 'OIC'),
              XMLTYPE(p_xml);
    EXCEPTION WHEN OTHERS THEN
      -- Capture must never stop a load. A sync that refuses to run because it
      -- could not write an audit row helps nobody, but a SILENT failure to
      -- capture is exactly what this file exists to prevent -- so it is
      -- recorded where the other sync failures already are.
      DECLARE
        v_ce VARCHAR2(400) := SUBSTR(SQLERRM, 1, 400);
      BEGIN
        INSERT INTO oc_time_sync_failed
               (job_run_id, entity_type, entity_key, failure_reason, failure_code)
        VALUES (NULL, NVL(p_report_name, v_tab), 'CHANGE_CAPTURE',
                'Before-image capture failed; the merge still ran, so the '
             || 'previous values for this batch are NOT recoverable: ' || v_ce,
                -1);
      END;
    END;
  END IF;

  -- If the lookup resolves nothing at all, the parent almost certainly has not
  -- been loaded yet -- which is a RUN_ORDER problem, not a data problem, and
  -- saying so is worth far more than ORA-02291 or a table of null keys.
  IF v_fkcol IS NOT NULL THEN
    DECLARE
      v_unres NUMBER;
    BEGIN
      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM (SELECT ' || v_fksql || ' AS k FROM XMLTABLE(' ||
        '''/DATA_DS/ROWSET/ROW'' PASSING :1 COLUMNS ' || LTRIM(v_cols, ',') ||
        ') x) WHERE k IS NULL'
        INTO v_unres USING XMLTYPE(p_xml);
      IF v_unres > 0 AND v_unres = o_rows_read THEN
        o_message := 'None of the ' || o_rows_read || ' rows could resolve '
                  || v_fkcol || '. The parent is probably not loaded yet -- '
                  || 'check RUN_ORDER, this feed must run after its parent.';
        RETURN;
      ELSIF v_unres > 0 THEN
        o_message := v_unres || ' row(s) could not resolve ' || v_fkcol || '. ';
      END IF;
    END;
  END IF;

  EXECUTE IMMEDIATE v_sql USING XMLTYPE(p_xml);
  o_rows_merged := SQL%ROWCOUNT;
  COMMIT;

  o_status  := 'Success';
  o_message := NVL(o_message, '') || o_rows_merged || ' of ' || o_rows_read
            || ' row(s) merged into ' || v_tab || '.';

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    o_status  := 'Failed';
    -- The ORA number matters to whoever reads SYNC_STATUS later, so it is kept
    -- rather than replaced with a friendly sentence.
    o_message := SUBSTR('Load into ' || v_tab || ' failed: ' || SQLERRM, 1, 2000);
    -- Recorded where the other sync failures already live, so one queue shows
    -- everything rather than this path being invisible.
    BEGIN
      DECLARE
        -- SQLCODE IS PL/SQL-ONLY AND CANNOT APPEAR INSIDE A SQL STATEMENT.
        -- Used directly in the VALUES list it is ORA-00984, "column not
        -- allowed here" -- the parser reads it as a column name. Same family as
        -- the SQLERRM trap, and the identical mistake is already commented in
        -- 13_ords_time_admin.sql, which is where this should have been copied
        -- from. SQLERRM on the line above is fine: that is a PL/SQL assignment,
        -- not a SQL statement.
        v_code NUMBER := SQLCODE;
      BEGIN
        INSERT INTO oc_time_sync_failed
               (job_run_id, entity_type, entity_key, failure_reason, failure_code)
        VALUES (NULL, NVL(p_report_name, v_tab), v_tab,
                SUBSTR(o_message, 1, 1000), v_code);
        COMMIT;
      END;
    EXCEPTION WHEN OTHERS THEN NULL;   -- never let logging mask the real error
    END;
END oc_time_load_xml;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A26
COLUMN object_type FORMAT A10
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_SYNC_CONFIG','OC_TIME_LOAD_XML')
 ORDER BY object_type;

COLUMN bip_report_name FORMAT A16
COLUMN target_table    FORMAT A22
COLUMN bip_report_path FORMAT A40

SELECT run_order, bip_report_name, enabled_flag,
       NVL(target_table,'(none)') AS target_table, schedule_tag, sync_mode
  FROM oc_time_sync_config
 ORDER BY run_order;

PROMPT (INT 001 must filter on ENABLED_FLAG = 'Y' and ORDER BY RUN_ORDER.)

PROMPT
PROMPT --- how each feed is matched -------------------------------
COLUMN matched_on FORMAT A34

-- Worth showing plainly: '(discovered)' means the loader will go looking in
-- USER_CONSTRAINTS, which cannot see a unique INDEX. OC_TIME_TASK is keyed by
-- one, so TASKS must read PROJECT_ID,TASK_CODE here and not '(discovered)'.
SELECT bip_report_name,
       NVL(target_table,'(none)')     AS target_table,
       NVL(merge_key,'(discovered)')  AS matched_on,
       NVL(fk_column,'-')             AS fk_column
  FROM oc_time_sync_config
 WHERE enabled_flag = 'Y'
 ORDER BY run_order;

PROMPT Done. INT 001 reads OC_TIME_SYNC_CONFIG; INT 002 calls OC_TIME_LOAD_XML.
--== END 16_oic_sync_config.sql ==

PROMPT [n/m] 19_sync_change_capture.sql - before-image capture + append-only

--==============================================================
-- BEGIN 19_sync_change_capture.sql
--==============================================================
--==============================================================
-- time/19_sync_change_capture.sql
-- O2C Timesheet Module — keep the before-image the sync would otherwise destroy
--
-- WHY THIS HAS TO EXIST BEFORE ANY ADJUSTMENT RULE DOES
--
-- OC_TIME_LOAD_XML merges master data with a plain UPDATE SET t.col = s.col.
-- The moment the daily sync runs, the PREVIOUS project, task, billable type and
-- allocation percentage are gone -- overwritten, with nothing recording that
-- they were ever different.
--
-- The requirement is that a master-data change becomes a Reversal (subtract the
-- hours from the old project/task) and an Adjustment (add them to the new),
-- posted into the next open period. That is impossible to compute afterwards:
-- by the time anything looks, only the NEW value exists. The old one has to be
-- captured at the moment of the merge or it is not recoverable at all.
--
-- So this file is deliberately only the CAPTURE half. It records what changed,
-- from what, to what, and leaves ADJUSTMENT_STATUS = 'Pending'. It raises no
-- adjustment and applies no rule, because the flag/scenario workbook is still
-- out for functional validation and the rules are not settled. Capture is
-- unambiguous and blocks everything downstream; generation is not and does not.
--
-- OC_TS_AUDIT already models the timesheet side of this (OLD_/NEW_ project,
-- task, hours, bill type, and a CHANGE_TYPE that already includes 'Adjustment'
-- and 'Reversal'). This is the master-data side, which nothing fed.
--
-- Idempotent. Depends on: time/02, time/04, time/06, time/16
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] OC_TIME_SYNC_CHANGE — the before-image
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_sync_change (
      CHANGE_ID       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      REPORT_NAME     VARCHAR2(60 CHAR)  NOT NULL,
      TARGET_TABLE    VARCHAR2(30 CHAR)  NOT NULL,
      -- The merge key's values, concatenated, exactly as the loader matched on
      -- them. Text because the key differs per table -- (project, task code)
      -- here, (project, employee, start date) there -- and a typed column set
      -- would have to be the union of every table's key.
      ROW_KEY         VARCHAR2(400 CHAR) NOT NULL,
      CHANGE_TYPE     VARCHAR2(10 CHAR)  NOT NULL,
      -- The whole row, both sides, as JSON. NOT one row per changed column.
      --
      -- Per-column rows read nicely and are wrong here: an adjustment needs the
      -- row as a COHERENT WHOLE -- project AND task AND billable type AND dates
      -- as they stood together -- and reassembling that from scattered column
      -- rows means trusting that they all came from one merge. The JSON is the
      -- state, and V_OC_TIME_SYNC_CHANGE_COL below splits it per column for
      -- anyone who wants to read it that way.
      OLD_ROW         CLOB,
      NEW_ROW         CLOB,
      -- Pending until something acts on it. NOTHING sets this to Raised yet --
      -- the generation rules are not settled. A queue that is never drained is
      -- visible; a change that was never recorded is not.
      ADJUSTMENT_STATUS VARCHAR2(20 CHAR) DEFAULT 'Pending' NOT NULL,
      ADJUSTMENT_ID   NUMBER,
      DECIDED_BY      VARCHAR2(100 CHAR),
      DECIDED_ON      TIMESTAMP,
      DECISION_NOTE   VARCHAR2(1000 CHAR),
      SYNC_JOB_RUN_ID NUMBER,
      CREATED_BY      VARCHAR2(100 CHAR) DEFAULT 'SYSTEM'   NOT NULL,
      CREATED_ON      TIMESTAMP          DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY      VARCHAR2(100 CHAR),
      UPDATED_ON      TIMESTAMP,
      CONSTRAINT chk_oc_tsch_type CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
      CONSTRAINT chk_oc_tsch_adjst   CHECK (adjustment_status IN
        ('Pending','Raised','NotRequired','Ignored'))
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CHANGE created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CHANGE already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- The queue read pattern: everything still Pending, oldest first.
BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsch_pending ON oc_time_sync_change '
                 || '(adjustment_status, created_on)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsch_row ON oc_time_sync_change '
                 || '(target_table, row_key)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/4] CAPTURE_CHANGES on the sync config
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_config ADD '
                 || '(capture_changes CHAR(1) DEFAULT ''Y'' NOT NULL)';
  DBMS_OUTPUT.PUT_LINE('CAPTURE_CHANGES added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN
    DBMS_OUTPUT.PUT_LINE('CAPTURE_CHANGES already present - skipped.');
  ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_sync_config ADD CONSTRAINT
    chk_oc_tsc_capture CHECK (capture_changes IN ('Y','N'))~';
EXCEPTION WHEN OTHERS THEN IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/

-- ON for everything, by instruction: costing and accrual are derived from all
-- of it, so there is no feed whose changes are safely ignorable. CALENDAR and
-- SHIFTS included -- a changed working day moves the hours a default produces.
UPDATE oc_time_sync_config SET capture_changes = 'Y' WHERE capture_changes IS NULL;
COMMIT;

PROMPT ============================================================
PROMPT [3/4] Append-only: an audit that can be edited is not one
PROMPT ============================================================

-- OC_TS_AUDIT and OC_TS_APPROVAL are the evidence trail for who approved what
-- and what was changed. Nothing prevented an UPDATE or a DELETE on either.
--
-- These are BEFORE statement-level triggers, so they refuse the operation
-- outright rather than logging it and letting it through. -20026 continues the
-- module's -20001..-20025 range; ORDS maps that band to 400 with the message
-- passed through, so a caller sees the reason rather than a 500.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(30);
  v t_tab := t_tab('OC_TS_AUDIT', 'OC_TS_APPROVAL');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    EXECUTE IMMEDIATE
      'CREATE OR REPLACE TRIGGER trg_' || LOWER(v(i)) || '_append_only ' ||
      'BEFORE UPDATE OR DELETE ON ' || v(i) || ' ' ||
      'BEGIN ' ||
      '  RAISE_APPLICATION_ERROR(-20026, ''' || v(i) ||
      ' is append-only. A correction is a NEW row, never an edit to an '     ||
      'existing one -- the point of the trail is that it cannot be rewritten.''); ' ||
      'END;';
    DBMS_OUTPUT.PUT_LINE('append-only trigger on ' || v(i));
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [4/4] The two genuine WHO gaps
PROMPT ============================================================

-- Audited 10-Aug-2026: 15 of 25 tables carry the full CREATED_BY/CREATED_ON/
-- UPDATED_BY/UPDATED_ON set. Most of the rest are EVENT tables where the row is
-- the event and the actor is already named -- OC_TS_APPROVAL has ACTOR_EMP_ID
-- and ACTION_ON, OC_TS_ADJUSTMENT has APPLIED_BY/ON, OC_TIME_SYNC_JOB has
-- TRIGGERED_BY. Adding generic columns there would duplicate what is recorded.
--
-- These two are different: both are mutable and neither says who touched them.
DECLARE
  TYPE t_col IS RECORD (tab VARCHAR2(40), spec VARCHAR2(120));
  TYPE t_tab IS TABLE OF t_col;
  v t_tab := t_tab(
    -- PROCESSED_FLAG / PULLED_ON / BATCH_ID are updated by the CONSUMER, and
    -- nothing recorded which consumer or when it claimed the row.
    t_col('XX_O2C_TIMESHEET_ACCRUAL_IF',
          'UPDATED_BY VARCHAR2(100 CHAR), UPDATED_ON TIMESTAMP'),
    -- A session row is created for a person at sign-in; without CREATED_BY
    -- there is no record of which path issued the token.
    t_col('OC_TIME_SESSION', 'CREATED_BY VARCHAR2(100 CHAR)'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE ' || v(i).tab || ' ADD (' || v(i).spec || ')';
      DBMS_OUTPUT.PUT_LINE('added to ' || v(i).tab || ': ' || v(i).spec);
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE = -1430 THEN
        DBMS_OUTPUT.PUT_LINE(v(i).tab || ' already has them - skipped.');
      ELSE RAISE; END IF;
    END;
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT Views
PROMPT ============================================================

-- The queue, for whoever builds the generation step.
CREATE OR REPLACE VIEW v_oc_time_sync_change_queue AS
SELECT c.change_id, c.report_name, c.target_table, c.row_key, c.change_type,
       c.old_row, c.new_row, c.adjustment_status, c.created_on,
       cfg.run_order, cfg.purpose
  FROM oc_time_sync_change c
  LEFT JOIN oc_time_sync_config cfg ON cfg.bip_report_name = c.report_name
 WHERE c.adjustment_status = 'Pending'
 ORDER BY c.created_on, c.change_id;

-- Column-level, derived rather than stored. JSON_TABLE over the two documents
-- so "what actually differed" is a query, not a second write path that could
-- disagree with the first.
CREATE OR REPLACE VIEW v_oc_time_sync_change_col AS
SELECT c.change_id, c.report_name, c.target_table, c.row_key, c.change_type,
       n.col_name,
       o.old_val, n.new_val, c.adjustment_status, c.created_on
  FROM oc_time_sync_change c,
       JSON_TABLE(c.new_row, '$[*]'
         COLUMNS (col_name  VARCHAR2(128) PATH '$.name',
                  new_val   VARCHAR2(4000) PATH '$.value')) n,
       JSON_TABLE(c.old_row, '$[*]'
         COLUMNS (o_name    VARCHAR2(128)  PATH '$.name',
                  old_val   VARCHAR2(4000) PATH '$.value')) o
 WHERE o.o_name = n.col_name
   AND DECODE(o.old_val, n.new_val, 1, 0) = 0;

PROMPT
PROMPT Verification
PROMPT ============================================================

COLUMN object_name FORMAT A34
COLUMN object_type FORMAT A10
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_SYNC_CHANGE',
                       'V_OC_TIME_SYNC_CHANGE_QUEUE','V_OC_TIME_SYNC_CHANGE_COL',
                       'TRG_OC_TS_AUDIT_APPEND_ONLY','TRG_OC_TS_APPROVAL_APPEND_ONLY')
 ORDER BY object_type, object_name;

PROMPT
PROMPT Nothing drains the queue yet, by design. Every captured change stays
PROMPT Pending until the adjustment rules are settled -- an undrained queue is
PROMPT visible, a change that was never recorded is not.
--== END 19_sync_change_capture.sql ==

PROMPT [n/m] 20_retro_reallocation.sql - retro allocation change -> Reversal/Adjustment

--==============================================================
-- BEGIN 20_retro_reallocation.sql
--==============================================================
--==============================================================
-- time/20_retro_reallocation.sql
-- O2C Timesheet Module — a retro allocation change becomes Reversal/Adjustment
--
-- THE SCENARIO, stated by the business owner 10-Aug-2026:
--
--   Person A is allocated to PRJ 444, task Onshore, to 31-Jul. July time is
--   logged, approved, and already sent to Project Costing and revenue accrual.
--   On 5-Aug it is decided that 444 actually ended on 15-Jul and the person
--   moved to a different project from 16-Jul.
--
--   July is closed. The clocked hours cannot be changed. So the hours booked to
--   444 from 16-Jul onward must be REMOVED from 444 and MOVED to the new
--   project -- as an adjustment, in the next open period.
--
-- Everything that does the moving already existed and is untouched here:
--
--   apply_adjustment    writes OC_TS_ADJUSTMENT with SOURCE_PERIOD = the month
--                       the work happened in and POST_PERIOD = the open one
--   approve_adjustment  on approval materialises -ABS(old_hours) as 'Reversal'
--                       against the old project/task and +ABS(new_hours) as
--                       'Adjustment' against the new one, in the OPEN period,
--                       carrying the original work date. The closed book is
--                       never touched.
--   run_accrual_top_up  carries those entries to the accrual interface, which
--                       confirm_month could not because it had already run
--
-- WHAT WAS MISSING is only the two ends: nothing expanded a DATE RANGE into
-- per-day adjustments, and nothing noticed the allocation had changed at all.
-- This file is those two ends and no new rules.
--
-- Deliberately NOT in OC_TIME_PKG. Every rule these touch -- the backdating
-- window, the dual approval, the period resolution, the sign convention --
-- stays in the package and is reached by calling it. These two are
-- orchestration: a loop and a queue reader. Putting them here keeps 09 (already
-- compiled, ~3000 lines) untouched.
--
-- Idempotent. Depends on: time/03, time/05, time/09, time/19
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] OC_TIME_RETRO_REALLOC — a date range, one day at a time
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_retro_realloc(
  p_employee_id    IN  VARCHAR2,
  p_old_project_id IN  NUMBER,
  p_old_task_id    IN  NUMBER DEFAULT NULL,   -- null = every task on the project
  p_new_project_id IN  NUMBER,
  p_new_task_id    IN  NUMBER DEFAULT NULL,   -- null = the default task rule
  p_from_date      IN  DATE,
  p_to_date        IN  DATE,
  p_reason         IN  VARCHAR2,
  p_actor          IN  VARCHAR2 DEFAULT 'SYNC',
  o_raised         OUT NUMBER,
  o_hours          OUT NUMBER,
  o_message        OUT VARCHAR2)
AS
  v_task   NUMBER := p_new_task_id;
  v_id     NUMBER;
  v_err    VARCHAR2(400);
BEGIN
  o_raised := 0;
  o_hours  := 0;

  -- The task on the new project. Resolved with the SAME rule populate_month
  -- uses, deliberately: the adjustment must land on the task the prepopulation
  -- would have chosen, or the moved hours sit on a different task from every
  -- subsequent day's hours on the same project and the project's own breakdown
  -- disagrees with itself.
  --
  -- First chargeable billable WBS task, ordered by TASK_CODE. Not by TASK_ID --
  -- that is the local identity column, so "the first task" would mean
  -- "whichever row the sync happened to insert first", which on project 444 was
  -- Leave. SORT_ORDER is never populated, so it cannot be the order either.
  IF v_task IS NULL THEN
    BEGIN
      SELECT task_id INTO v_task
        FROM (SELECT task_id FROM oc_time_task
               WHERE project_id      = p_new_project_id
                 AND task_type       = 'WBS'
                 AND status          = 'Active'
                 AND chargeable_flag = 'Y'
                 AND billable_type   = 'Billable'
               ORDER BY task_code)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      o_message := 'Project ' || p_new_project_id || ' has no chargeable '
                || 'billable WBS task, so there is nothing to move the hours '
                || 'to. Load its tasks before re-running.';
      RETURN;
    END;
  END IF;

  -- One adjustment PER DAY PER LINE, not one for the range.
  --
  -- OC_TS_ADJUSTMENT.WORK_DATE is a single day and that is right: Project
  -- Costing books to the day the work happened, so a range collapsed into one
  -- row would lose which days the hours belonged to and cost them all to
  -- whatever date was chosen. The 16-Jul..5-Aug example is ~15 rows, and that
  -- is the correct number.
  --
  -- Only 'Actual' rows with hours. A day already carrying a Reversal has been
  -- adjusted before; re-reversing it would double-count, and the guard is the
  -- entry_type filter rather than a flag on the adjustment.
  FOR e IN (SELECT e.entry_date, e.project_id, e.task_id, e.hours
              FROM oc_ts_entry e
              JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
             WHERE w.employee_id = p_employee_id
               AND e.project_id  = p_old_project_id
               AND (p_old_task_id IS NULL OR e.task_id = p_old_task_id)
               AND e.entry_date BETWEEN TRUNC(p_from_date) AND TRUNC(p_to_date)
               AND e.entry_type  = 'Actual'
               AND NVL(e.hours, 0) > 0
             ORDER BY e.entry_date, e.project_id, e.task_id)
  LOOP
    BEGIN
      v_id := oc_time_pkg.apply_adjustment(
                p_employee_id    => p_employee_id,
                p_work_date      => e.entry_date,
                p_old_project_id => e.project_id,
                p_old_task_id    => e.task_id,
                p_old_hours      => e.hours,
                p_new_project_id => p_new_project_id,
                p_new_task_id    => v_task,
                p_new_hours      => e.hours,   -- moved, not changed
                p_reason         => p_reason,
                p_adj_kind       => 'RetroWBS',
                p_actor          => p_actor);
      o_raised := o_raised + 1;
      o_hours  := o_hours + e.hours;
    EXCEPTION WHEN OTHERS THEN
      -- One day outside the RULE-019 window must not abandon the rest. The
      -- caller gets the count that DID succeed plus the first refusal, because
      -- a partial move that reports total success is the worst outcome here.
      v_err := NVL(v_err, SUBSTR(SQLERRM, 1, 300));
    END;
  END LOOP;

  o_message := o_raised || ' adjustment(s) raised for ' || o_hours || ' hour(s)'
            || CASE WHEN v_err IS NULL THEN
                 ', awaiting the old and new project managers (RA-014).'
               ELSE '. AT LEAST ONE DAY WAS REFUSED: ' || v_err END;
END oc_time_retro_realloc;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/3] OC_TIME_RAISE_ALLOC_ADJ — drive it from the sync
PROMPT ============================================================

-- Reads what OC_TIME_LOAD_XML captured and turns an allocation whose END DATE
-- MOVED EARLIER into the adjustments above. Automatic and unconfirmed, by
-- instruction 10-Aug-2026: Fusion is authoritative about who was allocated
-- where, so a human re-confirming it would only be re-typing what the sync
-- already knows.
--
-- The adjustments are still raised 'Awaiting Approval', which is a DIFFERENT
-- question and deliberately unchanged. RA-014 requires the old and new project
-- managers to agree before hours actually move, and nothing in "raise it
-- automatically" says "and move the hours without either manager seeing it".
-- Auto-approving is the irreversible direction; raising is not.
--
-- Only the end date moving EARLIER matters. Later means more days are covered,
-- not fewer, so nothing already booked becomes wrong.
CREATE OR REPLACE PROCEDURE oc_time_raise_alloc_adj(
  p_actor    IN  VARCHAR2 DEFAULT 'SYNC',
  o_examined OUT NUMBER,
  o_raised   OUT NUMBER,
  o_message  OUT VARCHAR2)
AS
  v_old_end  DATE;
  v_new_end  DATE;
  v_emp      VARCHAR2(50);
  v_proj     NUMBER;
  v_newproj  NUMBER;
  v_cnt      NUMBER;
  v_hrs      NUMBER;
  v_msg      VARCHAR2(2000);
  v_total    NUMBER := 0;

  FUNCTION jval(p_doc CLOB, p_name VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(4000);
  BEGIN
    -- The capture stores an ARRAY of {name,value}; pull one by name.
    SELECT MAX(x.val) INTO v
      FROM JSON_TABLE(p_doc, '$[*]'
             COLUMNS (nm  VARCHAR2(128)  PATH '$.name',
                      val VARCHAR2(4000) PATH '$.value')) x
     WHERE x.nm = p_name;
    RETURN v;
  END;
BEGIN
  o_examined := 0; o_raised := 0;

  FOR c IN (SELECT change_id, old_row, new_row
              FROM oc_time_sync_change
             WHERE target_table      = 'OC_TIME_ALLOCATION'
               AND change_type       = 'UPDATE'
               AND adjustment_status = 'Pending'
             ORDER BY created_on, change_id)
  LOOP
    o_examined := o_examined + 1;

    v_old_end := TO_DATE(jval(c.old_row, 'END_DATE'), 'YYYY-MM-DD');
    v_new_end := TO_DATE(jval(c.new_row, 'END_DATE'), 'YYYY-MM-DD');
    v_emp     := jval(c.new_row, 'EMPLOYEE_ID');
    v_proj    := TO_NUMBER(jval(c.new_row, 'PROJECT_ID'));

    -- NVL to the far future: an allocation with no end date was open-ended, and
    -- giving it one for the first time is the commonest form of this change.
    IF NVL(v_new_end, DATE '4712-12-31') >= NVL(v_old_end, DATE '4712-12-31')
       OR v_emp IS NULL OR v_proj IS NULL THEN
      UPDATE oc_time_sync_change
         SET adjustment_status = 'NotRequired',
             decision_note     = 'End date did not move earlier.',
             decided_by = p_actor, decided_on = SYSTIMESTAMP
       WHERE change_id = c.change_id;
      CONTINUE;
    END IF;

    -- Where the hours go. The person's allocation that covers the day AFTER the
    -- new end date -- which is precisely the "allocate the resource to a
    -- different project from 16th July" half of the change.
    BEGIN
      SELECT project_id INTO v_newproj
        FROM (SELECT a.project_id
                FROM oc_time_allocation a
               WHERE a.employee_id = v_emp
                 AND a.project_id <> v_proj
                 AND a.start_date <= v_new_end + 1
                 AND (a.end_date IS NULL OR a.end_date >= v_new_end + 1)
               ORDER BY a.start_date DESC)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      -- Left the project and joined nothing. The hours are still wrong on the
      -- old project, but there is nowhere to move them, and inventing a
      -- destination would be worse than saying so.
      UPDATE oc_time_sync_change
         SET adjustment_status = 'Pending',
             decision_note     = 'End date moved to '
                              || TO_CHAR(v_new_end,'DD-MON-YYYY')
                              || ' but the employee has no other allocation '
                              || 'covering the following day. Hours after that '
                              || 'date need a destination project.',
             decided_on = SYSTIMESTAMP
       WHERE change_id = c.change_id;
      CONTINUE;
    END;

    oc_time_retro_realloc(
      p_employee_id    => v_emp,
      p_old_project_id => v_proj,
      p_old_task_id    => NULL,               -- every task on the old project
      p_new_project_id => v_newproj,
      p_new_task_id    => NULL,               -- the default task rule
      p_from_date      => v_new_end + 1,      -- the day after the new end date
      p_to_date        => SYSDATE,            -- through today
      p_reason         => 'Allocation on project ' || v_proj || ' end-dated to '
                       || TO_CHAR(v_new_end,'DD-MON-YYYY') || ' in Fusion.',
      p_actor          => p_actor,
      o_raised         => v_cnt,
      o_hours          => v_hrs,
      o_message        => v_msg);

    UPDATE oc_time_sync_change
       SET adjustment_status = CASE WHEN NVL(v_cnt,0) > 0 THEN 'Raised'
                                    ELSE 'NotRequired' END,
           decision_note     = v_msg,
           decided_by = p_actor, decided_on = SYSTIMESTAMP
     WHERE change_id = c.change_id;

    o_raised := o_raised + NVL(v_cnt, 0);
    v_total  := v_total + NVL(v_hrs, 0);
  END LOOP;

  COMMIT;
  o_message := o_examined || ' allocation change(s) examined, ' || o_raised
            || ' adjustment(s) raised covering ' || v_total || ' hour(s).';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    o_message := SUBSTR('Raising allocation adjustments failed: ' || SQLERRM, 1, 2000);
END oc_time_raise_alloc_adj;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A30
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_RETRO_REALLOC','OC_TIME_RAISE_ALLOC_ADJ')
 ORDER BY object_name;

PROMPT
PROMPT Both must be VALID. Then, after each sync:
PROMPT
PROMPT   DECLARE n NUMBER; r NUMBER; m VARCHAR2(2000);
PROMPT   BEGIN oc_time_raise_alloc_adj('SYNC', n, r, m);
PROMPT         DBMS_OUTPUT.PUT_LINE(m); END;
PROMPT
PROMPT Raised adjustments sit 'Awaiting Approval' for the OLD and NEW project
PROMPT managers (RA-014). On approval they materialise as Reversal(-) on the old
PROMPT project and Adjustment(+) on the new, in the OPEN period, carrying the
PROMPT original work date -- and run_accrual_top_up carries them to accrual.
--== END 20_retro_reallocation.sql ==

-- 15 is NOT here: it creates a table the package body reads, so it runs before
-- step 09 above. Moving it back would reintroduce nine ORA-00942s.

-- ── REST surface ─────────────────────────────────────────────
PROMPT >>> 12 ORDS oc.time            (employee)

--==============================================================
-- BEGIN ords/11_ords_time.sql
--==============================================================
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
--   POST weeks/:id/revoke                        pull a submission back
--   GET  salaryhold/mine/:employeeId            my held dates (PROC-007)
--   POST salaryhold/day/:holdDayId/correct      correct one held date
--   GET  allocation/:employeeId                  allocation pop-up
--   GET  tasks/:projectId                        task LOV (WBS + common)
--   GET  projects/:employeeId                    projects the employee may charge
--   GET  cutoffs/:periodId                       cut-off display
--   GET  lookups/:type                           any seeded dictionary
--   GET  rejection/:tsWeekId                     reason + remarks + rejected dates
--   GET  weeks/:tsWeekId/activity               submitted / rejected / approved trail
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
             -- Deliberately NOT oc_time_pkg.get_open_period_id: that function
             -- RAISES ORA-20017 when nothing is Open, which is right for the
             -- callers that cannot proceed without a period (populate_daily,
             -- apply_adjustment, jobs/daily) but fatal here. Sign-in must never
             -- depend on a period being open, or nobody can log in between
             -- periods or before the first one is set up - the whole app becomes
             -- unreachable with a 555. NULL is a perfectly good answer; the shell
             -- already treats it as "no open period".
             (SELECT period_id FROM (
                 SELECT p.period_id
                   FROM oc_time_period p
                  WHERE p.status = 'Open'
                  ORDER BY CASE WHEN TRUNC(SYSDATE)
                                     BETWEEN p.start_date AND p.end_date
                                THEN 0 ELSE 1 END, p.start_date)
                WHERE ROWNUM = 1) AS open_period_id
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
             defaulted_flag, defaulted_by, late_submission_flag,
             advance_closure_flag, overridden_flag,
             has_reversal_flag, has_adjustment_flag,
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
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        -- :body_text is ORDS's implicit CLOB of the whole payload, and the
        -- scalars are read out of it rather than bound by name. A payload
        -- carrying a JSON ARRAY cannot be bound field by field: ORDS has no SQL
        -- type for the array, so the request fails with ORA-17004 before any of
        -- this runs and the caller sees only "The request could not be
        -- processed for a user defined resource". :cells was still a named bind
        -- here after the other handlers were converted, so every Save draft and
        -- every Submit failed.
        v_body   CLOB := :body_text;
        v_source VARCHAR2(20);
        v_actor  VARCHAR2(100);
        v_saved  NUMBER := 0;
      BEGIN
        SELECT NVL(src,'Employee'), NVL(act,'VBCS_USER')
          INTO v_source, v_actor
          FROM JSON_TABLE(v_body, '$'
                 COLUMNS (src VARCHAR2(20)  PATH '$.source',
                          act VARCHAR2(100) PATH '$.actor'));

        FOR c IN (
          SELECT ts_week_id, project_id, task_id, entry_date, hours, unbilled_reason
            FROM JSON_TABLE(v_body, '$.cells[*]'
                   COLUMNS (
                     ts_week_id      NUMBER        PATH '$.tsWeekId',
                     project_id      NUMBER        PATH '$.projectId',
                     task_id         NUMBER        PATH '$.taskId',
                     entry_date      VARCHAR2(30)  PATH '$.entryDate',
                     hours           NUMBER        PATH '$.hours',
                     unbilled_reason VARCHAR2(60)  PATH '$.unbilledReason')))
        LOOP
          oc_time_pkg.save_entry(
            p_ts_week_id      => c.ts_week_id,
            p_project_id      => c.project_id,
            p_task_id         => c.task_id,
            -- toApiDate() appends T00:00:00Z, so the value is 20 chars, not 10.
            -- SUBSTR before TO_DATE rather than widening the format mask, which
            -- would have to know about the Z.
            p_entry_date      => TO_DATE(SUBSTR(c.entry_date,1,10),'YYYY-MM-DD'),
            p_hours           => c.hours,
            p_source          => v_source,
            p_unbilled_reason => c.unbilled_reason,
            p_actor           => v_actor);
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

-- ── POST weeks/:id/revoke ────────────────────────────────────
-- Pull back a submission made by mistake. Submitted only; once the manager has
-- approved, undoing it is their send-back, not the employee's revoke. The
-- package raises -20021/-20022 for those two refusals, both inside the band
-- mapped to 400 below so the UI can show the message verbatim.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'weeks/:id/revoke');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'weeks/:id/revoke', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(30);
      BEGIN
        oc_time_pkg.revoke_week(:id, NVL(:actor,'VBCS_USER'), :traceId);
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

-- ── GET salaryhold/mine/:employeeId  (PROC-007, employee) ────
-- The employee's own held dates. Their own id only: this endpoint returns
-- somebody's pay status, so it is keyed on the person asking and never on a
-- period alone.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time',
                       p_pattern => 'salaryhold/mine/:employeeId');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'salaryhold/mine/:employeeId',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT hold_day_id, hold_id, employee_id, employee_name, worker_type,
             period_id, period_name, work_date, day_name, ts_week_id,
             expected_hours, day_status, corrected_hours, correction_reason,
             corrected_on, approved_by, approved_on, reject_remarks,
             salary_status, held_on, window_expires_on, days_left, window_open
        FROM v_oc_ts_salary_hold_mine
       WHERE employee_id = :employeeId
       ORDER BY work_date
    ]');
  COMMIT;
END;
/

-- ── POST salaryhold/day/:holdDayId/correct  (employee) ───────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time',
                       p_pattern => 'salaryhold/day/:holdDayId/correct');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'salaryhold/day/:holdDayId/correct',
    p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'[
      DECLARE v_status VARCHAR2(20);
      BEGIN
        oc_time_pkg.correct_salary_hold_day(
          p_hold_day_id => :holdDayId,
          p_hours       => :hours,
          p_reason      => :reason,
          p_actor       => NVL(:actor,'VBCS_USER'));
        SELECT day_status INTO v_status FROM oc_ts_salary_hold_day
         WHERE hold_day_id = :holdDayId;
        COMMIT;
        :status_code := 200;
        HTP.P('{"holdDayId":' || :holdDayId || ',"dayStatus":"' || v_status || '"}');
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
         -- Only projects somebody tracks time against (Reuse Assessment 2.4).
         -- The Organization project below is exempt: it is created locally, not
         -- synced, so nothing would ever set its flag, and FLD-006 requires it
         -- to appear for every employee.
         AND p.time_entry_enabled = 'Y'
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

-- ── GET weeks/:tsWeekId/activity  (the prototype's workflow strip) ─
-- The employee's own decision trail: submitted, rejected by whom and why,
-- resubmitted, approved. The prototype puts this at the foot of My Timesheet
-- and it was the one part of the rejected-week screen with nothing behind it -
-- the banner said a manager had sent the week back but never which manager, and
-- nothing at all recorded that the employee had already resubmitted once.
--
-- Same view as the manager's audit/:tsWeekId. Deliberately the same one: two
-- histories of the same week that could disagree is worse than none.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time', p_pattern => 'weeks/:tsWeekId/activity');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time', p_pattern => 'weeks/:tsWeekId/activity',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'[
      SELECT a.activity_id, a.kind, a.scope, a.entry_date, a.change_type,
             a.change_reason, a.changed_by, a.changed_on,
             a.old_hours, a.new_hours, a.delta_hours
        FROM v_oc_ts_week_activity a
       WHERE a.ts_week_id = :tsWeekId
       ORDER BY a.changed_on, a.activity_id
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
--== END ords/11_ords_time.sql ==

PROMPT >>> 13 ORDS oc.time.approval   (manager)

--==============================================================
-- BEGIN ords/12_ords_time_approval.sql
--==============================================================
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
--   POST llc/generate                            build the absentee list
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
    p_source => q'[
      SELECT d.ts_week_id, d.employee_id, d.employee_name, d.worker_type,
             d.week_index, d.week_start, d.week_end, d.week_range, d.week_status,
             d.billable_hours, d.non_billable_hours, d.leave_hours,
             d.billing_loss_hours, d.total_hours, d.standard_hours,
             d.defaulted_flag, d.defaulted_by, d.late_submission_flag,
             d.advance_closure_flag,
             d.overridden_flag, d.locked_flag,
             d.has_reversal_flag, d.has_adjustment_flag,
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
        :status_code := CASE WHEN SQLCODE BETWEEN -20025 AND -20001 THEN 400 ELSE 500 END;
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
--== END ords/12_ords_time_approval.sql ==

PROMPT >>> 14 ORDS oc.time.admin      (admin + accrual pull)

--==============================================================
-- BEGIN ords/13_ords_time_admin.sql
--==============================================================
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
--== END ords/13_ords_time_admin.sql ==

PROMPT >>> 15 ORDS oc.time.auth       (login, logout, session, set-password)

--==============================================================
-- BEGIN ords/14_ords_time_auth.sql
--==============================================================
--==============================================================
-- time/ords/14_ords_time_auth.sql
-- O2C Timesheet Module — ORDS module oc.time.auth  (SIGN-IN surface)
--
-- Base path: /oc/time/auth/
-- Mirrors the O2C main application's oc_auth contract so the two apps behave
-- the same way and a user meets one login model, not two.
--
-- Endpoints
--   POST login          email + password        -> token, role, employee
--   POST logout         token                   -> ends the session
--   GET  session/:token validate + who am I     -> the resolved identity
--   POST set-password   first-time / reset      -> Invited becomes Active
--
-- Three access levels come out of EFFECTIVE_ROLE in V_OC_TIME_SIGNIN:
--   resource  ROLE_TIME_EMPLOYEE | ROLE_TIME_CONTRACTOR
--   manager   ROLE_TIME_MANAGER
--   admin     ROLE_TIME_ADMIN
--
-- Responses are emitted with HTP.P, never APEX_JSON - APEX is not installed on
-- every target schema and referencing it makes ORDS reject the handler with 403.
--
-- Depends on: time/11_auth.sql
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

BEGIN ORDS.DELETE_MODULE(p_module_name => 'oc.time.auth'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time.auth',
    p_base_path      => '/oc/time/auth/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'O2C Timesheet - sign-in (login, logout, session, set-password).');
  COMMIT;
END;
/

-- ── POST login ───────────────────────────────────────────────
-- Deliberately returns the SAME message for an unknown email and a wrong
-- password. Distinguishing them tells an attacker which addresses are real.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'login');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'login', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        v_email VARCHAR2(255) := LOWER(:email);
        v_uid   NUMBER;
        v_hash  VARCHAR2(128);
        v_stat  VARCHAR2(20);
        v_fail  NUMBER;
        v_tok   VARCHAR2(64);
        v_role  VARCHAR2(30);
        v_emp   VARCHAR2(50);
        v_name  VARCHAR2(200);
      BEGIN
        IF v_email IS NULL OR :password IS NULL THEN
          :status_code := 400;
          HTP.P('{"error":"Email and password are required."}');
          RETURN;
        END IF;

        BEGIN
          SELECT user_id, password_hash, status, failed_count
            INTO v_uid, v_hash, v_stat, v_fail
            FROM oc_time_user WHERE LOWER(email) = v_email;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          :status_code := 401;
          HTP.P('{"error":"Invalid email or password."}');
          RETURN;
        END;

        IF v_stat = 'Invited' THEN
          :status_code := 403;
          HTP.P('{"error":"Set your password before signing in.","status":"Invited"}');
          RETURN;
        ELSIF v_stat <> 'Active' THEN
          :status_code := 403;
          HTP.P('{"error":"This account is inactive. Contact your administrator."}');
          RETURN;
        END IF;

        -- Ten consecutive failures locks the account. Deliberately a hard lock
        -- needing an administrator, not a timed one: this is an internal tool
        -- with a known user list, so a lockout is a signal worth looking at.
        IF v_fail >= 10 THEN
          :status_code := 403;
          HTP.P('{"error":"Account locked after repeated failed sign-ins. Contact your administrator."}');
          RETURN;
        END IF;

        IF v_hash IS NULL OR v_hash <> oc_time_hash_password(v_email, :password) THEN
          UPDATE oc_time_user
             SET failed_count = failed_count + 1, updated_on = SYSTIMESTAMP
           WHERE user_id = v_uid;
          COMMIT;
          :status_code := 401;
          HTP.P('{"error":"Invalid email or password."}');
          RETURN;
        END IF;

        -- Via the function, not inline, so the token recipe lives in exactly
        -- one place — and so restoring DBMS_CRYPTO.RANDOMBYTES later is a
        -- one-line change there rather than a hunt through the handlers.
        -- See the security note on oc_time_new_token in 11_auth.sql.
        v_tok := oc_time_new_token;

        -- Clear this user's expired rows on the way through, so the table is
        -- self-maintaining without a scheduled job.
        DELETE FROM oc_time_session
         WHERE user_id = v_uid AND expires_on < SYSTIMESTAMP;

        INSERT INTO oc_time_session (user_id, token, expires_on, last_seen_on, client_info)
        VALUES (v_uid, v_tok, SYSTIMESTAMP + INTERVAL '24' HOUR, SYSTIMESTAMP,
                SUBSTR(:client_info,1,400));

        UPDATE oc_time_user
           SET failed_count = 0, last_login_on = SYSTIMESTAMP, updated_on = SYSTIMESTAMP
         WHERE user_id = v_uid;
        COMMIT;

        SELECT effective_role, employee_id, employee_name
          INTO v_role, v_emp, v_name
          FROM v_oc_time_signin WHERE token = v_tok;

        :status_code := 200;
        HTP.P('{"token":"'        || v_tok  ||
              '","userId":'       || v_uid  ||
              ',"employeeId":"'   || NVL(v_emp,'')  ||
              '","employeeName":"'|| REPLACE(NVL(v_name,''),'"','\"') ||
              '","role":"'        || v_role ||
              '","expiresInHours":24}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── GET session/:token ───────────────────────────────────────
-- Who am I. The shell calls this on every load so a refresh does not require
-- re-entering credentials, and so a revoked or expired token stops working
-- immediately rather than at the next write.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'session/:token');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'session/:token',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'~
      SELECT user_id, employee_id, employee_name, email, effective_role AS app_role,
             worker_type, manager_emp_id, base_country, deputed_country,
             std_hours_per_day, total_alloc_pct, open_period_id,
             TO_CHAR(expires_on,'YYYY-MM-DD HH24:MI:SS') AS expires_on
        FROM v_oc_time_signin
       WHERE token = :token
    ~');
  COMMIT;
END;
/

-- ── POST logout ──────────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'logout');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'logout', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      BEGIN
        DELETE FROM oc_time_session WHERE token = :token;
        COMMIT;
        -- 200 whether or not the token existed: an already-dead session is a
        -- successful logout from the caller's point of view.
        :status_code := 200;
        HTP.P('{"loggedOut":true}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST set-password ────────────────────────────────────────
-- First-time setup and self-service change. An Invited user supplies no current
-- password; an Active one must.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'set-password');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'set-password', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        v_email VARCHAR2(255) := LOWER(:email);
        v_uid   NUMBER;
        v_hash  VARCHAR2(128);
        v_stat  VARCHAR2(20);
      BEGIN
        IF :newPassword IS NULL OR LENGTH(:newPassword) < 8 THEN
          :status_code := 400;
          HTP.P('{"error":"The new password must be at least 8 characters."}');
          RETURN;
        END IF;

        BEGIN
          SELECT user_id, password_hash, status INTO v_uid, v_hash, v_stat
            FROM oc_time_user WHERE LOWER(email) = v_email;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          :status_code := 404;
          HTP.P('{"error":"No account for that email."}');
          RETURN;
        END;

        IF v_stat = 'Inactive' THEN
          :status_code := 403;
          HTP.P('{"error":"This account is inactive. Contact your administrator."}');
          RETURN;
        END IF;

        -- Changing a live password requires proving you know the current one.
        -- An Invited account has none yet, which is the whole point of invite.
        IF v_stat = 'Active' THEN
          IF :currentPassword IS NULL
             OR v_hash <> oc_time_hash_password(v_email, :currentPassword) THEN
            :status_code := 401;
            HTP.P('{"error":"The current password is not correct."}');
            RETURN;
          END IF;
        END IF;

        UPDATE oc_time_user
           SET password_hash = oc_time_hash_password(v_email, :newPassword),
               status        = 'Active',
               failed_count  = 0,
               updated_by    = NVL(:actor, v_email),
               updated_on    = SYSTIMESTAMP
         WHERE user_id = v_uid;

        -- Every existing session dies on a password change, so a stolen token
        -- cannot outlive the credential it came from.
        DELETE FROM oc_time_session WHERE user_id = v_uid;
        COMMIT;

        :status_code := 200;
        HTP.P('{"userId":' || v_uid || ',"status":"Active"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT ORDS module oc.time.auth defined.
PROMPT ============================================================
--== END ords/14_ords_time_auth.sql ==

PROMPT [n/m] ords/15_ords_time_sync.sql - the OIC surface (INT 001 / INT 002)

--==============================================================
-- BEGIN ords/15_ords_time_sync.sql
--==============================================================
--==============================================================
-- time/ords/15_ords_time_sync.sql
-- O2C Timesheet Module — the REST surface OIC actually needs
--
-- OC_TIME_SYNC_CONFIG and OC_TIME_LOAD_XML both existed with NO WAY TO REACH
-- THEM. The design in 16_oic_sync_config.sql reads:
--
--   INT 001  schedule -> read this config -> for each row, call INT 002
--   INT 002  REST trigger -> run the BIP report -> hand (TARGET_TABLE, raw XML)
--                         to OC_TIME_LOAD_XML -> write LASTSYNC_DATE back
--
-- INT 001 had nothing to read the config from and INT 002 had nowhere to send
-- the XML. The per-entity sync/worker, sync/project handlers in module 13 are
-- the OLDER JSON path and key differently; they are not this.
--
-- A SEPARATE MODULE, not more templates on oc.time.admin. Every ORDS file here
-- opens with DELETE_MODULE and redefines its own module wholesale, so templates
-- added to oc.time.admin from this file would be silently erased the next time
-- 13 is run. Two files owning one module is a trap, not a saving.
--
-- Idempotent. Depends on: time/16
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] Module oc.time.sync
PROMPT ============================================================

BEGIN
  ORDS.DELETE_MODULE(p_module_name => 'oc.time.sync');
EXCEPTION WHEN OTHERS THEN NULL;   -- not defined yet
END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time.sync',
    p_base_path      => '/oc/time/sync/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'Master-data sync surface for OIC (INT 001 / INT 002).');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [2/3] GET config — what INT 001 loops over
PROMPT ============================================================

-- LASTSYNC_DATE IS EMITTED AS 'YYYY-MM-DD' TEXT, deliberately, and this is the
-- one thing in this file most likely to be "tidied" into a real date column.
--
-- It is fed straight into the BIP report's P_LAST_SYNC parameter, and the SQL
-- there is TO_DATE(:P_LAST_SYNC,'YYYY-MM-DD'). An ISO timestamp --
-- 2026-08-10T00:00:00.000Z, which is what a JSON date column normally becomes
-- -- raises ORA-01861, "literal does not match format string". Formatting here
-- means OIC maps the field through untouched and cannot get it wrong.
--
-- NULL becomes an EMPTY STRING, never the text 'null'. Empty is NULL to Oracle,
-- so the report's NVL(..., DATE '1900-01-01') turns it into a full load, which
-- is exactly right for a feed that has never run. The literal word 'null' would
-- reach TO_DATE and raise ORA-01861 on the very first sync of every feed.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.sync', p_pattern => 'config');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.sync', p_pattern => 'config', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'~
      SELECT bip_report_name                          AS "reportName",
             bip_report_path                          AS "reportPath",
             target_table                             AS "targetTable",
             NVL(TO_CHAR(lastsync_date,'YYYY-MM-DD'), '') AS "lastSyncDate",
             -- P_EFFECTIVE_DATE, COMPUTED HERE RATHER THAN IN THE MAPPER.
             --
             -- The two schedules need different as-of dates and the difference
             -- is not cosmetic. O2C_Time_OIC_Build_Guide section 4: "Assign
             -- effectiveDate = the 1st of next month. Not today. The monthly
             -- run builds next month, so the HCM as-of date must be inside next
             -- month or you populate from THIS month's allocations." The BRD
             -- agrees -- the monthly program "populates hours for the next
             -- month based on the allocation for the next month".
             --
             -- Getting it wrong builds September from August's allocations and
             -- looks entirely normal, so it is not a mistake anyone catches by
             -- reading the output.
             --
             -- In the database because ADD_MONTHS handles the December -> January
             -- rollover and month lengths correctly, and hand-rolled date
             -- arithmetic in an OIC mapper is exactly where that breaks. OIC
             -- maps this field straight through to the parameter.
             CASE WHEN :scheduleTag = 'Monthly'
                  THEN TO_CHAR(ADD_MONTHS(TRUNC(SYSDATE,'MM'), 1), 'YYYY-MM-DD')
                  ELSE TO_CHAR(TRUNC(SYSDATE), 'YYYY-MM-DD')
             END                                      AS "effectiveDate",
             -- The period the monthly orchestrator then populates, so OIC does
             -- not have to work out which OC_TIME_PERIOD row "next month" is.
             -- Null on the daily run, which calls jobs/daily instead.
             CASE WHEN :scheduleTag = 'Monthly'
                  THEN (SELECT MAX(p.period_id) FROM oc_time_period p
                         WHERE p.start_date = ADD_MONTHS(TRUNC(SYSDATE,'MM'), 1))
             END                                      AS "targetPeriodId",
             sync_mode                                AS "syncMode",
             schedule_tag                             AS "scheduleTag",
             run_order                                AS "runOrder",
             sync_status                              AS "syncStatus",
             purpose                                  AS "purpose"
        FROM oc_time_sync_config
       WHERE enabled_flag = 'Y'
         -- Both schedules pick up the 'Both' rows. A missing tag returns the
         -- whole enabled set, which is the right default for a manual run.
         AND (:scheduleTag IS NULL
              OR schedule_tag = :scheduleTag
              OR schedule_tag = 'Both')
       ORDER BY run_order, bip_report_name
    ~');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [3/3] POST load/:reportName — where INT 002 sends the XML
PROMPT ============================================================

-- THE XML IS THE REQUEST BODY, not a field inside a JSON envelope.
--
-- A BIP extract is megabytes of XML. Putting it in a JSON string means every
-- quote and newline escaped by OIC and unescaped here, for no gain, and JSON
-- string binds are size-capped in ways the raw body is not. Posting the report
-- output verbatim as application/xml means OIC forwards what BIP returned
-- without touching it -- fewer places for it to be corrupted, and nothing to
-- get wrong in a mapper.
--
-- TARGET_TABLE is looked up from the config by report name rather than accepted
-- from the caller. The loader validates the table against the config anyway and
-- refuses anything else -- it builds dynamic SQL, so an unchecked table name is
-- an injection point -- but not accepting it at all is simpler and leaves the
-- config the single source of truth.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.sync',
                       p_pattern     => 'load/:reportName');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.sync', p_pattern => 'load/:reportName',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
DECLARE
  v_tab     VARCHAR2(30);
  v_clob    CLOB;
  v_dest    INTEGER := 1;
  v_src     INTEGER := 1;
  v_lang    INTEGER := 0;
  v_warn    INTEGER := 0;
  v_read    NUMBER;
  v_merged  NUMBER;
  v_status  VARCHAR2(20);
  v_msg     VARCHAR2(2000);
BEGIN
  OWA_UTIL.MIME_HEADER('application/json', FALSE);
  OWA_UTIL.HTTP_HEADER_CLOSE;

  SELECT MAX(target_table) INTO v_tab
    FROM oc_time_sync_config
   WHERE bip_report_name = :reportName AND enabled_flag = 'Y';

  IF v_tab IS NULL THEN
    -- Not 500. An unknown or disabled report is the caller naming something
    -- wrong, and it must be distinguishable from the load itself failing.
    :status_code := 404;
    HTP.P('{"status":"Failed","message":"No enabled config row for report '
       || REPLACE(:reportName, '"', '') || '. Check OC_TIME_SYNC_CONFIG."}');
    RETURN;
  END IF;

  -- The body arrives as a BLOB. CONVERTTOCLOB handles the character-set
  -- conversion in one call and does not have the 32k ceiling that the
  -- UTL_ family imposes -- see the OC_TIME_B64_TO_BLOB note in CLAUDE.md,
  -- same class of problem.
  DBMS_LOB.CREATETEMPORARY(v_clob, TRUE);
  IF :body IS NOT NULL AND DBMS_LOB.GETLENGTH(:body) > 0 THEN
    DBMS_LOB.CONVERTTOCLOB(v_clob, :body, DBMS_LOB.LOBMAXSIZE,
                           v_dest, v_src, DBMS_LOB.DEFAULT_CSID,
                           v_lang, v_warn);
  END IF;

  oc_time_load_xml(
    p_table_name  => v_tab,
    p_xml         => v_clob,
    p_report_name => :reportName,
    p_actor       => 'OIC',
    o_rows_read   => v_read,
    o_rows_merged => v_merged,
    o_status      => v_status,
    o_message     => v_msg);

  -- 200 on Success, 422 otherwise. A load that read the XML and refused it is
  -- not a server error, and OIC must be able to tell "retry this" from "this
  -- will never work" without parsing prose.
  :status_code := CASE WHEN v_status = 'Success' THEN 200 ELSE 422 END;

  HTP.P('{"reportName":"'  || :reportName            || '"'
     || ',"targetTable":"' || v_tab                  || '"'
     || ',"status":"'      || v_status               || '"'
     || ',"rowsRead":'     || NVL(v_read, 0)
     || ',"rowsMerged":'   || NVL(v_merged, 0)
     || ',"message":"'     || REPLACE(REPLACE(NVL(v_msg, ''), '\', '\\'), '"', '\"')
     || '"}');

  DBMS_LOB.FREETEMPORARY(v_clob);
EXCEPTION
  WHEN OTHERS THEN
    -- SQLERRM into a local first: it cannot be referenced inside a SQL
    -- statement, and the concatenation below is close enough to one that this
    -- has already cost time elsewhere in this schema.
    DECLARE
      v_err VARCHAR2(500) := SUBSTR(SQLERRM, 1, 400);
    BEGIN
      :status_code := 500;
      HTP.P('{"status":"Failed","message":"'
         || REPLACE(REPLACE(v_err, '\', '\\'), '"', '\"') || '"}');
    END;
END;
    ~');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN name    FORMAT A16
COLUMN pattern FORMAT A22
COLUMN method  FORMAT A8

SELECT m.name, t.uri_template AS pattern, h.method
  FROM user_ords_modules m
  JOIN user_ords_templates t ON t.module_id = m.id
  JOIN user_ords_handlers  h ON h.template_id = t.id
 WHERE m.name = 'oc.time.sync'
 ORDER BY t.uri_template, h.method;

PROMPT
PROMPT Expect two rows: GET config, POST load/:reportName.
PROMPT
PROMPT   GET  .../oc/time/sync/config?scheduleTag=Daily
PROMPT   POST .../oc/time/sync/load/WORKERS      body = the BIP XML, as-is
PROMPT
PROMPT INT 002 passes BOTH BIP parameters, and both come from this response:
PROMPT
PROMPT   P_LAST_SYNC      <- lastSyncDate    ('' on a feed that never ran)
PROMPT   P_EFFECTIVE_DATE <- effectiveDate   (1st of next month on Monthly,
PROMPT                                        today on Daily)
PROMPT
PROMPT Do NOT feed lastSyncDate into P_EFFECTIVE_DATE. They answer different
PROMPT questions -- "what changed since" versus "as of when" -- and sharing a
PROMPT value reads the workforce as it stood at the last sync: stale attributes
PROMPT and anyone hired since simply missing.
PROMPT
PROMPT Monthly also gets targetPeriodId, for
PROMPT   POST /oc/time/admin/jobs/populate/{targetPeriodId}   (empty body)
PROMPT A NULL targetPeriodId means next month has no OC_TIME_PERIOD row yet --
PROMPT create the period before the monthly run, or it has nothing to build.
--== END ords/15_ords_time_sync.sql ==

-- ── Recompile anything the DDL invalidated ───────────────────
--
-- Adding a column to a table marks every dependent view INVALID. Oracle
-- recompiles them lazily on first use, so they are usually harmless — but
-- "usually" is the problem: a genuine error and a not-yet-touched object look
-- identical in USER_OBJECTS, so nobody can tell which they are looking at.
--
-- Compiling them here forces the distinction. Anything still INVALID after this
-- is really broken, and the verification block below will show it.
DECLARE
  v_n    PLS_INTEGER := 0;
  v_left PLS_INTEGER := 0;
BEGIN
  -- Views first, then everything else: a package body that reads an invalid
  -- view cannot compile until the view is sound.
  FOR o IN (SELECT object_type, object_name
              FROM user_objects
             WHERE status <> 'VALID'
               AND object_type IN ('VIEW','TRIGGER','PROCEDURE','FUNCTION',
                                   'PACKAGE','PACKAGE BODY')
             ORDER BY CASE object_type WHEN 'VIEW' THEN 1
                                       WHEN 'TRIGGER' THEN 2
                                       WHEN 'PACKAGE' THEN 3
                                       ELSE 4 END)
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER ' ||
        CASE o.object_type WHEN 'PACKAGE BODY' THEN 'PACKAGE' ELSE o.object_type END
        || ' ' || o.object_name || ' COMPILE' ||
        CASE WHEN o.object_type = 'PACKAGE BODY' THEN ' BODY' ELSE '' END;
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      -- ORA-24344 is "compiled with errors", which is the answer we wanted.
      NULL;
    END;
  END LOOP;

  SELECT COUNT(*) INTO v_left FROM user_objects WHERE status <> 'VALID';
  DBMS_OUTPUT.PUT_LINE('recompiled ' || v_n || ' object(s); ' || v_left ||
                       ' still invalid.');
  IF v_left > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Those are real errors - see the list below, then '
                         || 'SELECT * FROM user_errors.');
  END IF;
END;
/

-- ── Post-install verification ────────────────────────────────
PROMPT
PROMPT ##############################################################
PROMPT #  VERIFICATION
PROMPT ##############################################################
PROMPT

SET FEEDBACK OFF
COLUMN object_name FORMAT A34
COLUMN object_type FORMAT A14
COLUMN status      FORMAT A8

PROMPT --- Invalid objects (expect none) ---------------------------
SELECT object_type, object_name, status
  FROM user_objects
 WHERE status <> 'VALID'
 ORDER BY object_type, object_name;

PROMPT --- Tables --------------------------------------------------
SELECT table_name AS object_name
  FROM user_tables
 WHERE table_name LIKE 'OC_T%' OR table_name LIKE 'XX_O2C%'
 ORDER BY table_name;

PROMPT --- Views ---------------------------------------------------
SELECT view_name AS object_name FROM user_views
 WHERE view_name LIKE 'V_OC_T%'
 ORDER BY view_name;

PROMPT --- ORDS modules --------------------------------------------
COLUMN name      FORMAT A22
COLUMN uri_prefix FORMAT A26
SELECT m.name, m.uri_prefix, m.status,
       (SELECT COUNT(*) FROM user_ords_templates t
         WHERE t.module_id = m.id) AS templates,
       (SELECT COUNT(*) FROM user_ords_handlers h
         JOIN user_ords_templates t2 ON t2.id = h.template_id
        WHERE t2.module_id = m.id)  AS handlers
  FROM user_ords_modules m
 WHERE m.name IN ('oc.time','oc.time.approval','oc.time.admin','oc.time.auth')
 ORDER BY m.name;

PROMPT --- Seed counts ---------------------------------------------
SELECT 'lookup rows'   AS item, COUNT(*) AS cnt FROM oc_time_lookup
UNION ALL
SELECT 'common tasks',  COUNT(*) FROM oc_time_task WHERE task_type = 'COMMON'
UNION ALL
SELECT 'periods',       COUNT(*) FROM oc_time_period
UNION ALL
SELECT 'open periods',  COUNT(*) FROM oc_time_period WHERE status = 'Open'
UNION ALL
SELECT 'config items',  COUNT(*) FROM oc_time_config
UNION ALL
SELECT 'calendar days', COUNT(*) FROM oc_time_calendar;

SET FEEDBACK ON

PROMPT
PROMPT ##############################################################
PROMPT #  INSTALL COMPLETE
PROMPT #
PROMPT #  Next steps
PROMPT #   1. ORDS.ENABLE_SCHEMA (see the header) if not already done.
PROMPT #   2. Load Fusion master data: OC_TIME_WORKER, OC_TIME_PROJECT,
PROMPT #      OC_TIME_TASK, OC_TIME_ALLOCATION, OC_TIME_ABSENCE via OIC
PROMPT #      (INT-001 .. INT-006).
PROMPT #   3. Sync the calendar layers:
PROMPT #      POST /oc/time/admin/calendar/sync/{CORPORATE|PROJECT|CLIENT|SHIFT}
PROMPT #   4. Run population for the open period:
PROMPT #      POST /oc/time/admin/jobs/populate/{periodId}
PROMPT #   5. Point the VBCS service connection at this schema's ORDS base URL
PROMPT #      (services/catalog.json -> backends.oc_time.servers[0].url).
PROMPT #   6. Create sign-in accounts. OC_TIME_USER is empty after this install,
PROMPT #      so nobody can log in yet. Either run 90_test_seed.sql for the demo
PROMPT #      logins, or insert real ones:
PROMPT #        INSERT INTO oc_time_user (employee_id, email, full_name, status)
PROMPT #        VALUES ('RI2824','someone@rite.digital','Their Name','Invited');
PROMPT #      An Invited user sets their own password at first sign-in via
PROMPT #        POST /oc/time/auth/set-password  {email, newPassword}
PROMPT ##############################################################
PROMPT
