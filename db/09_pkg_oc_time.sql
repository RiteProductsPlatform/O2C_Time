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
  FUNCTION get_open_period_id RETURN NUMBER;

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

  FUNCTION run_weekly_defaulting(
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
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER;     -- job_run_id

  PROCEDURE release_salary_hold(
    p_hold_id      IN NUMBER,
    p_actor_emp_id IN VARCHAR2,
    p_remarks      IN VARCHAR2 DEFAULT NULL,
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
    SELECT period_id INTO v_id FROM oc_time_period WHERE status = 'Open';
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20017, 'No period is currently Open.');
    WHEN TOO_MANY_ROWS THEN
      -- Should be impossible: UK_OC_TP_SINGLE_OPEN enforces RULE-017.
      RAISE_APPLICATION_ERROR(-20017, 'Only one period can be Open at a time.');
  END get_open_period_id;


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
  BEGIN
    SELECT NVL(SUM(hours),0) INTO v_total
      FROM oc_ts_entry
     WHERE ts_week_id = p_ts_week_id
       AND entry_date = TRUNC(p_entry_date)
       AND entry_type IN ('Actual','Default');

    IF v_total > 24 THEN
      RAISE_APPLICATION_ERROR(-20003, 'Cannot enter more than 24 hours in a day.');
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
  BEGIN
    SELECT w.week_start, w.week_status, w.locked_flag, p.status, p.delivery_cutoff
      INTO v_ws, v_status, v_locked, v_pstatus, v_delivery
      FROM oc_ts_week w
      JOIN oc_time_period p ON p.period_id = w.period_id
     WHERE w.ts_week_id = p_ts_week_id;

    -- RULE-004: future weeks are visible but frozen (SC-02).
    IF v_ws > week_start_of(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(-20004, 'Future weeks cannot be filled.');
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
                     AND chargeable_flag = 'Y'
                   ORDER BY sort_order, task_id)
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
    UPDATE oc_time_sync_job
       SET job_status = 'Failed', finished_on = SYSTIMESTAMP,
           message = SUBSTR(SQLERRM,1,2000)
     WHERE job_run_id = v_job;
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
    v_period := get_open_period_id;
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

    log_event(p_ts_week_id, v_emp, NULL, v_period, 'WEEK', NULL,
              CASE WHEN v_corr = 'Y' THEN 'Resubmit' ELSE 'Submit' END,
              NULL, NULL, v_emp, p_trace_id);
  END submit_week;


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

    IF v_ok = 0
       OR p_cover_employee_id = v_absent
       OR EXISTS (SELECT 1 FROM oc_time_absence ab
                   WHERE ab.employee_id  = p_cover_employee_id
                     AND ab.absence_date = v_date)
       OR EXISTS (SELECT 1 FROM oc_ts_leave_loss_cover c
                   WHERE c.cover_employee_id = p_cover_employee_id
                     AND c.absence_date      = v_date
                     AND c.llc_id           <> p_llc_id) THEN
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
    p_actor     IN VARCHAR2 DEFAULT 'SCHEDULER') RETURN NUMBER
  IS
    v_job  NUMBER;
    v_read NUMBER := 0;
    v_up   NUMBER := 0;
  BEGIN
    v_job := start_job('Salary Stopping', 'SalaryStopping',
                       p_period_id, TRUNC(SYSDATE), NULL, p_actor);

    FOR e IN (SELECT w.employee_id,
                     COUNT(*)                                                   AS weeks_total,
                     SUM(CASE WHEN w.week_status = 'Defaulted' THEN 1 ELSE 0 END) AS weeks_def,
                     SUM(CASE WHEN w.week_status <> 'Defaulted' THEN 1 ELSE 0 END) AS weeks_sub,
                     SUM(CASE WHEN w.week_status <> 'Defaulted'
                              THEN w.total_hours ELSE 0 END)                     AS applied_hrs,
                     SUM(CASE WHEN w.week_status  = 'Defaulted'
                              THEN w.total_hours ELSE 0 END)                     AS default_hrs
                FROM oc_ts_week     w
                JOIN oc_time_worker k ON k.employee_id = w.employee_id
               WHERE w.period_id = p_period_id
                 -- Period doc: salary hold is for employees; contractors are
                 -- invoice-driven (RA-012 still open).
                 AND k.worker_type = 'Employee'
               GROUP BY w.employee_id
              HAVING SUM(CASE WHEN w.week_status = 'Defaulted' THEN 1 ELSE 0 END) > 0)
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
      v_up := v_up + 1;
    END LOOP;

    -- An employee who no longer has any Defaulted week is released
    -- automatically: the reason for the hold has gone.
    UPDATE oc_ts_salary_hold h
       SET salary_status = 'Released',
           released_by   = p_actor,
           released_on   = SYSTIMESTAMP,
           remarks       = 'Auto-released: no defaulted weeks remain.'
     WHERE h.period_id     = p_period_id
       AND h.salary_status = 'Held'
       AND NOT EXISTS (SELECT 1 FROM oc_ts_week w
                        WHERE w.employee_id = h.employee_id
                          AND w.period_id   = h.period_id
                          AND w.week_status = 'Defaulted');

    finish_job(v_job, v_read, v_up, 0);
    COMMIT;
    RETURN v_job;
  END run_salary_stopping;


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
