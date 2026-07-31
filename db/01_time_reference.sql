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

-- RULE-017: only one period may be Open at a time.
-- Function-based unique index: 'OPEN' is indexed only for Open rows, so a
-- second Open row raises DUP_VAL_ON_INDEX. Closed rows index to NULL and are
-- not constrained.
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE UNIQUE INDEX uk_oc_tp_single_open
      ON oc_time_period (CASE WHEN status = 'Open' THEN 'OPEN' END)
  ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

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
