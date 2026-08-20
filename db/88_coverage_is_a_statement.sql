--==============================================================
-- time/88_coverage_is_a_statement.sql
-- O2C Timesheet Module — leave-loss coverage moves no hours, anywhere
--
-- Decided 20-Aug after reading BRD 4.2.1 and the four transcripts back. Three
-- statements from the functional owner, and the first two retract a premise the
-- module has been built on since db/84:
--
--   "even though an unbilled employee covers a billable employee, the hours of
--    the unbilled employee stays as unbilled only -- i was wrong -- and the
--    leave hours already sit in leave columns. As this coverage will just go as
--    a statement in annexure"
--
--   "those hours need to go as billed for those employee - this is wrong"
--
--   "In the Annexure we will just give a line saying 'Sam' was absent on these
--    days and he has been replaced by this person on one day and some other or
--    the same person on another day. We will not give the number of hours. The
--    summary as it is already will have billed hours, unbilled hours and leave
--    as columns"
--
-- So COVERAGE IS A STATEMENT OF FACT ABOUT PEOPLE AND DATES. It records who
-- covered whom, and when. It moves no hours, changes no billability, and puts
-- no number on the invoice. The hours were never missing: the absentee's leave
-- is already in the leave column and the cover's hours are already unbilled.
--
-- WHAT THIS DELETES, AND IT IS MOST OF THE LAST FOUR SCRIPTS. db/84 moved hours
-- onto a billable task on the COVER's timesheet. Everything that fought us
-- since was a consequence of that one wrong premise and none of it was a
-- leave-loss problem:
--
--   db/85  the employee's assert_editable gate refusing a manager
--   db/86  entry_type = 'Actual' blind to a defaulted week
--   db/87  promotion, the UK_OC_TSE_CELL collision, the same-task dead end
--
-- All of it goes. A rule that touches no entries cannot hit any of them.
--
-- ── LOSS_HOURS STAYS, AND GETS SHARPER ───────────────────────────────────
--
-- Confirmed as correct, and the reason given is a better rule than the BRD's:
--
--   "the standard hours for that employee may be 10 hrs or 9.5 hours per day
--    and mostly in FCP they will be 100% allocated but their standard working
--    hours might differ based on shift, so here if we do it based on the
--    allocation it will be proper"
--
-- BRD 4.2.1 says the annexure figure is "the absence hours", and the absence
-- loader derives those from the worker's STD_HOURS_PER_DAY -- 8. A person on a
-- 9.5-hour shift therefore has a full day of leave recorded as 8, and the
-- previous LEAST(..., absence_hours) cap clipped their loss back to 8 as well.
-- Both understate.
--
-- The fix takes the FRACTION OF A DAY from the absence and applies it to the
-- SHIFT standard:
--
--   day_fraction = LEAST(1, absence_hours / worker.std_hours_per_day)
--   shift_std    = the standard_hours the timesheet used for that date,
--                  falling back to the worker's own standard
--   LOSS_HOURS   = ROUND(alloc_pct/100 * day_fraction * shift_std * 4) / 4
--
--   100%, 9.5h shift, full day   9.50   (was 8.00)
--    25%, 8h shift,   full day   2.00   (unchanged)
--   100%, 9.5h shift, half day   4.75   -- and that answers RA-013
--
-- A zero shift standard is a weekend or holiday and yields zero, which is
-- right: there was no capacity to lose. LOSS_HOURS is now SCREEN ONLY -- the
-- manager sees the size of what they are covering. It reaches no invoice.
--
-- ── AND A NEW RULE, WHICH IS NOT ABOUT COVERAGE AT ALL ───────────────────
--
--   "Shift hrs is the standard hrs and we also need to put a rule that a person
--    cannot enter hours more than the standard hrs for his which is his shift
--    hrs"
--
-- Added to validate_day as -20029, beside its sibling -20028 (each day must
-- EQUAL its standard before the week can be submitted). Save-time refuses more
-- than the standard; submit-time still requires exactly it. Only where a
-- standard exists: a zero-standard day is a weekend, where there is nothing to
-- exceed, and capping at zero would forbid genuine weekend work -- the same
-- guard -20028 already uses, so the two cannot disagree.
--
-- It lands in db/09, not here, because validate_day lives in the package and a
-- second copy would drift.
--
-- Idempotent. Supersedes db/86 [1/5] and db/87 [2/4].
-- Depends on: time/05, 07, 08, 09, 84, 85.
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
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/7] Nothing was ever moved, so nothing needs unwinding
PROMPT ============================================================

-- Every attempt to move hours refused, for one reason or another, so no
-- OC_TS_ENTRY row was rewritten by db/84..87. Verified rather than assumed:
-- if this reports anything, those days must be put back BY HAND before the
-- column is retired below, because after that nothing records what moved.
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n
    FROM oc_ts_leave_loss_cover WHERE cover_hours_billed IS NOT NULL;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Clean: no coverage ever moved hours.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  *** ' || v_n || ' row(s) DID move hours. '
      || 'Reverse them before going further:');
    FOR r IN (SELECT llc_id, cover_employee_id,
                     TO_CHAR(absence_date,'DD-Mon-YY') AS d, cover_hours_billed
                FROM oc_ts_leave_loss_cover
               WHERE cover_hours_billed IS NOT NULL ORDER BY llc_id)
    LOOP
      DBMS_OUTPUT.PUT_LINE('      llc ' || r.llc_id || '  ' || r.cover_employee_id
        || '  ' || r.d || '  ' || r.cover_hours_billed || 'h');
    END LOOP;
  END IF;
END;
/

COMMENT ON COLUMN oc_ts_leave_loss_cover.cover_hours_billed IS
  'RETRACTED 20-Aug-2026. Held the hours db/84 moved from the cover''s non-billable line to a billable one. Coverage moves no hours: the absentee''s leave is already in the leave column and the cover''s hours stay unbilled. Kept, unread and unwritten, because a dropped column loses the record that anything was ever moved. Do not read it.';

PROMPT ============================================================
PROMPT [2/7] V_OC_TS_LLC — LOSS_HOURS by allocation and SHIFT
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_llc AS
SELECT l.llc_id,
       l.project_id,
       p.project_number,
       p.project_name,
       p.revenue_model,
       p.leave_loss_flag,
       p.project_manager_id,
       l.period_id,
       pe.period_name,
       l.absent_employee_id,                                -- FLD-060
       aw.employee_name AS absent_employee_name,            -- FLD-061
       TO_CHAR(l.absence_date,'YYYY-MM-DD') AS absence_date, -- FLD-062
       TO_CHAR(l.absence_date,'DY')         AS absence_day,
       l.absence_type,
       l.absence_hours,                                     -- FLD-063
       -- THE CAPACITY THIS PROJECT LOST, screen only.
       --
       -- Allocation share of the person's SHIFT day, scaled by how much of the
       -- day the absence actually took. The shift is the part BRD 4.2.1 cannot
       -- express: it says "the absence hours", and those come from the worker's
       -- STD_HOURS_PER_DAY, so a 9.5-hour-shift person's full day is recorded
       -- as 8 and read as 8.
       --
       --   day_fraction  absence / the worker's own standard day, capped at 1
       --   shift_std     what the timesheet used for that date, which a work
       --                 pattern can vary; zero on a weekend, and zero loss is
       --                 the right answer there
       --
       -- Rounded to the quarter CHK_OC_TSE_QUARTER requires.
       ROUND(
         NVL((SELECT MAX(al.alloc_pct)
                FROM oc_time_allocation al
               WHERE al.employee_id = l.absent_employee_id
                 AND al.project_id  = l.project_id
                 AND al.status      = 'Active'
                 AND l.absence_date BETWEEN al.start_date
                                        AND NVL(al.end_date, l.absence_date)), 0)
         / 100
         * LEAST(1, NVL(l.absence_hours,0)
                    / NULLIF(NVL(aw.std_hours_per_day, 8), 0))
         * NVL((SELECT MAX(e.standard_hours)
                  FROM oc_ts_entry e
                  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
                 WHERE w.employee_id = l.absent_employee_id
                   AND e.entry_date  = l.absence_date),
               aw.std_hours_per_day)
         * 4) / 4                             AS loss_hours,
       l.cover_employee_id,                                 -- FLD-064
       cw.employee_name AS cover_employee_name,
       l.llc_status,                                        -- FLD-065
       l.billed_flag,
       l.assigned_by,
       TO_CHAR(l.assigned_on,'YYYY-MM-DD HH24:MI') AS assigned_on,
       l.approved_by,
       TO_CHAR(l.approved_on,'YYYY-MM-DD HH24:MI') AS approved_on,
       l.remarks
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_project p  ON p.project_id   = l.project_id
                         AND p.revenue_model   = 'FCP'
                         AND p.leave_loss_flag = 'Y'
  JOIN oc_time_period  pe ON pe.period_id    = l.period_id
  JOIN oc_time_worker  aw ON aw.employee_id  = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id;

PROMPT ============================================================
PROMPT [3/7] V_OC_TS_LLC_ANNEXURE — who covered whom, and no hours
PROMPT ============================================================

-- REP-002, at the grain the metadata states: absent employee, date, cover.
-- WITHOUT AN HOURS COLUMN. It carried COVERED_BILLED_HOURS, first from
-- ABSENCE_HOURS (four times the loss for a 25% allocation) and then from what
-- db/84 moved. Neither belongs: the invoice's hours come from the monthly
-- summary, which already has billed, unbilled and leave columns and is not
-- touched by coverage.
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
       l.absence_day,
       l.absence_type,
       l.cover_employee_id,
       l.cover_employee_name,
       l.llc_status,
       l.approved_by,
       l.approved_on
  FROM v_oc_ts_llc l
  JOIN oc_time_project p ON p.project_id = l.project_id
 WHERE l.llc_status = 'Approved'
   AND l.cover_employee_id IS NOT NULL;

PROMPT ============================================================
PROMPT [4/7] V_OC_TS_LLC_ANNEXURE_NOTE - withdrawn, see db/89
PROMPT ============================================================

-- THIS SECTION DELIBERATELY DOES NOTHING NOW, and it was wrong the same day it
-- was written.
--
-- It composed the printed sentence -- "Sam Joshuva S was absent on 07-Aug
-- (covered by Kishore Krovvidi)." Told immediately after: "we will just assign
-- and approve a person who is going to cover it from time module - annexure
-- will be done by the down stream system, not in time module".
--
-- The wording, the layout and the language are the downstream system's to
-- choose. We supply the facts in V_OC_TS_LLC_ANNEXURE and stop there. db/89
-- drops the view.

BEGIN
  DBMS_OUTPUT.PUT_LINE('  Withdrawn. db/89 drops this view.');
END;
/

PROMPT ============================================================
PROMPT [5/7] Approving coverage records a fact, and moves nothing
PROMPT ============================================================

-- RETIRED, not deleted, and it raises rather than returning quietly. The same
-- treatment approve_day and reject_day got when day-level approval was retired
-- (-20027): the procedure stays so a stale caller gets a sentence instead of
-- PLS-00201, and the sentence says what replaced it.
CREATE OR REPLACE PROCEDURE oc_time_cover_billing(
  p_llc_id  IN  NUMBER,
  p_apply   IN  VARCHAR2,
  p_actor   IN  VARCHAR2 DEFAULT 'VBCS_USER',
  o_hours   OUT NUMBER,
  o_message OUT VARCHAR2)
IS
BEGIN
  o_hours := 0;
  o_message := NULL;
  RAISE_APPLICATION_ERROR(-20033,
    'Leave-loss coverage no longer moves any hours. The covering colleague''s '
    || 'time stays unbilled and the absentee''s leave stays in the leave '
    || 'column; the coverage is a statement in the invoice annexure. Approve '
    || 'it with oc_time_approve_cover.');
END oc_time_cover_billing;
/
SHOW ERRORS

CREATE OR REPLACE PROCEDURE oc_time_approve_cover(
  p_llc_id       IN NUMBER,
  p_actor_emp_id IN VARCHAR2,
  p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
IS
  v_project   NUMBER;
  v_period    NUMBER;
  v_confirmed NUMBER;
BEGIN
  SELECT project_id, period_id INTO v_project, v_period
    FROM oc_ts_leave_loss_cover WHERE llc_id = p_llc_id;

  -- THE ONLY GUARD LEFT, and it is the one PROC-006 actually states: "before
  -- finance cut-off". Confirming the month is when the figures are handed off,
  -- and the annexure goes with them.
  --
  -- The week-approved and period-open guards db/86 added are gone with the
  -- premise that needed them: they protected the COVER's timesheet, and nothing
  -- touches it now. A defaulted or locked week is no longer any obstacle to
  -- recording who covered somebody's leave, which is what it never should have
  -- been.
  SELECT COUNT(*) INTO v_confirmed FROM oc_ts_month_confirm
   WHERE project_id = v_project AND period_id = v_period;

  IF v_confirmed > 0 THEN
    RAISE_APPLICATION_ERROR(-20007,
      'This month has already been confirmed for this project, so its invoice '
      || 'annexure is settled. Coverage has to be recorded before the finance '
      || 'cut-off.');
  END IF;

  oc_time_pkg.approve_cover(p_llc_id, p_actor_emp_id, p_actor);
END oc_time_approve_cover;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [6/7] Absences with nobody covering them
PROMPT ============================================================

-- "there should always be a eligible person to cover in FCP and this is
-- mandatory" -- 20-Aug, which closes the first half of RA-013. An uncovered
-- absence on an FCP+LL project is therefore an exception, not a resting state.
--
-- REPORTED, NOT ENFORCED. The natural enforcement point is confirm_month,
-- beside RULE-020's all-approved gate, and adding a second thing that can block
-- a month's confirmation is a decision for the functional owner rather than an
-- inference from one sentence.
COLUMN absent FORMAT A24
COLUMN proj   FORMAT A10
SELECT l.project_number AS proj, l.period_name,
       l.absent_employee_name AS absent,
       COUNT(*)                       AS uncovered_days,
       LISTAGG(TO_CHAR(TO_DATE(l.absence_date,'YYYY-MM-DD'),'DD-Mon'), ', ')
         WITHIN GROUP (ORDER BY l.absence_date) AS dates
  FROM v_oc_ts_llc l
 WHERE l.cover_employee_id IS NULL
 GROUP BY l.project_number, l.period_name, l.absent_employee_name
 ORDER BY l.project_number, l.absent_employee_name;

PROMPT
PROMPT Every row above is an FCP absence nobody has been assigned to cover.

PROMPT ============================================================
PROMPT [7/7] Verification
PROMPT ============================================================

COLUMN cover FORMAT A24
SELECT l.llc_id, l.project_number AS proj, l.absence_date AS on_date,
       l.absent_employee_name AS absent,
       l.absence_hours, l.loss_hours,
       NVL(l.cover_employee_name,'(none)') AS cover,
       l.llc_status
  FROM v_oc_ts_llc l
 ORDER BY l.project_number, l.absence_date;

PROMPT
PROMPT LOSS_HOURS is allocation x shift x day-fraction, and is shown on
PROMPT PAGE-006 only. It reaches no invoice and no accrual.

PROMPT
PROMPT The annexure, at REP-002's grain and with no hours column.

COLUMN line FORMAT A96
SELECT project_number, absent_employee_name, absence_date, cover_employee_name
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;

PROMPT
PROMPT NEXT: run db/09_pkg_oc_time.sql. validate_day gains -20029 there, the
PROMPT rule that a day cannot exceed the person's shift hours.
