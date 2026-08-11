--==============================================================
-- time/92_month_end_close.sql
-- O2C Timesheet Module — run a period's month end and close it
--
-- Written for July 2026, but the period is a variable: set v_period in [1].
--
-- WHAT IT DOES, in the order the rules require
--
--   1  weekly defaulting     un-submitted weeks past the employee cut-off
--                            become Defaulted, DEFAULTED_BY='EMPLOYEE'
--   2  delivery defaulting   un-approved weeks past the delivery cut-off
--                            become Defaulted, DEFAULTED_BY='MANAGER'
--   3  salary stopping       holds salary for the EMPLOYEE-defaulted only
--   4  confirm to accrual    per project, 'Advance closure' where a month is
--                            Defaulted rather than Approved
--   5  close the period      status = 'Closed'
--
-- WHY DEFAULTED AND NOT "SUBMITTED" / "APPROVED"
--   The ask was "default submitted if not submitted, default approved if not
--   approved". The module records that as ONE status, Defaulted, plus
--   DEFAULTED_BY saying which side let the cut-off pass. That is not a naming
--   quibble: run_salary_stopping filters on DEFAULTED_BY='EMPLOYEE' precisely
--   so a MANAGER's lateness never holds the employee's salary (section 8.1).
--   Collapsing both into "Approved" would lose the distinction that decides
--   whether someone gets paid.
--
-- WHY SALARY STOPPING RUNS BEFORE THE CONFIRM
--   It reads week status. Confirming does not change status, but closing the
--   period does gate editing, and a hold raised after the fact cannot be
--   cleared by the employee resubmitting. Holds first, while the week is still
--   reachable.
--
-- DESTRUCTIVE IN EFFECT, not in shape: it writes statuses, holds salary and
-- hands hours to accrual. It deletes nothing, but a confirmed month is not
-- casually undone -- confirm_type 'Reopened' exists for that and is a
-- deliberate act.
--
-- Idempotent: each step skips work already done. Depends on: time/09, time/15
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT ============================================================
PROMPT [1/6] The period, and what it looks like now
PROMPT ============================================================

COLUMN period_name FORMAT A14
COLUMN status      FORMAT A8

SELECT p.period_id, p.period_name, p.status,
       TO_CHAR(p.delivery_cutoff,'DD-MON-YYYY') AS delivery_cutoff,
       TO_CHAR(p.finance_cutoff, 'DD-MON-YYYY') AS finance_cutoff,
       (SELECT COUNT(*) FROM oc_ts_week w WHERE w.period_id = p.period_id) AS weeks
  FROM oc_time_period p
 ORDER BY p.period_id;

-- Week statuses in the target period, BEFORE anything runs.
COLUMN week_status FORMAT A22
SELECT w.week_status, COUNT(*) AS weeks, COUNT(DISTINCT w.employee_id) AS people
  FROM oc_ts_week w
  JOIN oc_time_period p ON p.period_id = w.period_id
 WHERE p.period_name = 'JUL-2026'          -- <- the target period
 GROUP BY w.week_status
 ORDER BY w.week_status;

PROMPT
PROMPT Read that before continuing. Anything already Approved stays as it is --
PROMPT the defaulting jobs only touch weeks that missed a cut-off.

PROMPT
PROMPT ============================================================
PROMPT [2/6] Defaulting, then salary stopping
PROMPT ============================================================

DECLARE
  v_period NUMBER;
  v_name   VARCHAR2(30);
  v_job    NUMBER;
BEGIN
  SELECT period_id, period_name INTO v_period, v_name
    FROM oc_time_period WHERE period_name = 'JUL-2026';   -- <- the target period

  DBMS_OUTPUT.PUT_LINE('Period ' || v_name || ' (id ' || v_period || ')');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 56, '-'));

  -- Un-submitted past the employee cut-off. DEFAULTED_BY='EMPLOYEE', which is
  -- what makes the salary hold in step 3 apply to them.
  v_job := oc_time_pkg.run_weekly_defaulting(v_period, SYSDATE, 'MONTH_END');
  DBMS_OUTPUT.PUT_LINE('weekly defaulting    job ' || v_job);

  -- Un-approved past the delivery cut-off. DEFAULTED_BY='MANAGER' -- these do
  -- NOT hold salary, because a manager's lateness must never stop the
  -- employee's pay (section 8.1).
  v_job := oc_time_pkg.run_delivery_defaulting(v_period, SYSDATE, 'MONTH_END');
  DBMS_OUTPUT.PUT_LINE('delivery defaulting  job ' || v_job);

  -- Holds pay for the EMPLOYEE-defaulted. Runs while the weeks are still
  -- reachable: after the period closes the employee cannot resubmit to clear
  -- their own hold.
  v_job := oc_time_pkg.run_salary_stopping(v_period, 'MONTH_END');
  DBMS_OUTPUT.PUT_LINE('salary stopping      job ' || v_job);

  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT [3/6] Where every week stands now
PROMPT ============================================================

COLUMN week_status  FORMAT A22
COLUMN defaulted_by FORMAT A12
SELECT w.week_status, w.defaulted_by, COUNT(*) AS weeks
  FROM oc_ts_week w
  JOIN oc_time_period p ON p.period_id = w.period_id
 WHERE p.period_name = 'JUL-2026'
 GROUP BY w.week_status, w.defaulted_by
 ORDER BY w.week_status, w.defaulted_by;

PROMPT
PROMPT DEFAULTED_BY 'EMPLOYEE' rows are the ones now holding salary. 'MANAGER'
PROMPT rows are defaulted but paid.

PROMPT
PROMPT ============================================================
PROMPT [4/6] Salary holds raised
PROMPT ============================================================

COLUMN employee_id   FORMAT A14
COLUMN salary_status FORMAT A14
SELECT h.employee_id, h.salary_status,
       TO_CHAR(h.held_on,'DD-MON-YYYY') AS held_on,
       TO_CHAR(h.window_expires_on,'DD-MON-YYYY') AS window_expires
  FROM oc_ts_salary_hold h
  JOIN oc_time_period p ON p.period_id = h.period_id
 WHERE p.period_name = 'JUL-2026'
 ORDER BY h.employee_id;

PROMPT
PROMPT These people appear on the salary stopping page and can resubmit to
PROMPT clear the hold -- until the period closes in [6].

PROMPT
PROMPT ============================================================
PROMPT [5/6] Confirm each project to accrual
PROMPT ============================================================

-- 'Advance closure' where anything is Defaulted, 'Normal' where every month is
-- Approved. The type is recorded on OC_TS_MONTH_CONFIRM, so "why did this
-- month go out without approvals" has an answer later.
--
-- One project at a time, each in its own block: a project that refuses must
-- not stop the rest, and the reason has to name the project.
DECLARE
  v_period NUMBER;
  v_type   VARCHAR2(20);
  v_conf   NUMBER;
  v_ok     NUMBER := 0;
  v_bad    NUMBER := 0;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period WHERE period_name = 'JUL-2026';

  FOR pr IN (SELECT DISTINCT m.project_id, p.project_number, p.project_name
               FROM v_oc_ts_month_summary m
               JOIN oc_time_project p ON p.project_id = m.project_id
              WHERE m.period_id = v_period
              ORDER BY p.project_number)
  LOOP
    BEGIN
      SELECT CASE WHEN COUNT(*) = SUM(CASE WHEN month_status = 'Approved'
                                           THEN 1 ELSE 0 END)
                  THEN 'Normal' ELSE 'Advance closure' END
        INTO v_type
        FROM v_oc_ts_month_summary
       WHERE project_id = pr.project_id AND period_id = v_period;

      v_conf := oc_time_pkg.confirm_month(
                  p_project_id   => pr.project_id,
                  p_period_id    => v_period,
                  p_actor_emp_id => 'MONTH_END',
                  p_confirm_type => v_type,
                  p_actor        => 'MONTH_END');
      v_ok := v_ok + 1;
      DBMS_OUTPUT.PUT_LINE(RPAD(pr.project_number, 14) || RPAD(v_type, 18)
                        || 'confirm ' || v_conf);
    EXCEPTION WHEN OTHERS THEN
      v_bad := v_bad + 1;
      DBMS_OUTPUT.PUT_LINE(RPAD(pr.project_number, 14) || 'REFUSED - '
                        || SUBSTR(SQLERRM, 1, 90));
    END;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE(v_ok || ' project(s) confirmed, ' || v_bad || ' refused.');
  IF v_bad > 0 THEN
    DBMS_OUTPUT.PUT_LINE('DO NOT CLOSE while any project is refused -- closing '
                      || 'locks the weeks and the refusal cannot then be fixed '
                      || 'by approving.');
  END IF;
END;
/

PROMPT
PROMPT ============================================================
PROMPT [6/6] Close the period — ONLY if [5] refused nothing
PROMPT ============================================================

-- Commented out on purpose. Closing gates editing, so it is the last
-- irreversible step and it should follow a human reading [5], not a script
-- deciding on its own.
--
-- UPDATE oc_time_period
--    SET status = 'Closed', updated_by = 'MONTH_END', updated_on = SYSTIMESTAMP
--  WHERE period_name = 'JUL-2026';
-- COMMIT;

PROMPT Uncomment the UPDATE at the end of this file once [5] shows 0 refused.
PROMPT
PROMPT After closing: July is read-only but still VISIBLE -- every period stays
PROMPT open to view and only editing is gated, which is why the month picker
PROMPT lists Closed months with a chip rather than hiding them.
