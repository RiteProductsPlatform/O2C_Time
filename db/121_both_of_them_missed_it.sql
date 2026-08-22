--==============================================================
-- time/121_both_of_them_missed_it.sql
-- O2C Timesheet Module -- DEFAULTED_BY can say BOTH, and the salary hold
-- follows it
--
-- Asked 22-Aug:
--
--   "At the delivery cut-off, a week the employee never submitted is stamped
--    EMPLOYEE rather than MANAGER - correct. But if manager also missed then
--    we need to have both."
--
--   "Salary hold is not dependent on the manager approval. Salary hold is
--    dependent only on the payroll cutoff."
--
-- -- WHAT WAS ALREADY TRUE, AND IS LEFT ALONE -------------------
--
-- Two of those are already how it works, and it is worth writing down so
-- nobody "fixes" them later:
--
--   SALARY HOLD ALREADY KEYS ON THE PAYROLL CUT-OFF. run_salary_stopping
--   reads V_OC_TIME_PAYROLL_WINDOW and tests pw.cutoff_passed = 'Y', per
--   country, and resolves each worker's own date through
--   oc_time_payroll_cutoff. It never looks at approval. A manager's silence
--   cannot hold anybody's pay and never could.
--
--   THE TWO-AXIS MODEL ALREADY EXPRESSES "BOTH MISSED". DeliveryCutoff leaves
--   the submission axis untouched and moves only approval, so a week reads
--   SUBMISSION_STATUS = 'Defaulted' (employee missed) alongside
--   APPROVAL_STATUS = 'ManagerDefaulted' (manager missed). db/27's own comment
--   on that rule says as much: "Defaulted + Manager Defaulted is expressible".
--
-- So the gap is not in the model. It is in DEFAULTED_BY, which is the
-- revision-2 COLLAPSED column -- one value where the V4 axes carry two facts
-- -- and it admits ('EMPLOYEE','MANAGER') only. Asked to record both, it
-- cannot.
--
-- -- WHY WIDEN THE OLD COLUMN RATHER THAN DROP IT ---------------
--
-- The honest answer to "DEFAULTED_BY cannot hold both" is that Phase 3 removes
-- it and the axes take over. That is not today's job: seven filters in
-- run_salary_stopping read it, so it decides whose pay is held, and a column
-- that decides that is not one to leave half-expressive while waiting for a
-- phase that has not started.
--
-- 'BOTH' therefore joins the CHECK, and the salary filters widen to
-- IN ('EMPLOYEE','BOTH'). The employee missed their cut-off in both cases --
-- that is what holds the pay -- and the manager's failure is recorded beside
-- it rather than instead of it.
--
-- READ THE WIDENING CAREFULLY: it is IN ('EMPLOYEE','BOTH'), never
-- IN ('EMPLOYEE','BOTH','MANAGER'). A week where ONLY the manager was late is
-- still not a salary hold, and that is RULE-016 and TIMESHEET_FLOW section 01
-- -- "the delivery cut-off must never hold the employee's salary". Widening
-- one step further would quietly reverse a decision this module has taken
-- twice.
--
-- Idempotent. Depends on: time/03, 09, 27.
-- RUN db/09 AFTER THIS: run_delivery_defaulting and run_salary_stopping are
-- edited there.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/4] Who is blamed for what right now
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN defby       FORMAT A10
SELECT p.period_name,
       NVL(w.defaulted_by,'(null)') AS defby,
       w.submission_status,
       w.approval_status,
       COUNT(*) AS weeks
  FROM oc_ts_week w
  JOIN oc_time_period p ON p.period_id = w.period_id
 GROUP BY p.period_name, w.defaulted_by, w.submission_status, w.approval_status
 ORDER BY p.period_name, 2, 3, 4;

PROMPT
PROMPT A row reading Defaulted / ManagerDefaulted with DEFAULTED_BY = EMPLOYEE
PROMPT is the case this script is about: the axes already say both missed and
PROMPT the collapsed column can only name one of them.

PROMPT ============================================================
PROMPT [2/4] Let DEFAULTED_BY say BOTH
PROMPT ============================================================

-- Two constraints carry the value list and they must move together. The
-- second was added by a later ALTER in db/03; dropping and recreating both is
-- the only way to be sure neither is left behind on a re-run.
DECLARE
  PROCEDURE redo(p_name VARCHAR2, p_ddl VARCHAR2) IS
  BEGIN
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_week DROP CONSTRAINT ' || p_name;
      DBMS_OUTPUT.PUT_LINE('  dropped ' || p_name);
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE = -2443 THEN
        DBMS_OUTPUT.PUT_LINE('  ' || p_name || ' not present');
      ELSE RAISE; END IF;
    END;
    EXECUTE IMMEDIATE p_ddl;
    DBMS_OUTPUT.PUT_LINE('  created ' || p_name);
  END redo;
BEGIN
  redo('CHK_OC_TSW_DEFBY',
       q'~ALTER TABLE oc_ts_week ADD CONSTRAINT chk_oc_tsw_defby
           CHECK (defaulted_by IS NULL
                  OR defaulted_by IN ('EMPLOYEE','MANAGER','BOTH'))~');
END;
/

COLUMN search_condition_vc FORMAT A72
SELECT constraint_name, search_condition_vc
  FROM user_constraints
 WHERE table_name = 'OC_TS_WEEK'
   AND constraint_name LIKE 'CHK_OC_TSW_DEFBY%'
 ORDER BY constraint_name;

PROMPT
PROMPT Both rows must now list BOTH. CHK_OC_TSW_DEFBY_REQ is untouched on
PROMPT purpose -- it only requires the column to be non-null for a Defaulted
PROMPT week, and says nothing about which values are legal.

PROMPT ============================================================
PROMPT [3/4] Correct the weeks that already missed on both sides
PROMPT ============================================================

-- The axes have been recording this correctly all along, so the history is
-- recoverable rather than lost: every week whose submission says the employee
-- defaulted AND whose approval says the manager did is a BOTH that could not
-- be written at the time.
--
-- Only where DEFAULTED_BY currently reads EMPLOYEE. A NULL there means the
-- employee submitted on time and only the manager was late -- that is a
-- MANAGER, not a BOTH, and section [4] leaves it to the job to stamp.
UPDATE oc_ts_week w
   SET w.defaulted_by = 'BOTH',
       w.updated_by   = 'DB_121',
       w.updated_on   = SYSTIMESTAMP
 WHERE w.defaulted_by      = 'EMPLOYEE'
   AND w.submission_status = 'Defaulted'
   AND w.approval_status   = 'ManagerDefaulted';

BEGIN
  DBMS_OUTPUT.PUT_LINE('  weeks restamped BOTH: ' || SQL%ROWCOUNT);
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/4] What the salary hold will now catch
PROMPT ============================================================

-- Read-only, and the number to check before running db/09: these are the
-- weeks whose pay is held. A BOTH belongs here -- the employee did miss their
-- cut-off -- and a MANAGER does not.
SELECT NVL(w.defaulted_by,'(null)') AS defby,
       COUNT(*) AS weeks,
       COUNT(DISTINCT w.employee_id) AS people,
       CASE WHEN NVL(w.defaulted_by,'x') IN ('EMPLOYEE','BOTH')
            THEN 'HELD' ELSE 'not held' END AS salary
  FROM oc_ts_week w
 WHERE w.submission_status = 'Defaulted'
 GROUP BY w.defaulted_by
 ORDER BY 1;

PROMPT
PROMPT MANAGER must read "not held". If a manager's lateness ever starts
PROMPT holding pay, RULE-016 has been broken -- see the header.
