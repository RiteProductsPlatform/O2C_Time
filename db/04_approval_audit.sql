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
