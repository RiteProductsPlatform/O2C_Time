--==============================================================
-- time/42_phase2b_rules.sql
-- O2C Timesheet Module — the rules phase 2b needs, and the end of 'Closed'
--
-- RUN THIS BEFORE RE-RUNNING 09_pkg_oc_time.sql. The package will call events
-- that do not exist yet, and a missing rule is -20034 at RUNTIME, not at
-- compile time -- so the package would compile perfectly and then refuse the
-- first Revoke anybody attempted.
--
-- THREE NEW EVENTS, for the procedures phase 2b rewired beyond the first five:
--   Revoke          the employee pulls back their own submission
--   RevokeDecision  the manager undoes their own approve or reject
--   AdvanceApprove  advance closure approves without the manager acting
--
-- AND 'CLOSED' IS RETIRED. Confirmed 14-Aug: "there is nothing called closed
-- -- if the cut-off date is passed it will not be editable, and if it is
-- rejected it becomes editable but will be late submission; then if the
-- delivery cut-off is crossed it goes as such, and if there is any change
-- needed it goes as adjustments."
--
-- So closure is a property of the PERIOD, not a state a week enters. Writing
-- it onto the week destroyed the approval outcome: an Approved week and an
-- 'Overridden and approved' one became indistinguishable the instant the
-- month confirmed, and "who approved this, and did they change the hours"
-- stopped being answerable. Editability already comes from the cut-offs, and
-- a post-cut-off change is an adjustment -- both already built.
--
-- Idempotent. Depends on: time/41
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] Three new events
PROMPT ============================================================

DECLARE
  PROCEDURE tr(p_event VARCHAR2, p_order NUMBER,
               p_fsub VARCHAR2, p_fapp VARCHAR2,
               p_tsub VARCHAR2, p_tapp VARCHAR2,
               p_flag VARCHAR2, p_scen VARCHAR2, p_notes VARCHAR2) IS
  BEGIN
    INSERT INTO oc_ts_transition (
      event_code, match_order, from_submission, from_approval,
      period_state, timing, require_flag,
      to_submission, to_approval, raise_flag, scenario_ref, notes, active_flag)
    VALUES (p_event, p_order, p_fsub, p_fapp, NULL, NULL, NULL,
            p_tsub, p_tapp, p_flag, p_scen, p_notes, 'Y');
  END tr;
BEGIN
  DELETE FROM oc_ts_transition
   WHERE event_code IN ('Revoke','RevokeDecision','AdvanceApprove');
  DBMS_OUTPUT.PUT_LINE(SQL%ROWCOUNT || ' existing rule(s) replaced');

  -- ── Revoke ────────────────────────────────────────────────
  -- Only while the manager has not decided. FROM_APPROVAL = 'Pending' is the
  -- entire guard: with the decision taken, there is no rule and the engine
  -- raises -20034 rather than letting an employee quietly withdraw a week the
  -- manager has already approved.
  tr('Revoke', 10, NULL, 'Pending', 'NotYetSubmitted', NULL, NULL, 'revoke',
     'The employee pulls back their own submission before it is decided. '
  || 'The LateSubmission FLAG is deliberately NOT cleared -- the week did '
  || 'land after the cut-off, and revoking it does not un-happen that.');

  -- ── RevokeDecision ────────────────────────────────────────
  -- Undoing a REJECTION has to restore the submission axis too. Rejecting set
  -- it to NotYetSubmitted because the week genuinely went back to the
  -- employee; undoing that without restoring it would leave the week reading
  -- NotYetSubmitted / Pending -- as though the employee had never submitted at
  -- all, which is the one thing everybody agrees they did do.
  tr('RevokeDecision', 10, NULL, 'Rejected', 'Submitted', 'Pending', NULL, 'revoke-reject',
     'The manager takes back a rejection. Submission is restored because the '
  || 'employee did submit. If it was LateSubmission the flag still carries '
  || 'that -- flags are never cleared -- so the lateness is not lost.');

  -- Undoing an APPROVAL leaves submission alone: it was already correct.
  tr('RevokeDecision', 20, NULL, 'Approved', NULL, 'Pending', NULL, 'revoke-approve',
     'The manager takes back an approval. Whether the week was Submitted, '
  || 'LateSubmission or Defaulted is untouched -- none of that changed.');

  tr('RevokeDecision', 30, NULL, 'ManagerDefaulted', NULL, 'Pending', NULL, 'revoke-mgrdef',
     'A manager default is undone the same way, putting the week back in '
  || 'their queue so they can decide it properly.');

  -- ── AdvanceApprove ────────────────────────────────────────
  -- Approves whatever the week is, INCLUDING Defaulted -- which is the open
  -- question in CLAUDE.md section 8.2, answered here in the only direction
  -- advance closure can mean anything: it exists precisely to close a month
  -- whose hours nobody has approved.
  --
  -- The flag is 'Adjusted', not a separate AdvanceClosure one, per the V4
  -- sheet: advance closure and reversal both surface as Adjusted.
  tr('AdvanceApprove', 10, NULL, 'Pending', NULL, 'Approved', 'Adjusted', '20 / advance',
     'Advance closure approves without the manager acting, so the record has '
  || 'to say the approval was not theirs. ADVANCE_CLOSURE_FLAG carries the '
  || 'specific reason; Adjusted is the V4 flag it maps to.');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('6 rules seeded across 3 events');
END;
/

PROMPT ============================================================
PROMPT [2/4] Retire 'Closed' from the weeks that already carry it
PROMPT ============================================================

-- A closed week was an APPROVED week; closing it overwrote that and nothing
-- else about it changed. Restoring 'Approved' loses nothing, because the
-- distinction 'Closed' was drawing -- is this month confirmed -- lives on
-- OC_TS_MONTH_CONFIRM, where a month-level fact belongs.
--
-- What it RECOVERS is the override: a week that was 'Overridden and approved'
-- before confirmation is currently indistinguishable from a plain approval.
-- OVERRIDDEN_FLAG survived, so the correct label can be rebuilt from it.
DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_ts_week
     SET week_status = oc_time_derive_week_status(
                         submission_status, approval_status, overridden_flag)
   WHERE week_status = 'Closed';
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' week(s) moved off ''Closed''');
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  none carried it -- no month has been confirmed yet');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [3/4] Consistency — every axis pair agrees with WEEK_STATUS
PROMPT ============================================================

-- The engine writes both representations together, so they cannot drift once
-- phase 2b lands. This checks the rows written BEFORE it did.
COLUMN week_status FORMAT A26
COLUMN derived     FORMAT A26
SELECT w.week_status, w.submission_status, w.approval_status,
       oc_time_derive_week_status(w.submission_status, w.approval_status,
                                  w.overridden_flag) AS derived,
       COUNT(*) AS weeks
  FROM oc_ts_week w
 GROUP BY w.week_status, w.submission_status, w.approval_status, w.overridden_flag
 HAVING w.week_status <> oc_time_derive_week_status(w.submission_status,
                            w.approval_status, w.overridden_flag)
 ORDER BY 1;

PROMPT
PROMPT That must return NO ROWS. Any row is a week whose old status and new
PROMPT axes disagree, and phase 2b would then write one of them over the other.

PROMPT ============================================================
PROMPT [4/4] The rule set, in full
PROMPT ============================================================

COLUMN event_code      FORMAT A16
COLUMN from_submission FORMAT A16
COLUMN from_approval   FORMAT A17
COLUMN to_submission   FORMAT A16
COLUMN to_approval     FORMAT A17
COLUMN raise_flag      FORMAT A16
SELECT event_code, match_order, from_submission, from_approval, timing,
       to_submission, to_approval, raise_flag
  FROM oc_ts_transition WHERE active_flag = 'Y'
 ORDER BY event_code, match_order;

PROMPT
PROMPT NEXT, and only after the check in [3] is empty:
PROMPT
PROMPT   @db/09_pkg_oc_time.sql
PROMPT
PROMPT That recompiles OC_TIME_PKG with eleven procedures routed through the
PROMPT engine and three day-level ones retired. Check SHOW ERRORS is clean and
PROMPT that the package is VALID before touching the app.
