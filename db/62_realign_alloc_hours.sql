--==============================================================
-- time/62_realign_alloc_hours.sql
-- O2C Timesheet Module — a changed allocation must reach days already built
--
-- The allocation percentages became real on 17-Aug-2026 (PJT_PROJECT_RESOURCE,
-- see integration/bip/extracts.py). RI2824 went from 100/100 across two
-- projects to 50/25/25 across three. The cache took it; the timesheet did not:
--
--   444        8h   should be 4   (50% of an 8h day)
--   555        2h   correct       -- a NEW row, built from the new percentage
--   PCS10034   8h   should be 2   (25%)
--
-- Eighteen hours against a standard of eight. Only the new allocation is right,
-- and that is the tell: populate's guard is NOT EXISTS a row for this cell, so
-- it seeds a cell once and never revisits it. A percentage that changes after
-- the month is built reaches nothing.
--
-- THIS WIDENS 61 RATHER THAN ADDING A SECOND PROCEDURE. db/61 restored rows
-- stranded at ZERO by a withdrawn absence, computing the figure from the
-- allocation to do it. That is this same statement with a narrower predicate:
-- prepopulated hours are DERIVED, so the rule is simply that they equal what
-- they derive to. 61's case is "derives to 8, holds 0"; this one adds "derives
-- to 4, holds 8". Same name, same signature, so ords/13 and db/45 keep calling
-- it with no change.
--
-- WHAT IS STILL NEVER TOUCHED
--   SOURCE = 'Prepopulated' only. Hours somebody typed are theirs even when
--   they disagree with the allocation -- that is a conversation for a manager,
--   not a correction for a job. And a day with an APPROVED absence is left
--   exactly as it is, because zero there is deliberate.
--
-- Idempotent: a second run finds every row already equal and does nothing.
--
-- Depends on: time/09, 44, 61. Supersedes 61's procedure body.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_RESTORE_DEFAULT_HOURS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'OC_TIME_RESTORE_DEFAULT_HOURS does not exist. Run 61 first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] The rule, as a view, so the answer can be read before it is applied
PROMPT ============================================================

-- Every prepopulated work row, what it holds, and what the allocation says it
-- should hold. A view because "why did my hours change" deserves an answer
-- that can be queried after the fact.
CREATE OR REPLACE VIEW v_oc_ts_entry_expected AS
SELECT e.ts_entry_id,
       e.ts_week_id,
       w.employee_id,
       w.approval_status,
       e.entry_date,
       e.project_id,
       p.project_number,
       e.hours AS held_hours,
       NVL(e.standard_hours,
           (SELECT wk.std_hours_per_day FROM oc_time_worker wk
             WHERE wk.employee_id = w.employee_id)) AS std_hours,
       NVL((SELECT MAX(al.alloc_pct) FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id
               AND al.project_id  = e.project_id
               AND al.status      = 'Active'
               -- The allocation in force ON THAT DAY, not merely active now.
               -- 555 starts 17-Aug for RI2824, so earlier days in the same
               -- month must not be apportioned by it.
               AND e.entry_date BETWEEN al.start_date
                                    AND NVL(al.end_date, DATE '4712-12-31')), 0)
         AS alloc_pct,
       -- populate's arithmetic exactly, including the 15-minute rounding
       -- CHK_OC_TSE_QUARTER (RULE-005) requires.
       ROUND(NVL(NVL(e.standard_hours,
                     (SELECT wk.std_hours_per_day FROM oc_time_worker wk
                       WHERE wk.employee_id = w.employee_id)), 0)
             * NVL((SELECT MAX(al.alloc_pct) FROM oc_time_allocation al
                     WHERE al.employee_id = w.employee_id
                       AND al.project_id  = e.project_id
                       AND al.status      = 'Active'
                       AND e.entry_date BETWEEN al.start_date
                                            AND NVL(al.end_date, DATE '4712-12-31')), 0)
             / 100 * 4) / 4 AS expected_hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_project p ON p.project_id = e.project_id
 WHERE e.source     = 'Prepopulated'
   AND e.is_leave   = 'N'
   AND e.entry_type IN ('Actual','Default')
   -- A day genuinely on leave carries zero on purpose.
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = w.employee_id
                      AND ab.absence_date    = e.entry_date
                      AND ab.approval_status = 'Approved');

PROMPT ============================================================
PROMPT [2/4] What disagrees, in the open period
PROMPT ============================================================

COLUMN employee_id FORMAT A11
COLUMN project_number FORMAT A12
SELECT x.employee_id, x.project_number,
       x.alloc_pct, x.std_hours,
       x.held_hours, x.expected_hours,
       COUNT(*) AS days
  FROM v_oc_ts_entry_expected x
  JOIN oc_time_period pe ON pe.status = 'Open'
                        AND x.entry_date BETWEEN pe.start_date AND pe.end_date
 WHERE x.held_hours <> x.expected_hours
 GROUP BY x.employee_id, x.project_number, x.alloc_pct, x.std_hours,
          x.held_hours, x.expected_hours
 ORDER BY x.employee_id, x.project_number
 FETCH FIRST 30 ROWS ONLY;

PROMPT
PROMPT --- and per person, the daily total before and after
SELECT x.employee_id, x.entry_date,
       SUM(x.held_hours)     AS holds_now,
       SUM(x.expected_hours) AS should_hold
  FROM v_oc_ts_entry_expected x
  JOIN oc_time_period pe ON pe.status = 'Open'
                        AND x.entry_date BETWEEN pe.start_date AND pe.end_date
 WHERE x.employee_id IN ('RI2824','RI2894','RI9001','RI2249')
 GROUP BY x.employee_id, x.entry_date
HAVING SUM(x.held_hours) <> SUM(x.expected_hours)
 ORDER BY x.employee_id, x.entry_date
 FETCH FIRST 25 ROWS ONLY;

PROMPT ============================================================
PROMPT [3/4] OC_TIME_RESTORE_DEFAULT_HOURS, widened
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_restore_default_hours(
  p_from        IN  DATE,
  p_to          IN  DATE,
  p_employee_id IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'LEAVE_RESTORE',
  o_restored    OUT NUMBER)
IS
BEGIN
  o_restored := 0;

  FOR e IN (SELECT * FROM v_oc_ts_entry_expected x
             WHERE x.entry_date BETWEEN p_from AND p_to
               AND (p_employee_id IS NULL OR x.employee_id = p_employee_id)
               AND x.held_hours <> x.expected_hours
               -- An allocation that resolves to nothing is a different fault
               -- (no active row covering the day) and zeroing the timesheet
               -- over it would destroy hours to fix a lookup.
               AND x.expected_hours > 0)
  LOOP
    UPDATE oc_ts_entry
       SET hours      = e.expected_hours,
           updated_by = p_actor,
           updated_on = SYSTIMESTAMP
     WHERE ts_entry_id = e.ts_entry_id;
    o_restored := o_restored + 1;

    -- The hours moved after somebody decided the week, which is DailyChange.
    -- A Pending week needs no event; nobody has judged it yet.
    IF e.approval_status <> 'Pending' THEN
      DECLARE
        v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', p_actor, v_s, v_a, v_f);
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(o_restored
    || ' day-row(s) realigned to their allocation');
END oc_time_restore_default_hours;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Apply, then prove the day adds up
PROMPT ============================================================

DECLARE
  v_from DATE;
  v_to   DATE;
  v_n    NUMBER;
BEGIN
  SELECT MIN(start_date) - 92, MAX(end_date)
    INTO v_from, v_to
    FROM oc_time_period WHERE status = 'Open';

  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('No open period; nothing realigned.');
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Realigning ' || TO_CHAR(v_from,'DD-Mon-YY')
                       || ' .. ' || TO_CHAR(v_to,'DD-Mon-YY'));
  oc_time_restore_default_hours(v_from, v_to, NULL, 'ALLOC_REALIGN', v_n);
END;
/

PROMPT
PROMPT --- nothing should disagree now
SELECT COUNT(*) AS still_wrong
  FROM v_oc_ts_entry_expected x
 WHERE x.held_hours <> x.expected_hours
   AND x.expected_hours > 0;

PROMPT
PROMPT --- and no working day should exceed its standard from prepopulation alone
COLUMN employee_id FORMAT A11
SELECT w.employee_id, TO_CHAR(e.entry_date,'YYYY-MM-DD') AS entry_date,
       SUM(e.hours) AS seeded, MAX(e.standard_hours) AS standard
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_period pe ON pe.status = 'Open'
                        AND e.entry_date BETWEEN pe.start_date AND pe.end_date
 WHERE e.source = 'Prepopulated' AND e.is_leave = 'N'
   AND e.entry_type IN ('Actual','Default')
 GROUP BY w.employee_id, e.entry_date
HAVING SUM(e.hours) > MAX(e.standard_hours)
 ORDER BY 3 DESC
 FETCH FIRST 20 ROWS ONLY;

PROMPT
PROMPT A row above means that person's allocations still total more than 100%
PROMPT in PPM for that day. That is a PPM correction, not a timesheet one -- the
PROMPT module is faithfully apportioning what it was given.
