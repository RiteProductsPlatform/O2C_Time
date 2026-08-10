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
