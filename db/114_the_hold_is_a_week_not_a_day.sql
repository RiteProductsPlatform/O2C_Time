--==============================================================
-- time/114_the_hold_is_a_week_not_a_day.sql
-- O2C Timesheet Module — the employee's salary-hold screen is week-grained,
-- and a hold older than the window cannot be typed into
--
-- Asked 21-Aug: "Salary Held - lets keep it in weekwise, daywise is too much
-- lines in the screen, and if the week is 3 months before lets not allow a
-- edit".
--
-- ── THE BRD AGREES, AND IT IS WORTH RECORDING WHY ────────────
--
-- doc/O2C_Timesheet_User_Journey.html states the grain twice, and the first is
-- marked Confirmed rather than Open:
--
--   "A per-employee split of WEEKS submitted vs defaulted with applied hours
--    and default hours (e.g. 2 of 4 weeks submitted, 2 defaulted). Only the
--    defaulted weeks hold salary; the submitted weeks are unaffected."
--
--   "Salary Stopping shows WEEKS submitted vs defaulted with applied vs
--    default hours."
--
-- So the manager's screen (main-salary-stopping) was already right -- its
-- breakdown dialog is week-grained. The DAY grain leaked in through the
-- EMPLOYEE self-view, main-my-salary-hold, which lists one row per held date.
-- That screen is the one the same document lists as still OPEN:
--
--   "BRD 4.4 gives the employee a screen to view un-submitted dates and
--    resubmit with a reason. Reconcile with the Manager-only decision."
--
-- A month of held dates is twenty-odd rows of a person's own missing
-- timesheet, which is a wall of text where the useful question is "which weeks
-- do I owe". Hence this.
--
-- OC_TS_SALARY_HOLD_DAY IS NOT TOUCHED. The day rows stay: they are what the
-- release logic counts (a hold releases when no day is left un-approved), and
-- they are the audit of which dates were actually missing. This changes what
-- the employee is SHOWN, not what is recorded. Collapsing the storage to weeks
-- would throw away the only record of which dates a defaulted week covered.
--
-- ── "3 MONTHS" ANSWERS A QUESTION THE BRD LEFT OPEN ──────────
--
-- The same document has, unresolved:
--
--   "Salary hold - contractors & window expiry. Open. If the 60-day resubmit
--    window expires, is pay forfeited or escalated?"
--
-- CFG-012 / HOLD_RELEASE_DAYS already exists and already defaults to 60, and
-- the expiry is already enforced -- assert_editable's salary-hold keyhole
-- reads h.window_expires_on, so a lapsed hold already refuses the edit. So
-- this is a number change, not a new rule: 60 -> 90.
--
-- It does NOT answer the forfeited-or-escalated half. Nothing here forfeits
-- anything; the hold simply stops being editable and stays Held, which is the
-- state that makes it visible to the manager. That question is still open.
--
-- Idempotent. Depends on: time/01, 05, 09, 15.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/4] The window becomes 90 days
PROMPT ============================================================

-- Two places hold the number and they must move together, or the screen and
-- the procedure disagree about whether a hold is still live:
--   OC_TIME_CONFIG        CFG-012, the global default
--   OC_TIME_PERIOD        HOLD_RELEASE_DAYS, the per-period override
UPDATE oc_time_config
   SET config_value = '90',
       description  = 'CFG-012 Days an employee/contractor can resubmit a '
                   || 'defaulted timesheet. 90 = about three months '
                   || '(decision 21-Aug-2026, was 60).',
       updated_by   = 'DECISION_21AUG2026',
       updated_on   = SYSTIMESTAMP
 WHERE config_name = 'HOLD_RELEASE_DAYS';

BEGIN DBMS_OUTPUT.PUT_LINE('config rows updated: ' || SQL%ROWCOUNT); END;
/

-- Only periods that have not closed. Reopening the window on a month already
-- settled would revive holds finance has finished with.
UPDATE oc_time_period
   SET hold_release_days = 90,
       updated_by        = 'DECISION_21AUG2026',
       updated_on        = SYSTIMESTAMP
 WHERE NVL(hold_release_days, 60) <> 90
   AND status <> 'Closed';

BEGIN DBMS_OUTPUT.PUT_LINE('period rows updated: ' || SQL%ROWCOUNT); END;
/
COMMIT;

-- Existing HELD holds get the longer window too. A hold stamped under the old
-- 60 keeps a WINDOW_EXPIRES_ON computed from it, so without this the change
-- would apply only to holds created from tomorrow -- and the person asking for
-- three months would still be refused at day 61.
UPDATE oc_ts_salary_hold h
   SET h.window_expires_on = TRUNC(h.held_on) + 90,
       h.updated_by        = 'DECISION_21AUG2026',
       h.updated_on        = SYSTIMESTAMP
 WHERE h.salary_status = 'Held'
   AND h.window_expires_on IS NOT NULL
   AND h.window_expires_on <> TRUNC(h.held_on) + 90;

BEGIN DBMS_OUTPUT.PUT_LINE('live holds re-stamped: ' || SQL%ROWCOUNT); END;
/
COMMIT;

PROMPT ============================================================
PROMPT [2/4] The employee's view, one row per WEEK
PROMPT ============================================================

-- Replaces the day list behind main-my-salary-hold. Every column the screen
-- needs is here so the page does no arithmetic (§9: no logic in a binding).
--
-- HELD_DATES is the day detail folded into one cell rather than thrown away --
-- the employee still needs to know WHICH dates, they just do not need a row
-- each. LISTAGG is capped: a clipped week is at most 7 days, so it cannot
-- overflow, but a week that somehow carried more would raise ORA-01489 and
-- take the whole screen down, hence the ON OVERFLOW TRUNCATE.
--
-- EDITABLE_FLAG is computed HERE and also enforced in assert_editable. The
-- screen must be able to explain a disabled button (§6), and the database
-- remains the control -- a caller hitting ORDS directly meets the same
-- refusal.
CREATE OR REPLACE VIEW v_oc_ts_my_hold_weeks AS
SELECT h.hold_id,
       h.employee_id,
       d.ts_week_id,
       w.period_id,
       p.period_name,
       w.week_index,
       w.week_start,
       w.week_end,
       TO_CHAR(w.week_start,'DD Mon') || ' - '
         || TO_CHAR(w.week_end,'DD Mon') AS week_range,
       w.week_status,
       w.approval_status,
       COUNT(*)                                    AS held_days,
       SUM(CASE WHEN d.day_status = 'Held'      THEN 1 ELSE 0 END) AS days_outstanding,
       SUM(CASE WHEN d.day_status = 'Corrected' THEN 1 ELSE 0 END) AS days_resubmitted,
       SUM(CASE WHEN d.day_status = 'Approved'  THEN 1 ELSE 0 END) AS days_approved,
       SUM(CASE WHEN d.day_status = 'Rejected'  THEN 1 ELSE 0 END) AS days_rejected,
       NVL(SUM(d.expected_hours),  0) AS expected_hours,
       NVL(SUM(d.corrected_hours), 0) AS corrected_hours,
       LISTAGG(TO_CHAR(d.work_date,'DD Mon'), ', ' ON OVERFLOW TRUNCATE)
         WITHIN GROUP (ORDER BY d.work_date) AS held_dates,
       h.salary_status,
       h.window_expires_on,
       TRUNC(h.window_expires_on) - TRUNC(SYSDATE) AS days_left,
       -- One row of the week is enough to decide the week: a week is editable
       -- while the hold is live, the window has not lapsed, and the manager
       -- has not already settled it.
       CASE WHEN h.salary_status = 'Held'
             AND (h.window_expires_on IS NULL
                  OR TRUNC(SYSDATE) <= h.window_expires_on)
             AND w.approval_status NOT IN ('Approved')
            THEN 'Y' ELSE 'N' END AS editable_flag,
       CASE WHEN h.salary_status <> 'Held'                       THEN 'Released'
            WHEN TRUNC(SYSDATE) > NVL(h.window_expires_on, TRUNC(SYSDATE))
                                                                 THEN 'Window closed'
            WHEN w.approval_status = 'Approved'                  THEN 'Approved'
            ELSE 'Open for correction' END AS edit_state
  FROM oc_ts_salary_hold_day d
  JOIN oc_ts_salary_hold     h ON h.hold_id    = d.hold_id
  JOIN oc_ts_week            w ON w.ts_week_id = d.ts_week_id
  JOIN oc_time_period        p ON p.period_id  = w.period_id
 GROUP BY h.hold_id, h.employee_id, d.ts_week_id, w.period_id, p.period_name,
          w.week_index, w.week_start, w.week_end, w.week_status,
          w.approval_status, h.salary_status, h.window_expires_on;

SHOW ERRORS

COLUMN period_name FORMAT A10
COLUMN week_range  FORMAT A18
COLUMN edit_state  FORMAT A20
SELECT employee_id, period_name, week_index, week_range,
       held_days, days_outstanding, edit_state
  FROM v_oc_ts_my_hold_weeks
 ORDER BY employee_id, week_start
 FETCH FIRST 15 ROWS ONLY;

PROMPT ============================================================
PROMPT [3/4] The window is refused in the database, not only on the screen
PROMPT ============================================================

-- assert_editable already reads h.window_expires_on, so a lapsed hold is
-- already refused -- but it falls through to the ORDINARY gates and the
-- employee gets "this week is locked", which is true and unhelpful. It does
-- not say that pay is held, that there WAS a window, or that it has closed.
--
-- A dedicated check, called before the keyhole, so the refusal names the real
-- reason. -20030 is the next free code in the business range.
CREATE OR REPLACE PROCEDURE oc_time_assert_hold_window(p_ts_week_id IN NUMBER)
IS
  v_lapsed NUMBER;
  v_exp    DATE;
BEGIN
  SELECT CASE WHEN EXISTS (
           SELECT 1
             FROM oc_ts_salary_hold_day d
             JOIN oc_ts_salary_hold     h ON h.hold_id = d.hold_id
            WHERE d.ts_week_id    = p_ts_week_id
              AND h.salary_status = 'Held'
              AND h.window_expires_on IS NOT NULL
              AND TRUNC(SYSDATE) > h.window_expires_on)
         THEN 1 ELSE 0 END
    INTO v_lapsed FROM dual;

  IF v_lapsed = 1 THEN
    SELECT MAX(h.window_expires_on) INTO v_exp
      FROM oc_ts_salary_hold_day d
      JOIN oc_ts_salary_hold     h ON h.hold_id = d.hold_id
     WHERE d.ts_week_id = p_ts_week_id;

    RAISE_APPLICATION_ERROR(-20030,
      'The correction window for this week closed on '
      || TO_CHAR(v_exp,'DD-Mon-YYYY')
      || '. It can no longer be edited - ask your manager.');
  END IF;
END oc_time_assert_hold_window;
/

SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Which holds are now past their window
PROMPT ============================================================

COLUMN nm FORMAT A28
SELECT h.employee_id, w.employee_name AS nm,
       TO_CHAR(h.held_on,'DD-Mon-YY')           AS held,
       TO_CHAR(h.window_expires_on,'DD-Mon-YY') AS expires,
       TRUNC(h.window_expires_on) - TRUNC(SYSDATE) AS days_left,
       h.salary_status
  FROM oc_ts_salary_hold h
  JOIN oc_time_worker    w ON w.employee_id = h.employee_id
 WHERE h.salary_status = 'Held'
 ORDER BY h.window_expires_on;

PROMPT
PROMPT A negative days_left is a hold the employee can no longer correct. Under
PROMPT the old 60 these would already have lapsed; at 90 most come back.
PROMPT
PROMPT NEXT: db/09_pkg_oc_time.sql - assert_editable is edited there to call
PROMPT oc_time_assert_hold_window.
