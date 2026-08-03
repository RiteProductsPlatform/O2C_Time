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
