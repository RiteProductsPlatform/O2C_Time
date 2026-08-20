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
--
-- PARTIAL, and the CASE expressions are the whole point. Written plainly as
-- (cover_employee_id, absence_date) this indexed the GAP rather than the cover:
-- Oracle omits an entry only when EVERY key column is null, and ABSENCE_DATE is
-- NOT NULL, so two rows awaiting a cover on one date collided as
-- (NULL, 20-Aug). The rule it enforced was "only one person in the company may
-- be uncovered on any given date", and generate_llc_lines -- a single
-- INSERT ... SELECT -- lost its whole run to ORA-00001 the first time two
-- people were off together. Latent since this file was written; surfaced
-- 21-Aug-2026 on 555.
--
-- Collapsing both expressions to NULL when there is no cover leaves uncovered
-- rows unindexed, and enforces the actual rule on the assigned ones. See db/95.
BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE UNIQUE INDEX uk_oc_tsllc_cover_day
      ON oc_ts_leave_loss_cover (
        CASE WHEN cover_employee_id IS NULL THEN NULL ELSE cover_employee_id END,
        CASE WHEN cover_employee_id IS NULL THEN NULL ELSE absence_date      END)
  ~';
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
   -- ON THE PROJECT ON THAT DAY, not merely on it now. Added 20-Aug.
   -- al.status='Active' says the allocation has not ended; it says nothing
   -- about whether it had started. RI2824's 555 allocation begins 17-Aug, so
   -- without this the same person is offered as cover for 07-Aug -- exactly the
   -- fault already fixed in populate, where ten days of 555 were seeded before
   -- the allocation existed.
   AND d.absence_date BETWEEN al.start_date
                          AND NVL(al.end_date, d.absence_date)
   -- not absent that day.
   --
   -- APPROVED absence only. This tested for any row, so a REJECTED leave
   -- request removed somebody who is demonstrably at work -- and
   -- generate_llc_lines requires Approved for the absentee, so the two halves
   -- of one rule disagreed. Withdrawn leave never reaches here: the loader
   -- deletes it.
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = al.employee_id
                      AND ab.absence_date    = d.absence_date
                      AND ab.approval_status = 'Approved')
   -- a working day for THEM. Patterns differ -- 555 carries people on
   -- Sunday-to-Thursday and Monday-to-Friday -- so somebody's day off is not
   -- everybody's. Offering them wastes the manager's decision: the billing
   -- move would then find no hours to convert.
   AND NOT EXISTS (SELECT 1 FROM oc_time_calendar c2
                    WHERE c2.layer          = 'SHIFT'
                      AND c2.scope_key      = al.employee_id
                      AND c2.cal_date       = d.absence_date
                      AND c2.is_working_day = 'N')
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
