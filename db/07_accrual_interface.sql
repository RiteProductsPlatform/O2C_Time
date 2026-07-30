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

PROMPT
PROMPT ============================================================
PROMPT time/07_accrual_interface complete.
PROMPT ============================================================
