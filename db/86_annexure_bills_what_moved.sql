--==============================================================
-- time/86_annexure_bills_what_moved.sql
-- O2C Timesheet Module — the same 8-for-2 error, on the invoice
--
-- Asked on reading db/85's verification: "here absence hours is coming as 8 but
-- for this project its only 2". The grid was fixed; the question is better than
-- the fix, because the number goes somewhere else too.
--
-- ── THE ANNEXURE BILLED THE WHOLE ABSENCE ────────────────────────────────
--
-- V_OC_TS_LLC_ANNEXURE (db/07) is REP-002, the appendix that travels WITH THE
-- INVOICE. It read:
--
--   l.absence_hours AS covered_billed_hours
--
-- So 555 was set to invoice 8 hours of recovered capacity for a day where its
-- loss was 2 -- the identical fourfold overstatement, on the one document that
-- reaches the client.
--
-- THERE ARE THREE NUMBERS HERE AND THEY ARE NOT INTERCHANGEABLE:
--
--   ABSENCE_HOURS       8   the person was away all day       (about the person)
--   LOSS_HOURS          2   what this project lost            (about the project)
--   COVER_HOURS_BILLED  2   what actually moved to billable   (about the recovery)
--
-- The annexure must bill the THIRD. Not the first, which is four times the
-- loss; and not the second either, because the loss is what was at stake and
-- not necessarily what was recovered -- a cover with only one spare hour
-- recovers one. Billing LOSS_HOURS would put a figure on the invoice that no
-- timesheet supports, and accrual would then report a different one from the
-- same event. Two documents, one event, two answers, which is the exact fault
-- db/84 was written to end.
--
-- The filter moves with it. It was BILLED_FLAG = 'Y', and llc 4 shows why that
-- is not the same question: approved through the old handler, flag set, zero
-- hours moved -- and therefore ON the annexure today, claiming 8. The annexure
-- now keys on the hours, so a row reaches the invoice when, and only when,
-- there are hours behind it.
--
-- BILLED_FLAG IS NOT CLEARED. The manager did approve the coverage; that is a
-- true fact and theirs. What did not happen is the billing. Two facts, kept
-- apart -- section [3/5] reports where they disagree instead of rewriting one
-- of them to match the other.
--
-- ── THE BILLING GUARD WAS THE EMPLOYEE'S, NOT THE MANAGER'S ──────────────
--
-- db/85 [5/6] could not complete llc 4:
--
--   ORA-20007: This week is locked. Only a manager can edit a defaulted
--              timesheet.
--
-- Read that message again. This IS a manager, doing the thing it says a manager
-- may do. db/84 reused oc_time_pkg.assert_editable, which is the gate the
-- EMPLOYEE's own screen passes through, and its LOCKED_FLAG branch exists to
-- stop the employee touching a week the weekly cut-off has defaulted.
--
-- Defaulting is the employee's failure to submit. It says nothing about whether
-- a colleague covered someone's leave, and it must not be what stops the
-- manager recording the commercial consequence of somebody else's absence.
--
-- So the guard becomes a manager's. What still refuses, and why:
--
--   week Approved / Overridden / Closed   a decision has been made, and moving
--                                         hours under it changes what was
--                                         approved without saying so
--   period not Open                       RULE-004 / RULE-007
--   month already confirmed               the hours reached accrual as
--                                         non-billable; moving them now makes
--                                         the timesheet disagree with what was
--                                         sent, and the fix for that is an
--                                         adjustment, not an edit
--
-- That keeps the decision taken on 20-Aug intact -- "manager should do this
-- before the weekly cutoff or monthly cutoff" -- while letting the one case
-- through whose refusal was an accident of which gate was reused.
--
-- SUPERSEDES db/85 [4/6], which is now a pointer to here. Re-running 85 after
-- this would otherwise restore the old guard silently, the same way re-running
-- 01 would have restored UK_OC_TP_SINGLE_OPEN.
--
-- Idempotent. Depends on: time/04, 05, 07, 08, 09, 84, 85.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views WHERE view_name = 'V_OC_TS_LLC';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'V_OC_TS_LLC' AND column_name = 'LOSS_HOURS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'db/85 has not been run here: V_OC_TS_LLC.LOSS_HOURS is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] V_OC_TS_LLC_ANNEXURE bills what actually moved
PROMPT ============================================================

-- Built over V_OC_TS_LLC rather than over the table, so LOSS_HOURS keeps its
-- one definition. CUSTOMER_NAME is the only thing the view does not carry.
CREATE OR REPLACE VIEW v_oc_ts_llc_annexure AS
SELECT l.llc_id,
       l.project_id,
       l.project_number,
       l.project_name,
       p.customer_name,
       l.revenue_model,
       l.period_id,
       l.period_name,
       l.absent_employee_id,
       l.absent_employee_name,
       l.absence_date,
       l.absence_type,
       -- WHAT IS BILLED: the hours oc_time_cover_billing actually moved onto a
       -- billable task. This was ABSENCE_HOURS, which is four times the figure
       -- for a 25% allocation and is not a claim any timesheet supports.
       l.cover_hours_billed AS covered_billed_hours,
       -- BOTH KEPT AS CONTEXT, because an appendix that says "2 hours billed"
       -- with nothing beside it cannot be checked. These let a reader see the
       -- whole absence, the share at stake, and the part recovered.
       l.absence_hours,
       l.loss_hours,
       l.cover_employee_id,
       l.cover_employee_name,
       l.llc_status,
       l.billed_flag,
       l.approved_by,
       l.approved_on
  FROM v_oc_ts_llc l
  JOIN oc_time_project p ON p.project_id = l.project_id
 WHERE l.llc_status = 'Approved'
   -- THE HOURS, NOT THE FLAG. BILLED_FLAG says the manager approved; this says
   -- hours moved. llc 4 has the first without the second and was on the invoice
   -- claiming 8.
   AND NVL(l.cover_hours_billed, 0) > 0;

PROMPT ============================================================
PROMPT [2/5] OC_TIME_COVER_BILLING - superseded, see db/87
PROMPT ============================================================

-- THIS SECTION DELIBERATELY DOES NOTHING NOW.
--
-- It created OC_TIME_COVER_BILLING with the manager's guard, which was right,
-- and with e.entry_type = 'Actual' throughout, which was not: a week filled in
-- by run_weekly_defaulting carries ENTRY_TYPE = 'Default', so the source lookup
-- found nothing and the procedure reported "no non-billable hours" about 8
-- hours that were sitting right there. Unblocking the guard is what made the
-- defaulted week reachable and exposed it.
--
-- Running this file after db/87 would put the narrow filter back, and it would
-- do so quietly: the symptom is a truthful-sounding refusal, not an error.
--
-- Commented out rather than deleted, same reason as db/85 [4/6] and
-- 01_time_reference.sql's UK_OC_TP_SINGLE_OPEN.
--
-- The live definition is db/87_cover_billing_on_a_defaulted_week.sql [2/4].

BEGIN
  DBMS_OUTPUT.PUT_LINE('  Left alone. The live definition is db/87 [2/4].');
END;
/


PROMPT ============================================================
PROMPT [3/5] Where the approval and the billing disagree
PROMPT ============================================================

COLUMN absent FORMAT A22
COLUMN cover  FORMAT A22
COLUMN verdict FORMAT A46
SELECT l.llc_id,
       TO_CHAR(l.absence_date,'DD-Mon') AS on_date,
       aw.employee_name AS absent,
       NVL(cw.employee_name,'(none)') AS cover,
       l.billed_flag,
       NVL(TO_CHAR(l.cover_hours_billed),'-') AS billed_hrs,
       CASE
         WHEN l.billed_flag = 'Y' AND l.cover_hours_billed IS NULL
           THEN 'flag says billed, no hours moved - off annexure'
         WHEN l.billed_flag = 'N' AND l.cover_hours_billed IS NOT NULL
           THEN 'hours moved without the flag - investigate'
         ELSE 'consistent'
       END AS verdict
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_worker aw ON aw.employee_id = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id
 WHERE l.llc_status = 'Approved'
 ORDER BY l.llc_id;

PROMPT
PROMPT BILLED_FLAG is not corrected to match. The manager did approve; the
PROMPT billing is what did not happen. Rewriting one to agree with the other
PROMPT would destroy the only evidence that they ever differed.

PROMPT ============================================================
PROMPT [4/5] Retry the rows the employee gate had refused
PROMPT ============================================================

DECLARE
  v_h   NUMBER;
  v_msg VARCHAR2(400);
  v_n   NUMBER := 0;
BEGIN
  FOR r IN (SELECT llc_id
              FROM oc_ts_leave_loss_cover
             WHERE llc_status = 'Approved'
               AND billed_flag = 'Y'
               AND cover_hours_billed IS NULL
             ORDER BY llc_id)
  LOOP
    BEGIN
      oc_time_cover_billing(r.llc_id, 'Y', 'FIX_86', v_h, v_msg);
      DBMS_OUTPUT.PUT_LINE('  llc ' || r.llc_id || ': ' || v_msg);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  llc ' || r.llc_id || ': NOT COMPLETED - '
                           || SUBSTR(SQLERRM,1,200));
    END;
  END LOOP;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Nothing outstanding.');
  END IF;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN proj FORMAT A10
SELECT l.llc_id, l.project_number AS proj, l.absence_date AS on_date,
       l.absent_employee_name AS absent,
       l.absence_hours, l.loss_hours,
       NVL(l.cover_employee_name,'(none)') AS cover,
       l.llc_status,
       NVL(TO_CHAR(l.cover_hours_billed),'-') AS billed_hrs
  FROM v_oc_ts_llc l
 ORDER BY l.project_number, l.absence_date;

PROMPT
PROMPT And what the invoice would now carry. COVERED_BILLED_HOURS is the
PROMPT recovered figure; ABSENCE_HOURS and LOSS_HOURS sit beside it so the
PROMPT appendix can be checked rather than taken on trust.

SELECT project_number, absence_date, absent_employee_name,
       absence_hours, loss_hours, covered_billed_hours
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;

PROMPT
PROMPT A row that is Approved but recovered nothing is correctly ABSENT from
PROMPT that second result. Section [3/5] listed those, with the reason.
