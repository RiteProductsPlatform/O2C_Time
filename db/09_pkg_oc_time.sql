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

  -- p_reason is REQUIRED when the week is under an open salary hold and the
  -- employee has changed something: it is the "why" on every adjustment the
  -- resubmission raises, and the manager approves on the strength of it.
  -- Optional everywhere else, so ordinary in-period submission is unchanged.
  PROCEDURE submit_week(
    p_ts_week_id IN NUMBER,
    p_actor      IN VARCHAR2 DEFAULT 'VBCS_USER',
    p_trace_id   IN VARCHAR2 DEFAULT NULL,
    p_reason     IN VARCHAR2 DEFAULT NULL);

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
    v_layer    oc_time_calendar.layer%TYPE;
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
    -- LAYER is selected too, because what follows has to know whether the
    -- answer came from SHIFT or from something underneath it.
    BEGIN
      SELECT layer, shift_code, NVL(std_hours, v_std), is_working_day, holiday_name
        INTO v_layer, o_shift_code, o_std_hours, o_is_working, o_holiday_name
        FROM (SELECT c.layer, c.shift_code, c.std_hours, c.is_working_day,
                     c.holiday_name
                FROM oc_time_calendar c
               WHERE c.cal_date = TRUNC(p_date)
                 AND ( (c.layer = 'SHIFT'     AND c.scope_key = p_employee_id)
                    OR (c.layer = 'CLIENT'    AND c.scope_key = v_customer)
                    OR (c.layer = 'PROJECT'   AND c.scope_key = TO_CHAR(p_project_id))
                    OR (c.layer = 'CORPORATE' AND c.scope_key = v_country) )
               ORDER BY c.precedence DESC)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      -- No calendar row on any layer: fall back to Mon-Fri at the worker's
      -- standard hours. Overridden immediately below if they are rostered.
      v_layer        := NULL;
      o_shift_code   := NULL;
      o_std_hours    := v_std;
      o_is_working   := CASE WHEN TO_CHAR(TRUNC(p_date),'DY','NLS_DATE_LANGUAGE=ENGLISH')
                                  IN ('SAT','SUN') THEN 'N' ELSE 'Y' END;
      o_holiday_name := NULL;
    END;

    -- ── A DAY MISSING FROM A ROSTERED WEEK IS A DAY OFF ───────
    -- The WORKER_SHIFTS extract emits 'Y' and nothing else: it returns the days
    -- somebody is rostered and stays silent about the rest. So for a
    -- Sunday-to-Thursday worker, Friday and Saturday produce NO SHIFT row --
    -- and without this the lookup above falls through to CORPORATE, where
    -- Friday is an ordinary working day, and seeds it. The pattern extract says
    -- as much in its own comment: "a day absent from this list is a non-working
    -- day in that pattern".
    --
    -- Absence in a row-per-day table cannot speak for itself, so the question
    -- is asked the other way round: does this person have a roster around this
    -- date at all? If they do, the SHIFT layer is authoritative for them and a
    -- gap in it means they are off.
    --
    -- Only when the answer came from a LOWER layer, or from no layer. A real
    -- SHIFT row always wins on its own, including one saying 'Y' on a public
    -- holiday, which is the documented intent -- a shift day beats a holiday.
    IF NVL(v_layer, 'NONE') <> 'SHIFT' THEN
      DECLARE
        v_rostered NUMBER;
      BEGIN
        -- Bounded to the surrounding fortnight rather than "ever". A person
        -- whose roster stopped syncing would otherwise have every later day
        -- turn non-working and silently lose their whole timesheet; past the
        -- end of the roster this correctly finds nothing and the country
        -- calendar takes over again.
        SELECT COUNT(*) INTO v_rostered
          FROM oc_time_calendar c
         WHERE c.layer     = 'SHIFT'
           AND c.scope_key = p_employee_id
           AND c.cal_date BETWEEN TRUNC(p_date) - 7 AND TRUNC(p_date) + 7;

        IF v_rostered > 0 THEN
          o_shift_code   := NULL;
          o_std_hours    := 0;
          o_is_working   := 'N';
          o_holiday_name := NULL;
        END IF;
      END;
    END IF;

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
    -- Which billability of task this allocation should be seeded onto.
    v_want     oc_time_task.billable_type%TYPE;
    -- Absence apportionment (RULE-008). See the block that uses them.
    v_pct_tot  NUMBER;
    v_alloc_n  NUMBER;
    v_seq      NUMBER;
    v_left     NUMBER;
    v_share    NUMBER;
  BEGIN
    v_job := start_job('Monthly Population', 'MonthlyPopulation',
                       p_period_id, NULL, p_employee_id, p_actor);

    SELECT start_date, end_date INTO v_start, v_end
      FROM oc_time_period WHERE period_id = p_period_id;

    -- START_DATE and END_DATE are selected because the DAY LOOP needs them,
    -- not just this WHERE. The predicate below picks allocations that OVERLAP
    -- the period; it does not say which days within it they cover, and the loop
    -- used to seed every day of the period regardless. RI2824's 555 allocation
    -- begins 17-Aug and had been seeded from 01-Aug -- ten days on a project
    -- they were not on yet, which then read as an allocation of zero because
    -- no allocation row covered the date.
    FOR a IN (SELECT al.allocation_id, al.employee_id, al.project_id, al.alloc_pct,
                     al.start_date, al.end_date,
                     -- Review 18-Aug: "for non-billable people by default it
                     -- should show the non-billable task". This is the fact
                     -- that decides it -- BILLING_STATUS is per person per
                     -- project, from PPM's assignment type, and is a different
                     -- axis from OC_TIME_TASK.BILLABLE_TYPE, which is per task
                     -- for everyone. Both are needed and neither substitutes.
                     al.billing_status,
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
        -- The default task matches how this person is engaged on this project:
        -- an Unbilled resource is seeded onto a non-billable task, a Billable
        -- one onto a billable task. Two different vocabularies meet here --
        -- CHK_OC_TAL_BILLING allows ('Billable','Unbilled') and the task column
        -- allows ('Billable','Non-billable') -- so the mapping is explicit
        -- rather than a comparison.
        --
        -- FALLING BACK IS THE POINT, not a safety net. Most projects on this
        -- pod carry no non-billable WBS task yet: the single-level task
        -- structure that gives every project both was agreed in the same
        -- conversation and has not been built in PPM. Until it is, an Unbilled
        -- resource finds nothing to match and lands on the billable task
        -- exactly as before -- so this changes nothing anywhere the data does
        -- not yet support it, and starts working the day the tasks arrive.
        v_want := CASE WHEN a.billing_status = 'Unbilled'
                       THEN 'Non-billable' ELSE 'Billable' END;
        -- READ FROM THE LOV, NOT FROM OC_TIME_TASK.
        --
        -- This selected straight from the table with its own copy of the LOV's
        -- rules -- task_type='WBS', chargeable, billable -- and the copy was
        -- already incomplete: it omitted SELECTABLE_FLAG, which is what keeps
        -- Leave and Billing Loss out of the picker (RULE-008 / RULE-009). A
        -- project whose first chargeable billable task happened to be
        -- system-owned would have been seeded onto a line nobody could change.
        --
        -- Selecting from V_OC_TS_TASK_LOV makes that class of bug impossible
        -- rather than fixed: populate can only ever seed something the employee
        -- can also pick, because it is reading the picker. The comment below
        -- has always asserted the two agree; now they cannot disagree.
        --
        -- It also delivers the review item today. The LOV already carries the
        -- COMMON non-billable tasks against every project, so an Unbilled
        -- resource has a non-billable task to land on right now, without
        -- waiting for the single-level project task structure agreed in the
        -- same conversation. When that arrives and the project's own
        -- non-billable WBS tasks appear, the ORDER BY prefers them
        -- automatically -- WBS before Common -- and nothing here changes.
        BEGIN
          SELECT task_id INTO v_task
            FROM (SELECT task_id FROM v_oc_ts_task_lov
                   WHERE project_id    = a.project_id
                     AND billable_type = v_want
                   -- The project's own task before the shared one, then by WBS
                   -- number.
                   --
                   -- task_code, not task_id. SORT_ORDER is never populated -- the
                   -- extract does not carry it and the sync does not set it -- so
                   -- every task sits at the default 100 and the tie-break decided
                   -- the answer. task_id is the local identity column, so "the
                   -- first chargeable task" actually meant "whichever row the
                   -- sync happened to insert first". On project 444 that was
                   -- Leave; on another project it was Development. Ordering by
                   -- the WBS number makes it the first task in the BREAKDOWN,
                   -- and matches how V_OC_TS_TASK_LOV already orders.
                   ORDER BY CASE WHEN task_group = 'WBS' THEN 0 ELSE 1 END,
                            sort_order, task_code, task_id)
           WHERE ROWNUM = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          -- Nothing of the wanted billability. Only reachable for a Billable
          -- resource on a project with no billable task at all, since the
          -- COMMON non-billable tasks are always present for the Unbilled
          -- case. Left as a failed record, as it always was.
          fail_record(v_job, 'ALLOCATION',
                      'proj=' || a.project_id || ';emp=' || a.employee_id,
                      a.employee_id,
                      'Project has no selectable ' || v_want
                      || ' task to pre-populate against.',
                      'NO_WBS_TASK');
          v_failed := v_failed + 1;
          CONTINUE;
        END;

        FOR d IN 0 .. (v_end - v_start) LOOP
          DECLARE
            v_date DATE := v_start + d;
          BEGIN
            -- THE ALLOCATION'S OWN SPAN, per day. The cursor above only asks
            -- whether the allocation overlaps the PERIOD, so without this a
            -- mid-month start seeds the days before it and a mid-month end
            -- seeds the days after. Those rows are indistinguishable from real
            -- ones until something asks what allocation justifies them, which
            -- is how ten days of 555 appeared for RI2824 before 17-Aug.
            --
            -- Checked before resolve_day because it is the cheaper test and
            -- resolve_day reads the calendar.
            IF v_date < a.start_date
               OR (a.end_date IS NOT NULL AND v_date > a.end_date) THEN
              CONTINUE;
            END IF;

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
             -- 'Actual' OR 'Default'. This tested Actual alone, and
             -- run_weekly_defaulting retags a prepopulated row to
             -- entry_type='Default' -- so the moment a week defaulted, the
             -- guard stopped seeing its own rows, the cells read as empty, and
             -- the next populate filled them again. RI2824's week of 03-09 Aug
             -- ended up with 128 hours across five days: 64 defaulted plus 64
             -- freshly prepopulated on the same days.
             --
             -- UK_OC_TSE_CELL includes ENTRY_TYPE so the database allows the
             -- pair, which is right for a Reversal(-) sitting on the same day
             -- as the Actual it offsets. Default is not a counterpart though;
             -- it IS that Actual under another name, and the two must never
             -- both exist.
             --
             -- AND NOT BY TASK EITHER, for the same reason one step further
             -- out. This tested e.task_id = v_task -- the DEFAULT task -- so
             -- the moment the employee moved a line to another task
             -- (oc_time_change_line_task UPDATEs task_id), the guard stopped
             -- seeing its own row and seeded the default task again. The
             -- employee got two lines on one project, 4 hours each, and the
             -- second one reappeared on every page load because
             -- refreshAbsenceChain calls runPopulation. Reported 19-Aug from
             -- the screen: "move means we are updating, not adding a new line".
             --
             -- The right question is not "is the default task seeded" but "is
             -- this project seeded for this day". One allocation seeds one
             -- line per working day; which task it ends up on is the
             -- employee's business.
             --
             -- IS_LEAVE='N' keeps the previous behaviour on a leave day. Leave
             -- rows are Actual too, so without this a day that already carries
             -- leave would read as seeded and never get its worked line -- and
             -- the half-day case genuinely needs one. A full day is seeded and
             -- then zeroed, exactly as before.
             WHERE NOT EXISTS (SELECT 1 FROM oc_ts_entry e
                                WHERE e.ts_week_id = v_week
                                  AND e.project_id = a.project_id
                                  AND e.entry_date = v_date
                                  AND e.is_leave   = 'N'
                                  AND e.entry_type IN ('Actual','Default'));
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

      -- ── APPORTIONED ACROSS THE ALLOCATIONS (RULE-008) ────────
      --
      -- This used to send the whole day's leave to MIN(project_id) -- the
      -- lowest-numbered project the person was on, chosen for no reason but
      -- that it was first. RI2824 is 50% on 444, 25% on 555 and 25% on
      -- PCS10034, so a day of leave charged 8 hours to 444 and nothing to the
      -- other two. Every project's leave figure was wrong, and 444's manager
      -- carried absence taken against work they do not own. It also made the
      -- billing-loss number wrong on two projects out of three, because
      -- RULE-009 derives loss from leave.
      --
      -- The day is now split by ALLOC_PCT, over the allocations that actually
      -- cover the absence date -- not merely Active today, since somebody who
      -- joined 555 on the 17th did not owe it leave on the 10th.
      --
      -- THE TOTAL IS NEVER ASSUMED TO BE 8, and it is not assumed to be 100%
      -- either. The hours come from OC_TIME_ABSENCE, which the loader derives
      -- from the worker's own STD_HOURS_PER_DAY -- several people here are on
      -- 9-hour days and some patterns run 7.5 or 10. Percentages are divided by
      -- their own SUM rather than by 100, so a person allocated 50% in total
      -- still has their whole absence accounted for instead of half of it
      -- vanishing.
      --
      -- ROUNDING GOES TO THE LAST ROW ON PURPOSE. Three shares of 7.5h at
      -- 33.33% round to 2.50 each and sum to 7.50 by luck; 7.5h at 40/30/30
      -- rounds to 3.00/2.25/2.25 and sums to 7.50, but 10h at 33/33/34 does
      -- not. HOURS is NUMBER(6,2), so a residue of a cent-hour would leave the
      -- leave total short of the standard day -- and the "zero out the seeded
      -- work" step below tests absence >= standard, so a 0.01 shortfall would
      -- silently leave 8 hours of work sitting beside 7.99 of leave. The last
      -- allocation takes the remainder and the sum is exact by construction.
      --
      -- Aggregated per DAY, not per absence row. Two absence types on one date
      -- are two OC_TIME_ABSENCE rows (UK is employee+date+type) but only one
      -- cell per project in OC_TS_ENTRY, so iterating rows made the second type
      -- overwrite the first rather than add to it. Summed here, with the
      -- dominant type named on the row.
      FOR ab IN (SELECT ab.employee_id, ab.absence_date,
                        SUM(ab.absence_hours) AS absence_hours,
                        MAX(ab.absence_type) KEEP (DENSE_RANK FIRST
                            ORDER BY ab.absence_hours DESC) AS absence_type
                   FROM oc_time_absence ab
                  WHERE ab.absence_date BETWEEN v_start AND v_end
                    AND ab.approval_status = 'Approved'
                    AND (p_employee_id IS NULL OR ab.employee_id = p_employee_id)
                  GROUP BY ab.employee_id, ab.absence_date)
      LOOP
        SELECT NVL(SUM(al.alloc_pct),0), COUNT(*)
          INTO v_pct_tot, v_alloc_n
          FROM oc_time_allocation al
         WHERE al.employee_id = ab.employee_id
           AND al.status      = 'Active'
           AND ab.absence_date BETWEEN al.start_date
                               AND NVL(al.end_date, ab.absence_date);

        -- No allocation covering the date: nothing to charge the leave to.
        -- Skipped rather than parked on an arbitrary project, which is the
        -- fault this block exists to remove.
        IF v_pct_tot <= 0 OR v_alloc_n = 0 THEN CONTINUE; END IF;

        v_week := ensure_week(ab.employee_id, ab.absence_date, p_actor);
        v_left := ab.absence_hours;
        v_seq  := 0;

        FOR al IN (SELECT al.project_id, al.alloc_pct
                     FROM oc_time_allocation al
                    WHERE al.employee_id = ab.employee_id
                      AND al.status      = 'Active'
                      AND ab.absence_date BETWEEN al.start_date
                                          AND NVL(al.end_date, ab.absence_date)
                    ORDER BY al.alloc_pct DESC, al.project_id)
        LOOP
          v_seq := v_seq + 1;
          IF v_seq = v_alloc_n THEN
            v_share := v_left;                       -- the remainder, exactly
          ELSE
            v_share := ROUND(ab.absence_hours * al.alloc_pct / v_pct_tot, 2);
            v_left  := v_left - v_share;
          END IF;

        MERGE INTO oc_ts_entry e
        USING (SELECT v_week AS ts_week_id, al.project_id AS project_id,
                      v_task AS task_id, ab.absence_date AS entry_date FROM dual) s
           ON (e.ts_week_id = s.ts_week_id AND e.project_id = s.project_id
           AND e.task_id    = s.task_id    AND e.entry_date = s.entry_date
           AND e.entry_type = 'Actual')
         -- SOURCE = 'Absence' ON BOTH BRANCHES.
         --
         -- The UPDATE branch used to leave SOURCE alone, so a day that had
         -- already been prepopulated kept 'Prepopulated' when leave landed on
         -- it. TRG_OC_TSE_AUDIT_CAPTURE switches on SOURCE and has no case for
         -- that value, so it fell to ELSE -> 'ManagerEdit', and the approval
         -- workflow told the employee "Edited by the manager" about a change no
         -- manager made. Reported 12-Aug-2026.
         --
         -- 'Absence' is also what records, in the database, that these hours
         -- came from Absence Management -- which is why the screen no longer
         -- needs a chip to say so.
         WHEN MATCHED THEN UPDATE
              SET e.hours = v_share, e.is_leave = 'Y',
                  e.absence_type = ab.absence_type, e.source = 'Absence',
                  e.updated_by = p_actor
         WHEN NOT MATCHED THEN
              INSERT (ts_week_id, project_id, task_id, entry_date, hours,
                      entry_type, is_leave, absence_type, source, created_by)
              VALUES (v_week, al.project_id, v_task, ab.absence_date,
                      v_share, 'Actual', 'Y', ab.absence_type,
                      'Absence', p_actor);
          v_upserted := v_upserted + 1;
        END LOOP;

        -- A LEAVE ROW LEFT BEHIND BY A CHANGED ALLOCATION IS STILL LEAVE to
        -- every SUM() that reads it, so the old share has to go when the split
        -- moves. Comes up on two ordinary events: somebody is taken off a
        -- project, and somebody's percentage is re-cut so a project drops out
        -- of the distribution entirely. Restricted to rows this job wrote
        -- ('Absence'), so a manager's override is never swept up.
        DELETE FROM oc_ts_entry e
         WHERE e.ts_week_id = v_week
           AND e.entry_date = ab.absence_date
           AND e.is_leave   = 'Y'
           AND e.source     = 'Absence'
           AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al2
                            WHERE al2.employee_id = ab.employee_id
                              AND al2.project_id  = e.project_id
                              AND al2.status      = 'Active'
                              AND ab.absence_date BETWEEN al2.start_date
                                  AND NVL(al2.end_date, ab.absence_date));

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
    -- Null means "today ON THIS DATABASE", resolved here rather than by the
    -- caller. A DEFAULT on the parameter would not do this: a default applies
    -- only when the argument is OMITTED, and OIC's database adapter names every
    -- parameter and sends an empty element -- an explicit NULL. Same trap that
    -- put NULL into OC_TIME_ALLOCATION.ALLOC_PCT despite its DEFAULT 100.
    --
    -- It matters because OIC and the ATP are in different regions and their
    -- dates disagree: measured 11-Aug-2026, OIC said the 11th while
    -- LASTSYNC_DATE came back 10-08-26. Most days that is harmless. On the 1st
    -- of a month it is not -- get_period_for_date below would resolve the WRONG
    -- MONTH and the job would populate it, quietly and successfully.
    v_date   DATE := NVL(p_action_date, TRUNC(SYSDATE));
  BEGIN
    -- The period the action date falls in, not "the open period". With several
    -- months open at once the latter is a guess, and this job already knows the
    -- exact date it is processing (RA-003).
    v_period := get_period_for_date(v_date);
    v_job := start_job('Daily Action-date Process', 'DailyActionDate',
                       v_period, TRUNC(v_date), p_scope_key, p_actor);

    FOR w IN (SELECT DISTINCT al.employee_id
                FROM oc_time_allocation al
                JOIN oc_time_worker     wk ON wk.employee_id = al.employee_id
               WHERE al.status = 'Active'
                 AND (p_scope_key IS NULL
                      OR NVL(wk.deputed_country, wk.base_country) = p_scope_key)
                 AND (TRUNC(al.updated_on) = TRUNC(v_date)
                   OR TRUNC(al.created_on) = TRUNC(v_date)
                   OR TRUNC(wk.updated_on) = TRUNC(v_date)
                   OR TRUNC(wk.created_on) = TRUNC(v_date)))
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

    -- PROMOTE A DEFAULT ROW FIRST, so the MERGE below finds it.
    --
    -- The MERGE matches 'Actual' alone, which was safe only because nothing
    -- could reach it on a defaulted week: defaulting locks the week and every
    -- other caller edits one that is already Actual. The salary-hold keyhole in
    -- assert_editable changed that -- it is the first path that reaches
    -- save_entry on a week whose rows are 'Default', which is precisely the
    -- correction flow PROC-007 exists for.
    --
    -- Unmatched, the INSERT below adds an Actual BESIDE the Default, and
    -- UK_OC_TSE_CELL includes ENTRY_TYPE so the database allows the pair. A day
    -- holding 8 defaulted hours, corrected to 4 would end up with 12 --
    -- validate_day only refuses past 24. CLAUDE.md states the invariant it
    -- breaks: "Default is not a counterpart; it IS that Actual under another
    -- name, and the two must never both exist."
    --
    -- A SEPARATE UPDATE, not a widened ON clause. Matching
    -- entry_type IN ('Actual','Default') and setting entry_type in the same
    -- MERGE raises ORA-38104: a column in the ON clause cannot be updated.
    --
    -- The promotion is meaningful, not just mechanical: the row stops being
    -- what the job assumed and becomes what the person says. So the 'Default'
    -- rows still standing after a resubmission are exactly the untouched ones,
    -- which is the baseline the adjustment rule compares against.
    UPDATE oc_ts_entry
       SET entry_type = 'Actual',
           updated_by = p_actor
     WHERE ts_week_id = p_ts_week_id
       AND project_id = p_project_id
       AND task_id    = p_task_id
       AND entry_date = TRUNC(p_entry_date)
       AND entry_type = 'Default';

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
    p_trace_id   IN VARCHAR2 DEFAULT NULL,
    p_reason     IN VARCHAR2 DEFAULT NULL)
  IS
    -- Salary-hold resubmission (PROC-007). Declared here rather than inside a
    -- nested block so the count is available after the event fires, which is
    -- where the adjustments have to be raised.
    v_hold_open NUMBER := 0;
    v_changed   NUMBER := 0;
    v_adj       NUMBER := 0;
    v_emp      oc_ts_week.employee_id%TYPE;
    v_period   oc_ts_week.period_id%TYPE;
    v_status   oc_ts_week.week_status%TYPE;
    v_ws       DATE;
    v_we       DATE;
    v_type     oc_time_worker.worker_type%TYPE;
    v_cutday   oc_time_period.ts_cutoff_day%TYPE;
    v_cuttime  oc_time_period.ts_cutoff_time%TYPE;
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

    -- ── A DAY MUST ADD UP TO ITS STANDARD HOURS ──────────────
    -- Review 18-Aug-2026: "The time entered against any of the projects task
    -- put together for a day should equal to that standard hours. If it is not
    -- there, show a warning message" -- corrected moments later to "error
    -- message, not a warning".
    --
    -- AT SUBMIT, NOT AT SAVE, and that is a judgement rather than the literal
    -- wording. The ask was made about saving, but no day can be built up to
    -- eight hours without passing through four: enforcing it on Save draft
    -- would make the grid impossible to fill in a project at a time, and would
    -- refuse the perfectly ordinary act of stopping halfway. Submit is the
    -- moment the employee asserts the week is complete, so it is the moment the
    -- assertion can be checked. validate_day keeps the per-save rules -- 24
    -- hours, and no work on a full leave day.
    --
    -- The scenario that prompted it is the one to keep in mind: apply leave,
    -- cancel it, and the work rows come back at zero. Total 0 against a
    -- standard of 8, and nothing previously said so.
    --
    -- Zero-standard days are skipped -- weekend, holiday, or a non-working day
    -- in the person's pattern. There is no standard to reach, and RULE-012
    -- still lets them book time there voluntarily.
    --
    -- Driven off the entries rather than the calendar, so a working day with no
    -- rows at all is not seen. That does not arise in practice: populate writes
    -- a row per allocation per working day and the zero-out step sets hours to
    -- zero rather than deleting, so the row survives to be counted.
    DECLARE
      v_offend VARCHAR2(1000);
    BEGIN
      SELECT LISTAGG(TO_CHAR(d.entry_date,'DD-Mon') || ' has '
                     || TRIM(TO_CHAR(d.booked,'FM9990.99')) || ' of '
                     || TRIM(TO_CHAR(d.std,'FM9990.99')), '; ')
               WITHIN GROUP (ORDER BY d.entry_date)
        INTO v_offend
        FROM (SELECT e.entry_date,
                     SUM(e.hours)          AS booked,
                     MAX(e.standard_hours) AS std
                FROM oc_ts_entry e
               WHERE e.ts_week_id = p_ts_week_id
                 AND e.entry_type IN ('Actual','Default')
               GROUP BY e.entry_date) d
       WHERE NVL(d.std,0) > 0
         AND NVL(d.booked,0) <> d.std;

      IF v_offend IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20028,
          'Each day must add up to its standard hours before the week can be '
          || 'submitted. ' || v_offend || '.');
      END IF;
    END;

    -- RULE-007 (lateness) IS NO LONGER DECIDED HERE. It was computed inline --
    -- SYSDATE against NEXT_DAY(week_end, cutday) -- reading the hour only and
    -- dropping the minutes, so a 17:30 cut-off behaved as 17:00. The engine's
    -- oc_time_week_timing reads hours AND minutes and is the single answer
    -- both this and the defaulting job now use, so they cannot disagree.

    -- A resubmission after rejection is recorded in the log as Resubmit; the
    -- Correction FLAG itself was dropped in revision 2, the OC_TS_APPROVAL row
    -- being the audit trail.
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

    -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────────
    -- Submitted or LateSubmission is a ROW in OC_TS_TRANSITION, not a branch
    -- here, and the timing it matches on is computed at THIS instant -- not
    -- the one the page worked out when it rendered, which may be minutes old
    -- and on the wrong side of 17:00. It also writes both axes, cascades to
    -- every day, raises the flag, keeps WEEK_STATUS in step, and leaves a
    -- numbered version behind.
    -- ── SALARY-HOLD RESUBMISSION (PROC-007) ───────────────────
    -- Is this week under an open hold, and did the person actually change
    -- anything? Asked BEFORE the event so the answer describes the state they
    -- submitted, and answered by the entry rows themselves: a cell nobody
    -- touched is still ENTRY_TYPE 'Default', because save_entry promotes to
    -- 'Actual' on edit.
    --
    -- The functional owner's rule, 18-Aug-2026: "if the employee submits data
    -- without any changes to it then we don't send it as adjustment, but he
    -- has reduced the hours or adding one more line for a new project and
    -- adding some hours to it then it goes as adjustment". Unchanged hours were
    -- already accrued when the month was confirmed, so there is no delta to
    -- post -- and posting one would send a Reversal and an equal Adjustment
    -- that cancel.
    SELECT COUNT(*) INTO v_hold_open
      FROM oc_ts_salary_hold_day d
      JOIN oc_ts_salary_hold     h ON h.hold_id = d.hold_id
     WHERE d.ts_week_id    = p_ts_week_id
       AND d.day_status   IN ('Held','Rejected')
       AND h.salary_status = 'Held';

    IF v_hold_open > 0 THEN
      SELECT COUNT(*) INTO v_changed
        FROM oc_ts_entry e
       WHERE e.ts_week_id = p_ts_week_id
         AND e.is_leave   = 'N'
         AND e.entry_type = 'Actual'
         AND e.source    <> 'Prepopulated';

      -- A REASON IS ONLY REQUIRED IF SOMETHING MOVED. Demanding one to confirm
      -- the figures already on the screen would be a toll on the correct
      -- behaviour -- the employee agreeing with the default is the outcome the
      -- module wants, and it needs no justification.
      IF v_changed > 0
         AND (p_reason IS NULL OR LENGTH(TRIM(p_reason)) = 0) THEN
        RAISE_APPLICATION_ERROR(-20013,
          'You have changed hours on a week that is holding your pay. Give a '
          || 'reason -- your manager approves the correction on the strength '
          || 'of it.');
      END IF;
    END IF;

    oc_time_fire_event(p_ts_week_id, 'Submit', p_actor);

    -- AFTER the event, so the adjustments sit under the version it wrote and
    -- the trail reads in the order things happened.
    IF v_hold_open > 0 AND v_changed > 0 THEN
      oc_time_raise_late_adjustments(p_ts_week_id, p_reason, p_actor, v_adj);

      -- The reason on the version row too. OC_TS_WEEK_VERSION is what somebody
      -- reads to understand a week's history, and a version that says
      -- "LateSubmission" without saying why sends them hunting through
      -- OC_TS_ADJUSTMENT for it.
      UPDATE oc_ts_week_version
         SET notes = SUBSTR(NVL(notes || ' ', '') || v_adj
                     || ' adjustment(s) raised: ' || p_reason, 1, 400)
       WHERE ts_week_id = p_ts_week_id
         AND version_no = (SELECT MAX(version_no) FROM oc_ts_week_version
                            WHERE ts_week_id = p_ts_week_id);
    END IF;

    -- What the engine does not own: who pressed the button, and clearing the
    -- previous rejection so a resubmission does not carry the old reason
    -- forward into the manager's queue.
    UPDATE oc_ts_week
       SET submitted_by   = p_actor,
           submitted_on   = SYSTIMESTAMP,
           reject_reason  = NULL,
           reject_remarks = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    UPDATE oc_ts_entry
       SET reject_reason  = NULL,
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

    -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────────
    oc_time_fire_event(p_ts_week_id, 'Revoke', p_actor);

    UPDATE oc_ts_week
       SET submitted_by = NULL,
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
    -- v_cutday / v_cuttime are gone: the cut-off moment is no longer computed
    -- here at all, it is asked of oc_time_week_timing.
  BEGIN
    v_job := start_job('Weekly Defaulting', 'WeeklyDefaulting',
                       p_period_id, TRUNC(p_as_of), NULL, p_actor);

    -- Selected on the AXIS, not on WEEK_STATUS. The axis is the V4 truth and
    -- WEEK_STATUS is derived from it; filtering on the derived value would
    -- work today and quietly stop working the moment phase 3 removes it.
    FOR w IN (SELECT ts_week_id, employee_id, week_end
                FROM oc_ts_week
               WHERE period_id          = p_period_id
                 AND submission_status  = 'NotYetSubmitted'
                 AND week_end           < TRUNC(p_as_of))
    LOOP
      v_read := v_read + 1;
      BEGIN
        -- ONE ANSWER ABOUT THE CUT-OFF, and the engine owns it. This block
        -- used to compute its own -- SUBSTR(cuttime,1,2)/24 -- which read the
        -- hour and dropped the minutes, so at a 17:30 cut-off it defaulted
        -- weeks half an hour before the Submit rules considered them late: a
        -- week both Defaulted and WithinCutoff at once.
        --
        -- p_as_of is passed through so a replay against a past date evaluates
        -- against that date and not against today.
        IF oc_time_week_timing(w.ts_week_id, p_as_of) = 'WithinCutoff' THEN
          CONTINUE;
        END IF;

        -- The pre-populated rows ARE the default hours; retag them so the
        -- accrual hand-off can tell Actual from Default (INT-014 ENTRY_TYPE).
        UPDATE oc_ts_entry
           SET entry_type = 'Default', source = 'Job', updated_by = p_actor
         WHERE ts_week_id = w.ts_week_id
           AND entry_type = 'Actual'
           AND source     = 'Prepopulated';

        -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────
        -- WeeklyCutoff sets submission to Defaulted, raises the Defaulted
        -- flag, and writes DEFAULTED_BY = 'EMPLOYEE' -- the default that holds
        -- pay (RULE-016). It also leaves a version, so an auto-submission the
        -- employee never made is as traceable as one they did.
        oc_time_fire_event(w.ts_week_id, 'WeeklyCutoff', p_actor);

        -- Locking and the submission stamp are not status. Only a manager can
        -- edit the week now.
        UPDATE oc_ts_week
           SET locked_flag  = 'Y',
               submitted_by = p_actor,
               submitted_on = SYSTIMESTAMP,
               updated_by   = p_actor
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

    -- ANYTHING STILL AWAITING THE MANAGER, whichever way it got there. The
    -- old filter was week_status = 'Submitted', which silently excluded a
    -- week the weekly job had defaulted -- that week reached the manager just
    -- as surely, and their not acting on it is exactly what this job records.
    --
    -- NotYetSubmitted is excluded, and that is the whole point: a manager
    -- cannot fail to approve something nobody sent. The engine has no rule for
    -- that combination and would raise -20034 rather than blame them.
    FOR w IN (SELECT ts_week_id, employee_id
                FROM oc_ts_week
               WHERE period_id         = p_period_id
                 AND approval_status   = 'Pending'
                 AND submission_status IN ('Submitted','LateSubmission','Defaulted'))
    LOOP
      v_read := v_read + 1;
      BEGIN
        -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────
        -- Approval becomes ManagerDefaulted; the SUBMISSION axis is left
        -- untouched, so an employee who submitted on time keeps that on their
        -- record. DEFAULTED_BY stays EMPLOYEE where it already was, which is
        -- what stops a manager's lateness releasing an employee's salary hold.
        oc_time_fire_event(w.ts_week_id, 'DeliveryCutoff', p_actor);

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

    -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────────
    -- ACT-014: approving the week approves every day in it, which the engine
    -- does in one statement so a day can never disagree with its week.
    --
    -- ApproveOverride is a DIFFERENT EVENT, not a flag checked afterwards. It
    -- raises Overridden itself and derives 'Overridden and approved', so the
    -- override cannot be lost between deciding it and recording it.
    --
    -- Note the ordering this depends on: OVERRIDDEN_FLAG is already 'Y' by the
    -- time approve_week runs, because the manager's edit set it. Reading it
    -- here to CHOOSE the event is therefore safe; reading it inside the engine
    -- to derive the label would not be, which is why apply_event treats the
    -- ApproveOverride event as authoritative rather than the column.
    oc_time_fire_event(p_ts_week_id,
      CASE WHEN v_over = 'Y' THEN 'ApproveOverride' ELSE 'Approve' END, p_actor);

    -- Who approved it, and when. The engine owns status; it does not own this.
    UPDATE oc_ts_entry
       SET approved_by = p_actor,
           approved_on = SYSTIMESTAMP,
           updated_by  = p_actor
     WHERE ts_week_id = p_ts_week_id;

    UPDATE oc_ts_week
       SET approved_by = p_actor,
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

    -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────────
    -- Rejection moves BOTH axes, and the two move differently: approval
    -- becomes Rejected, and submission resets to NotYetSubmitted because the
    -- week genuinely is back with the employee to send again. Confirmed
    -- 13-Aug -- and it is why the employee's next submission can land as
    -- LateSubmission if the cut-off has since passed, which a single status
    -- column could not have expressed.
    oc_time_fire_event(p_ts_week_id, 'Reject', p_actor);

    -- The reason, and unlocking so they can correct and resubmit
    -- (PROC-005 / RULE-007). Reason and remarks are not status, so the engine
    -- has no opinion on them.
    UPDATE oc_ts_entry
       SET reject_reason  = p_reason,
           reject_remarks = p_remarks,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    UPDATE oc_ts_week
       SET reject_reason  = p_reason,
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
  BEGIN
    -- RETIRED 14-Aug-2026. APPROVAL IS WEEKLY, and only weekly: "if a week is
    -- approved all the days in a week are approved, and if a week is rejected
    -- all the days in the week are rejected".
    --
    -- A day never holds a decision of its own. While it could, this procedure
    -- was able to leave a week whose days disagreed with it -- half approved,
    -- half pending, and a WEEK_STATUS rolled up from whichever happened to be
    -- last. That is precisely what the two-axis model exists to remove, and
    -- oc_time_apply_event now writes every day of a week in ONE statement so
    -- the disagreement is not expressible.
    --
    -- Kept as a procedure rather than dropped: the ORDS handler still calls
    -- it, and a clear refusal is better than the PLS-00201 an unresolved
    -- identifier would give. -20027 is inside the range ORDS maps to 400, so
    -- the message reaches the screen verbatim.
    RAISE_APPLICATION_ERROR(-20027,
      'Days are not approved or rejected individually. Act on the whole week.');
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
  BEGIN
    -- RETIRED 14-Aug-2026. APPROVAL IS WEEKLY, and only weekly: "if a week is
    -- approved all the days in a week are approved, and if a week is rejected
    -- all the days in the week are rejected".
    --
    -- A day never holds a decision of its own. While it could, this procedure
    -- was able to leave a week whose days disagreed with it -- half approved,
    -- half pending, and a WEEK_STATUS rolled up from whichever happened to be
    -- last. That is precisely what the two-axis model exists to remove, and
    -- oc_time_apply_event now writes every day of a week in ONE statement so
    -- the disagreement is not expressible.
    --
    -- Kept as a procedure rather than dropped: the ORDS handler still calls
    -- it, and a clear refusal is better than the PLS-00201 an unresolved
    -- identifier would give. -20027 is inside the range ORDS maps to 400, so
    -- the message reaches the screen verbatim.
    RAISE_APPLICATION_ERROR(-20027,
      'Days are not approved or rejected individually. Act on the whole week.');
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
  BEGIN
    -- RETIRED 14-Aug-2026. APPROVAL IS WEEKLY, and only weekly: "if a week is
    -- approved all the days in a week are approved, and if a week is rejected
    -- all the days in the week are rejected".
    --
    -- A day never holds a decision of its own. While it could, this procedure
    -- was able to leave a week whose days disagreed with it -- half approved,
    -- half pending, and a WEEK_STATUS rolled up from whichever happened to be
    -- last. That is precisely what the two-axis model exists to remove, and
    -- oc_time_apply_event now writes every day of a week in ONE statement so
    -- the disagreement is not expressible.
    --
    -- Kept as a procedure rather than dropped: the ORDS handler still calls
    -- it, and a clear refusal is better than the PLS-00201 an unresolved
    -- identifier would give. -20027 is inside the range ORDS maps to 400, so
    -- the message reaches the screen verbatim.
    RAISE_APPLICATION_ERROR(-20027,
      'Days are not approved or rejected individually. Act on the whole week.');
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
    v_emp    oc_ts_week.employee_id%TYPE;
    v_period oc_ts_week.period_id%TYPE;
    v_app    VARCHAR2(30);
  BEGIN
    -- Was a loop over days calling revoke_decision. Approval is weekly, so
    -- there is one decision to undo, not one per day: "if a week is approved
    -- all the days in a week are approved, and if a week is rejected all the
    -- days in the week are rejected" (confirmed 14-Aug). The day loop could
    -- only ever have produced the same answer more slowly, or a partial one.
    SELECT employee_id, period_id, approval_status
      INTO v_emp, v_period, v_app
      FROM oc_ts_week WHERE ts_week_id = p_ts_week_id;

    IF v_app = 'Pending' THEN
      RAISE_APPLICATION_ERROR(-20025,
        'There is no approval or rejection on this week to undo.');
    END IF;

    assert_not_self(v_emp, p_actor_emp_id);

    -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ──────────────
    -- Approval returns to Pending; the SUBMISSION axis is untouched, so the
    -- employee's record still shows they submitted, and when.
    oc_time_fire_event(p_ts_week_id, 'RevokeDecision', p_actor);

    UPDATE oc_ts_week
       SET approved_by    = NULL,
           approved_on    = NULL,
           reject_reason  = NULL,
           reject_remarks = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    UPDATE oc_ts_entry
       SET approved_by    = NULL,
           approved_on    = NULL,
           reject_reason  = NULL,
           reject_remarks = NULL,
           updated_by     = p_actor
     WHERE ts_week_id = p_ts_week_id;

    -- 'Revoke', not 'RevokeDecision'. CHK_OC_TSA_ACTION on OC_TS_APPROVAL
    -- allows ten values and RevokeDecision is not one of them -- 12_revoke.sql
    -- widened the domain to admit 'Revoke' and nothing since has touched it.
    -- A new value would mean another constraint change to run before this
    -- package could log anything, for no gain: the actor and ENTITY already
    -- distinguish an employee pulling back a submission from a manager undoing
    -- their own decision, which is how the original told them apart too.
    log_event(p_ts_week_id, v_emp, NULL, v_period, 'WEEK', NULL,
              'Revoke', NULL, NULL, p_actor_emp_id, p_trace_id);
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

    -- THE REASON GOES IN BEFORE THE WRITE, NOT AFTER IT.
    --
    -- This used to stamp the reason onto the audit row afterwards:
    --
    --   UPDATE oc_ts_audit SET change_reason = p_reason, trace_id = p_trace_id
    --    WHERE audit_id = (SELECT MAX(audit_id) ...);
    --
    -- and db/19 had already made OC_TS_AUDIT append-only, with a BEFORE UPDATE
    -- OR DELETE trigger that raises -20026 unconditionally. So ACT-016 failed
    -- on every call from the day db/19 was applied -- measured against ORDS
    -- SIT on 20-Aug, 400 "OC_TS_AUDIT is append-only". The trigger is
    -- STATEMENT level, so it fires even when the WHERE matches nothing: there
    -- was no input for which this succeeded.
    --
    -- Neither side gives way. A trail that can be rewritten is not a trail,
    -- and a correction with no reason is not one either. The reason is
    -- therefore handed to the capture trigger through OC_TIME_CTX (db/85) and
    -- lands in the INSERT it was always meant to be part of.
    oc_time_ctx.set_reason(p_reason, p_trace_id);

    UPDATE oc_ts_entry
       SET hours      = p_new_hours,
           source     = 'Manager',       -- drives the audit capture
           updated_by = p_actor
     WHERE ts_entry_id = p_ts_entry_id;

    -- Cleared as soon as the capture has run. The global outlives the
    -- statement but must not outlive the call, or the next write on this
    -- session inherits a reason nobody gave for it.
    oc_time_ctx.clear;

    validate_day(v_week, v_date);

    UPDATE oc_ts_week
       SET overridden_flag = 'Y', updated_by = p_actor
     WHERE ts_week_id = v_week;

    log_event(v_week, v_emp, NULL, v_period, 'DAY', v_date,
              'Override', NULL, p_reason, p_actor_emp_id, p_trace_id);
  EXCEPTION WHEN OTHERS THEN
    -- validate_day raises RULE-003 on a day that would now exceed 24 hours,
    -- and that is a normal refusal rather than a fault. ORDS rolls the
    -- transaction back; the context is session state and would not be rolled
    -- back with it.
    oc_time_ctx.clear;
    RAISE;
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
                 -- On the AXIS, and narrowed to Pending. The old filter was
                 -- "week_status NOT IN (Approved, Overridden and approved,
                 -- Closed)", which also selected REJECTED weeks -- and the
                 -- AdvanceApprove rule only matches from Pending, so the
                 -- engine would raise -20034 partway through. This loop has no
                 -- per-week handler, so that one rejected week would abandon
                 -- the whole month's advance closure with some weeks approved
                 -- and the rest not.
                 --
                 -- Excluding them is also right on its own terms: a week the
                 -- manager rejected should not be swept into an approval by a
                 -- closure job.
                 AND w.approval_status = 'Pending')
    LOOP
      assert_not_self(w.employee_id, p_actor_emp_id);

      -- ── THE ENGINE DECIDES THE STATUS (phase 2b) ────────────
      -- Advance closure approves whatever state the week is in, including a
      -- Defaulted one -- that is the whole point of it, and the open question
      -- in section 8.2. The rule carries AdvanceClosure so the reason a week
      -- was approved without a manager looking at it stays on the record.
      oc_time_fire_event(w.ts_week_id, 'AdvanceApprove', p_actor);

      UPDATE oc_ts_entry
         SET approved_by = p_actor,
             approved_on = SYSTIMESTAMP, updated_by = p_actor
       WHERE ts_week_id = w.ts_week_id;

      UPDATE oc_ts_week
         SET advance_closure_flag = 'Y',
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
    v_status  oc_ts_leave_loss_cover.llc_status%TYPE;
    v_ok      NUMBER;
    v_clash   NUMBER;
  BEGIN
    SELECT project_id, absence_date, absent_employee_id, llc_status
      INTO v_project, v_date, v_absent, v_status
      FROM oc_ts_leave_loss_cover WHERE llc_id = p_llc_id;

    -- AN APPROVED COVERAGE IS NOT REASSIGNABLE. Added 20-Aug alongside db/84,
    -- which is what makes it matter: approval MOVES hours out of the cover's
    -- non-billable line and records the quantity in COVER_HOURS_BILLED.
    -- Reassigning would point that record at a different person while the
    -- hours stayed moved for the first one -- billed time attributed to
    -- somebody who never covered. Revoke the billing first, then reassign.
    IF v_status = 'Approved' THEN
      RAISE_APPLICATION_ERROR(-20014,
        'This coverage is approved and its hours are already billed. Revoke it '
        || 'before assigning somebody else.');
    END IF;

    -- RULE-014: unbilled on the same project, not absent that day, not already
    -- assigned. Checked here as well as in the LOV so an API caller cannot
    -- bypass the filter.
    --
    -- The date range is checked too, not just al.status. Active says the
    -- allocation has not ended; it says nothing about whether it had started,
    -- and somebody who joins the project on the 17th cannot cover the 7th.
    SELECT COUNT(*) INTO v_ok
      FROM oc_time_allocation al
     WHERE al.project_id     = v_project
       AND al.employee_id    = p_cover_employee_id
       AND al.status         = 'Active'
       AND al.billing_status = 'Unbilled'
       AND v_date BETWEEN al.start_date AND NVL(al.end_date, v_date);

    -- Is the candidate themselves absent that day, or already covering someone
    -- else on it? EXISTS is a SQL construct and cannot appear in a PL/SQL IF
    -- (PLS-00204), so both tests are evaluated in SQL. CASE WHEN EXISTS rather
    -- than COUNT(*) keeps the short-circuit: it stops at the first hit instead
    -- of counting every match.
    SELECT CASE WHEN EXISTS (SELECT 1 FROM oc_time_absence ab
                              WHERE ab.employee_id     = p_cover_employee_id
                                AND ab.absence_date    = v_date
                                -- APPROVED only. This matched any absence row,
                                -- so a REJECTED leave request blocked somebody
                                -- who is demonstrably at work -- while
                                -- generate_llc_lines requires Approved for the
                                -- absentee. One rule, two halves, disagreeing.
                                AND ab.approval_status = 'Approved')
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
    v_hold NUMBER;          -- the hold row the day rows hang off
    v_pay_cut DATE;         -- this worker's payroll cut-off (per country)
    v_rel_days NUMBER;      -- and their release window, from the same source
    v_win_from DATE;        -- their country's payroll window, for the day rows
    v_win_to   DATE;
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
      -- TWO STATEMENTS, not one. The single-statement version read
      --   SELECT NVL(MAX(prev.payroll_cutoff) + 1,
      --              (SELECT start_date FROM oc_time_period WHERE ...))
      --     FROM oc_time_period prev WHERE ...
      -- and raised ORA-00937, "not a single-group group function": a scalar
      -- subquery in the select list is not an aggregate, so sitting it beside
      -- MAX() with no GROUP BY is illegal. It compiles -- the package built
      -- clean -- and fails only when the function is called, which is why it
      -- surfaced in the middle of a month end rather than at install.
      DECLARE
        v_prev DATE;
      BEGIN
        SELECT MAX(prev.payroll_cutoff) INTO v_prev
          FROM oc_time_period prev
         WHERE prev.payroll_cutoff IS NOT NULL
           AND prev.payroll_cutoff < (SELECT NVL(payroll_cutoff, TRUNC(SYSDATE))
                                        FROM oc_time_period
                                       WHERE period_id = p_period_id);

        IF v_prev IS NOT NULL THEN
          v_from := v_prev + 1;          -- the day after the last cut-off
        ELSE
          -- Nothing earlier to chain from: bound the window at this period's
          -- own start rather than leaving it open.
          SELECT start_date INTO v_from
            FROM oc_time_period WHERE period_id = p_period_id;
        END IF;
      END;
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
                     -- DEFAULTED, not "never submitted". This tested
                     -- SUBMITTED_ON IS NULL, and run_weekly_defaulting STAMPS
                     -- submitted_by/on when it defaults a week -- it
                     -- auto-submits on the employee's behalf. So every week
                     -- this job exists to catch had a SUBMITTED_ON, the HAVING
                     -- below counted zero, and no hold was ever created. The
                     -- page has been empty since the day it was built.
                     --
                     -- DEFAULTED_BY = 'EMPLOYEE' is the other half. A MANAGER
                     -- default means the employee submitted and nobody
                     -- approved, and RULE-016 is explicit that awaiting
                     -- approval does not stop salary. Four scripts already
                     -- CLAIMED this filter existed; none of them checked.
                     SUM(CASE WHEN w.submission_status = 'Defaulted'
                               AND w.defaulted_by = 'EMPLOYEE'
                              THEN 1 ELSE 0 END)                 AS weeks_def,
                     SUM(CASE WHEN w.submission_status = 'Defaulted'
                               AND w.defaulted_by = 'EMPLOYEE'
                              THEN 0 ELSE 1 END)                 AS weeks_sub,
                     SUM(CASE WHEN w.submission_status = 'Defaulted'
                               AND w.defaulted_by = 'EMPLOYEE'
                              THEN 0 ELSE w.total_hours END)     AS applied_hrs,
                     SUM(CASE WHEN w.submission_status = 'Defaulted'
                               AND w.defaulted_by = 'EMPLOYEE'
                              THEN w.total_hours ELSE 0 END)     AS default_hrs
                FROM oc_ts_week     w
                JOIN oc_time_worker k ON k.employee_id = w.employee_id
                -- THE WINDOW, PER COUNTRY. Joined rather than taken from the
                -- v_from/v_upto locals, because a cut-off belongs to the
                -- country -- the payroll configuration screen says so in as
                -- many words -- and two people in the same month can therefore
                -- be judged against different dates. The locals were derived
                -- from OC_TIME_PERIOD, which is ours and can disagree with the
                -- configuration the gate below already reads.
                --
                -- CUTOFF_PASSED = 'Y' does the real gating here: a country
                -- whose cut-off is still ahead contributes no rows at all,
                -- which is why moving August to the 30th empties this cursor
                -- rather than merely narrowing it.
                --
                -- One row per period per country, so this cannot fan out the
                -- aggregates below.
                JOIN v_oc_time_payroll_window pw
                  ON pw.period_id     = p_period_id
                 AND pw.country       = k.base_country
                 AND pw.cutoff_passed = 'Y'
               WHERE k.status = 'Active'
                 -- Any week OVERLAPPING the payroll window, whichever calendar
                 -- period it belongs to. Overlap, not containment: a week that
                 -- straddles the cut-off contributes its earlier days.
                 AND w.week_start <= pw.window_to
                 AND w.week_end   >= pw.window_from
               GROUP BY w.employee_id
              HAVING SUM(CASE WHEN w.submission_status = 'Defaulted'
                               AND w.defaulted_by = 'EMPLOYEE'
                              THEN 1 ELSE 0 END) > 0)
    LOOP
      v_read := v_read + 1;

      -- ── THE PAYROLL CUT-OFF, PER COUNTRY ──────────────────
      -- PROC-007 holds pay AT THE PAYROLL CUT-OFF, not when a week defaults.
      -- The two are different dates and the gap between them is the window in
      -- which somebody can still fix their timesheet and be paid on time.
      --
      -- It cannot be a period-level bound: o2c_dev.OC_PAYROLL_CONFIG is keyed
      -- by COUNTRY and the definition says one country may hold several
      -- cut-offs for a period. Two people in the same month have different
      -- cut-offs, so this is asked per person, inside the loop.
      --
      -- NULL means no cut-off is configured for their country, and then this
      -- holds NOBODY. Guessing a date here would hold real pay on an invented
      -- deadline; an unconfigured country is reported by time/53 instead.
      v_pay_cut := oc_time_payroll_cutoff(e.employee_id, p_period_id);
      IF v_pay_cut IS NULL OR TRUNC(SYSDATE) <= v_pay_cut THEN
        CONTINUE;
      END IF;

      -- THE RELEASE WINDOW IS THEIRS TOO. This read
      --   NVL(oc_time_period.hold_release_days, 60)
      -- while db/53 had already built oc_time_hold_release_days() to read the
      -- payroll configuration, and nothing ever called it. Two sources for one
      -- number, agreeing at 60 today -- which is exactly why it went unnoticed.
      -- Change "Salary hold release period" on the screen and only one of them
      -- would move. NVL to 60 (CFG-012) stays as the floor for a country the
      -- configuration has no row for.
      v_rel_days := NVL(oc_time_hold_release_days(e.employee_id, p_period_id), 60);

      -- This person's own window, for the day rows below. Same source as the
      -- cursor's join, read here because the day cursor needs the bounds as
      -- values. NVL to the period-derived locals so a country with no window
      -- row still behaves as it did rather than writing no days at all.
      BEGIN
        SELECT pw.window_from, pw.window_to
          INTO v_win_from, v_win_to
          FROM v_oc_time_payroll_window pw
          JOIN oc_time_worker k ON k.base_country = pw.country
         WHERE pw.period_id = p_period_id
           AND k.employee_id = e.employee_id;
      EXCEPTION WHEN OTHERS THEN
        v_win_from := v_from;
        v_win_to   := v_upto;
      END;

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

      -- The calendar days the employee gets to correct, from the payroll
      -- configuration's "Salary hold release period" (CFG-012). Stamped only
      -- when the hold is first opened: re-running the job must not keep pushing
      -- the deadline out, or the window never closes.
      UPDATE oc_ts_salary_hold h
         SET h.hold_release_days = NVL(h.hold_release_days, v_rel_days),
             h.window_expires_on = NVL(h.window_expires_on,
                                       TRUNC(SYSDATE) + v_rel_days)
       WHERE h.employee_id = e.employee_id
         AND h.period_id   = p_period_id;

      -- ── the dates themselves ─────────────────────────────────
      -- A CURSOR THAT AGGREGATES, THEN A PLAIN VALUES INSERT.
      --
      -- Three attempts at INSERT ... SELECT with a GROUP BY failed with
      -- ORA-00979: nested inline view, flattened, and with the binds named in
      -- the GROUP BY. The common element was never the shape -- it was
      -- p_period_id and p_actor sitting in the select list of a grouped
      -- statement inside PL/SQL, which Oracle will not accept however it is
      -- arranged.
      --
      -- So the grouping happens where it is uncontroversial: a cursor whose
      -- select list is real columns and one aggregate, nothing else. The
      -- insert is then row by row with no grouping at all. Slower, and it
      -- runs -- which the elegant version did not.
      --
      -- NOT EXISTS stays in the cursor's WHERE, evaluated per row before
      -- grouping. A day the employee has already corrected is never reset by a
      -- later run: losing somebody's correction because the scheduler ran
      -- twice would be unforgivable and entirely silent. There is no unique
      -- key on (employee, work_date) to catch it, so this test is the only
      -- thing standing between a re-run and a duplicate.
      SELECT MAX(hold_id) INTO v_hold
        FROM oc_ts_salary_hold
       WHERE employee_id = e.employee_id AND period_id = p_period_id;

      FOR d IN (SELECT en.ts_week_id, en.entry_date,
                       MAX(en.standard_hours) AS std_hours
                  FROM oc_ts_entry en
                  JOIN oc_ts_week  wk ON wk.ts_week_id = en.ts_week_id
                 WHERE wk.employee_id  = e.employee_id
                   AND wk.submission_status = 'Defaulted'
                   AND wk.defaulted_by      = 'EMPLOYEE'
                   -- The payroll window, not the calendar month. Strictly
                   -- before the cut-off: a day cannot be late on the day
                   -- itself.
                   -- Per-country bounds, not the period-derived locals.
                   AND en.entry_date  >= v_win_from
                   AND en.entry_date   < v_win_to
                   AND NOT EXISTS (SELECT 1 FROM oc_ts_salary_hold_day x
                                    WHERE x.employee_id = e.employee_id
                                      AND x.work_date   = en.entry_date)
                 GROUP BY en.ts_week_id, en.entry_date
                HAVING MAX(en.standard_hours) > 0)
      LOOP
        INSERT INTO oc_ts_salary_hold_day
               (hold_id, employee_id, period_id, work_date, ts_week_id,
                expected_hours, day_status, created_by)
        VALUES (v_hold, e.employee_id, p_period_id, d.entry_date, d.ts_week_id,
                d.std_hours, 'Held', p_actor);
      END LOOP;

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
                        JOIN oc_time_worker k2
                          ON k2.employee_id = w.employee_id
                        JOIN v_oc_time_payroll_window pw2
                          ON pw2.period_id = h.period_id
                         AND pw2.country   = k2.base_country
                        WHERE w.employee_id  = h.employee_id
                          AND w.submission_status = 'Defaulted'
                          AND w.defaulted_by      = 'EMPLOYEE'
                          -- The SAME per-country window the hold was opened
                          -- against. Judged against the period-derived locals
                          -- instead, a hold could be released because a week
                          -- fell outside a window that was never the one used
                          -- to create it.
                          AND w.week_start  <= pw2.window_to
                          AND w.week_end    >= pw2.window_from);

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
    --
    -- ADVANCE CLOSURE IS THE ONE EXCEPTION, settled 11-Aug-2026. Section 8.2
    -- of the module notes left this open: a Defaulted week blocks the confirm,
    -- while advance close says defaulted hours are "treated as approved". The
    -- recommendation was to keep blocking and make advance close the explicit
    -- exception, and that is what this is.
    --
    -- It is deliberately NOT a widening of the normal path. A Normal confirm
    -- still refuses a defaulted week, so nobody closes a month with unapproved
    -- time by accident -- they have to say 'Advance closure', which is recorded
    -- on OC_TS_MONTH_CONFIRM.CONFIRM_TYPE and answers "why did this month go
    -- out without approvals" months later.
    --
    -- Defaulted already means a cut-off passed and a job decided: the weekly
    -- job for the employee, the delivery job for the manager, each stamping
    -- DEFAULTED_BY. The hours are real and prepopulated; what is missing is
    -- somebody's agreement, and advance closure is the decision to proceed
    -- without it.
    -- 'Pending', NOT 'Defaulted'. V_OC_TS_MONTH_SUMMARY derives month_status
    -- as one of four values only -- 'No employees', 'Rejected', 'Approved',
    -- 'Pending' -- so a defaulted month reads as Pending and the first version
    -- of this test matched a value that cannot occur. Every project refused.
    --
    -- 'Rejected' still blocks even on advance closure, and deliberately: a
    -- rejection is a manager actively saying no, which is the opposite of the
    -- silence advance closure exists to override.
    SELECT COUNT(*),
           SUM(CASE WHEN month_status = 'Approved'
                      OR (p_confirm_type = 'Advance closure'
                          AND month_status = 'Pending')
                    THEN 1 ELSE 0 END)
      INTO v_emps, v_appr
      FROM v_oc_ts_month_summary
     WHERE project_id = p_project_id AND period_id = p_period_id;

    IF NVL(v_emps,0) = 0 THEN
      RAISE_APPLICATION_ERROR(-20020,
        'There is no approved time on this project for the period.');
    END IF;

    IF v_emps <> NVL(v_appr,0) THEN
      RAISE_APPLICATION_ERROR(-20020,
        'Approve every employee''s month before confirming to accrual. '
     || 'If a cut-off has passed and the hours must go out without those '
     || 'approvals, confirm with type ''Advance closure'' -- which accepts '
     || 'Defaulted months and records that it did.');
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
      client_role,
      wbs_task, wbs_task_name, work_date,
      billable_hours, non_billable_hours, leave_hours, unbilled_reason,
      entry_type, flag, action_date,
      source_ts_id, source_adj_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           -- The person's role on this project, copied at confirmation.
           -- A SCALAR SUBQUERY, not a join: OC_TIME_ALLOCATION can hold more
           -- than one row per person per project across date ranges, and a
           -- join would multiply every entry into the interface.
           (SELECT MAX(al.client_role) FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id
               AND al.project_id  = e.project_id),
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

    -- THERE IS NO 'CLOSED' STATUS. Confirmed 14-Aug: "there is nothing called
    -- closed -- if the cut-off date is passed it will not be editable, and if
    -- it is rejected it becomes editable but will be late submission; then if
    -- the delivery cut-off is crossed it goes as such, and if there is any
    -- change needed it goes as adjustments."
    --
    -- So closure is not something that happens TO a week. Editability already
    -- derives from the period's cut-offs (V_OC_TIME_CUTOFFS -> EDITABLE_FLAG),
    -- and a change after the cut-off is an ADJUSTMENT, which apply_adjustment
    -- and run_accrual_top_up already handle. Writing 'Closed' over the week
    -- destroyed the approval outcome -- an approved week and an overridden-
    -- and-approved one became indistinguishable the moment the month
    -- confirmed, and the audit question "who approved this, and was it
    -- overridden" stopped being answerable.
    --
    -- The confirmation itself is recorded on OC_TS_MONTH_CONFIRM, which is
    -- where a month-level fact belongs. Nothing is lost by not stamping it on
    -- every week.
    NULL;

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
          client_role,
          wbs_task, wbs_task_name, work_date,
          billable_hours, non_billable_hours, leave_hours, unbilled_reason,
          entry_type, flag, action_date,
          source_ts_id, source_adj_id, batch_id, trace_id)
        SELECT pe.period_name, pe.period_year, pe.period_month, c.confirm_id,
               w.employee_id, wk.employee_name, wk.worker_type,
               p.project_number, p.project_name, p.customer_name, p.revenue_model,
               (SELECT MAX(al.client_role) FROM oc_time_allocation al
                 WHERE al.employee_id = w.employee_id
                   AND al.project_id  = e.project_id),
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
