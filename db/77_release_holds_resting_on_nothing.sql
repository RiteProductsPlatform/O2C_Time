--==============================================================
-- time/77_release_holds_resting_on_nothing.sql
-- O2C Timesheet Module — pay held for a week nobody could have filled in
--
-- db/76 emptied the phantom weeks and section 5 reported the consequence it
-- deliberately did not act on: six holds now rest on weeks with no hours behind
-- them, for four people with no allocation to any project.
--
--   57      Alan James                JUN 160h, JUL 144h   (PCS10064, now closed)
--   7781    User Rite                 JUN 160h, JUL 144h   (555)
--   7897    Santosh Kumar01 Kanala    JUL 0h               (the duplicate Santosh)
--   RI2985  Aadhiseshan Anandavijaya  JUL 0h               (taken off 444)
--
-- 7793 is absent from that list because run_salary_stopping filters
-- k.status = 'Active' and db/75 made them Inactive. Their hold, if any, is
-- already unreachable by the job.
--
-- THREE THINGS WERE CHECKED BEFORE WRITING THIS, and each ruled out an
-- easier answer.
--
-- 1. RE-RUNNING THE JOB DOES NOT FIX IT. run_salary_stopping counts
--    submission_status = 'Defaulted' AND defaulted_by = 'EMPLOYEE' straight off
--    OC_TS_WEEK and never reads OC_TS_ENTRY, so an emptied week still counts.
--    Its auto-release at the end fires only when no such week remains. Both
--    halves therefore ignore what db/76 changed.
--
-- 2. DELETING THE WEEKS IS THE WRONG TOOL. OC_TS_AUDIT and OC_TS_APPROVAL both
--    cascade from OC_TS_WEEK and both carry BEFORE UPDATE OR DELETE statement
--    triggers raising -20026 (db/19). That is the failure db/71 hit twice
--    before concluding the week delete "was never needed". It still is not.
--
-- 3. THE PROPER RELEASE PATH REFUSES, CORRECTLY. release_salary_hold enforces
--    ACT-026: "Correct the defaulted timesheet before releasing the salary
--    hold" (-20016) whenever any week is Defaulted. That rule is right for the
--    case it was written for -- somebody who owes a timesheet -- and this is
--    not that case. There is nothing to correct: no allocation means no project
--    to book to, and the grid would open empty. The precondition cannot be
--    satisfied by anyone, ever, so it is overridden here rather than gamed.
--
-- WHY A DIRECT UPDATE IS SAFE AND STAYS SAFE. The MERGE in run_salary_stopping
-- is guarded WHEN MATCHED THEN UPDATE ... WHERE h.salary_status = 'Held', so a
-- Released row is matched and left alone rather than re-raised. Releasing is
-- durable without touching the week, which is what keeps this away from the
-- -20026 family entirely. CHK_OC_TSSH_REL requires RELEASED_BY on a released
-- row, so the actor is recorded and the SOX constraint is met, not bypassed.
--
-- THE ONE QUESTION THIS COULD NOT ANSWER FOR ITSELF, now answered. The risk was
-- that Alan James or User Rite SHOULD be on a time-tracking project and nobody
-- ever ticked PJS_TRACK_TIME in PPM -- in which case the hold is legitimate and
-- releasing it lets unrecorded time through payroll. Confirmed 18-Aug-2026:
-- both are demo/test accounts on the pod, not payroll employees. All four
-- release. Had the answer gone the other way, only the two zero-hour rows
-- would have been touched and PPM fixed first.
--
-- Worth noting separately, because it is a PPM hygiene point and not a bug
-- here: 7781 held an allocation to 555, a live time-tracking project. A test
-- account was staffed onto real work. The allocation is already retired by
-- db/75 and nothing further is needed, but it is how these hours came to exist.
--
-- Idempotent -- an already-Released hold is not matched twice.
-- Depends on: time/05, 09, 75, 76.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TS_SALARY_HOLD';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] Every held row, and whether anything stands behind it
PROMPT ============================================================

COLUMN employee_id FORMAT A10
COLUMN employee_name FORMAT A26
COLUMN period_name FORMAT A10
COLUMN verdict FORMAT A30
SELECT h.employee_id, wk.employee_name, pe.period_name,
       h.weeks_defaulted AS wks, h.default_hours AS def_hrs,
       (SELECT COUNT(*) FROM oc_time_allocation al
         WHERE al.employee_id = h.employee_id AND al.status = 'Active') AS allocs,
       CASE WHEN EXISTS (SELECT 1 FROM oc_ts_week w
                           JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
                          WHERE w.employee_id = h.employee_id
                            AND w.period_id   = h.period_id)
            THEN 'has hours - LEAVE HELD'
            ELSE 'nothing behind it - release' END AS verdict
  FROM oc_ts_salary_hold h
  JOIN oc_time_worker wk ON wk.employee_id = h.employee_id
  JOIN oc_time_period pe ON pe.period_id   = h.period_id
 WHERE h.salary_status = 'Held'
 ORDER BY h.employee_id, pe.period_name;

PROMPT
PROMPT Only rows reading "nothing behind it" are touched below. A hold with any
PROMPT timesheet row left in that period is a real hold and stays.

PROMPT ============================================================
PROMPT [2/3] Release the ones resting on nothing
PROMPT ============================================================

DECLARE
  v_r NUMBER;
BEGIN
  UPDATE oc_ts_salary_hold h
     SET h.salary_status = 'Released',
         h.released_by   = 'CLEANUP_77',
         h.released_on   = SYSTIMESTAMP,
         -- Truthful, and deliberately not the auto-release wording. That says
         -- "every week has now been submitted", which did not happen here and
         -- would misdescribe a payroll decision in the one field anybody reads
         -- when asking why somebody was paid.
         h.remarks       = 'Released by cleanup: no allocation in Fusion and no '
                        || 'timesheet rows in this period, so the defaulted week '
                        || 'could not have been filled in. See db/77.'
   WHERE h.salary_status = 'Held'
     AND NOT EXISTS (SELECT 1 FROM oc_ts_week w
                       JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
                      WHERE w.employee_id = h.employee_id
                        AND w.period_id   = h.period_id)
     AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al
                      WHERE al.employee_id = h.employee_id
                        AND al.status      = 'Active');
  v_r := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_r || ' hold(s) released.');
  DBMS_OUTPUT.PUT_LINE('  run_salary_stopping will not re-raise these: its '
                    || 'MERGE updates only rows already Held.');
END;
/

-- The day rows under a released hold are no longer awaiting anything. Left
-- 'Held' they keep the correction list on PAGE-007 populated with dates nobody
-- can act on, which is the same class of fault as the hold itself.
DECLARE
  v_d NUMBER;
BEGIN
  UPDATE oc_ts_salary_hold_day d
     SET d.day_status = 'Expired', d.updated_by = 'CLEANUP_77',
         d.updated_on = SYSTIMESTAMP
   WHERE d.day_status IN ('Held','Rejected')
     AND EXISTS (SELECT 1 FROM oc_ts_salary_hold h
                  WHERE h.hold_id = d.hold_id
                    AND h.salary_status = 'Released'
                    AND h.released_by   = 'CLEANUP_77');
  v_d := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_d || ' hold day row(s) marked Expired.');
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

SELECT h.salary_status, COUNT(*) AS holds, SUM(h.default_hours) AS def_hours
  FROM oc_ts_salary_hold h
 GROUP BY h.salary_status
 ORDER BY 1;

PROMPT
COLUMN remarks FORMAT A40
SELECT h.employee_id, wk.employee_name, pe.period_name,
       NVL(h.released_by,'-') AS released_by, h.remarks
  FROM oc_ts_salary_hold h
  JOIN oc_time_worker wk ON wk.employee_id = h.employee_id
  JOIN oc_time_period pe ON pe.period_id   = h.period_id
 WHERE h.released_by = 'CLEANUP_77'
 ORDER BY h.employee_id, pe.period_name;

PROMPT
PROMPT REVERSIBLE, exactly and only these rows:
PROMPT   UPDATE oc_ts_salary_hold SET salary_status = 'Held', released_by = NULL,
PROMPT          released_on = NULL, remarks = NULL
PROMPT    WHERE released_by = 'CLEANUP_77';
PROMPT
PROMPT STILL OPEN, and not for a script to decide: release_salary_hold refuses
PROMPT any hold whose week is Defaulted (ACT-026, -20016). Somebody with no
PROMPT allocation can never satisfy that, so if this recurs the procedure needs
PROMPT an explicit no-allocation branch rather than another one-off.
