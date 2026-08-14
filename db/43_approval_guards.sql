--==============================================================
-- time/43_approval_guards.sql
-- O2C Timesheet Module — a manager may only decide what reached them
--
-- Approve, ApproveOverride and Reject were seeded with every FROM column NULL,
-- meaning "match from any state". Measured on a real August week:
--
--   Approve a week nobody sent   ALLOWED -> NotYetSubmitted / Approved
--   Reject  a week nobody sent   ALLOWED -> NotYetSubmitted / Rejected
--
-- A week both never submitted and approved. Nothing rejects it, nothing
-- reports it, and it flows to accrual as approved hours nobody entered.
--
-- THE RULE, confirmed 14-Aug: a manager can approve or reject only when a week
-- is SUBMITTED or SYSTEM DEFAULTED.
--
-- This is the same fault as the DeliveryCutoff one fixed in 41, from the
-- opposite side. There the engine blamed a manager for not approving a week
-- nobody sent; here it let them approve it. Both came from the same habit --
-- leaving FROM columns NULL because "the screen would never do that" -- and
-- the screen is not the control. Section 6 of CLAUDE.md: rules live in the
-- database, and a caller hitting ORDS directly must meet the identical
-- refusal. The ORDS endpoints are directly callable and have been used that
-- way to find faults, so this is not hypothetical.
--
-- Idempotent. Depends on: time/42
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
PROMPT [1/3] Guard the manager's decisions
PROMPT ============================================================

DECLARE
  PROCEDURE tr(p_event VARCHAR2, p_order NUMBER, p_fsub VARCHAR2,
               p_tsub VARCHAR2, p_tapp VARCHAR2, p_flag VARCHAR2,
               p_scen VARCHAR2, p_notes VARCHAR2) IS
  BEGIN
    INSERT INTO oc_ts_transition (
      event_code, match_order, from_submission, from_approval,
      period_state, timing, require_flag,
      to_submission, to_approval, raise_flag, scenario_ref, notes, active_flag)
    -- FROM_APPROVAL = 'Pending' on every one of these. A decision is taken
    -- once; changing it means revoking it first, which is what
    -- RevokeDecision exists for. Overriding an ALREADY-approved week for up
    -- to three months is a separate capability, deliberately left to a later
    -- phase -- it needs its own event, not a relaxed guard here.
    VALUES (p_event, p_order, p_fsub, 'Pending', NULL, NULL, NULL,
            p_tsub, p_tapp, p_flag, p_scen, p_notes, 'Y');
  END tr;
BEGIN
  DELETE FROM oc_ts_transition
   WHERE event_code IN ('Approve','ApproveOverride','Reject','Revoke');
  DBMS_OUTPUT.PUT_LINE(SQL%ROWCOUNT || ' unguarded rule(s) removed');

  -- ── Approve ───────────────────────────────────────────────
  -- Three submitted states, and no fourth. Submitted and LateSubmission are
  -- the employee's own act; Defaulted is the weekly job submitting on their
  -- behalf, which still put the week in front of the manager. NotYetSubmitted
  -- is the one that never reached them.
  tr('Approve', 10, 'Submitted',      NULL, 'Approved', NULL, '16',
     'The ordinary approval.');
  tr('Approve', 20, 'LateSubmission', NULL, 'Approved', NULL, '16',
     'Late, but submitted. The LateSubmission flag stays as the record; it '
  || 'does not stop the manager approving the hours.');
  tr('Approve', 30, 'Defaulted',      NULL, 'Approved', NULL, '16',
     'The weekly job submitted on the employee''s behalf and the manager is '
  || 'approving what it produced. SUBMISSION stays Defaulted -- approving '
  || 'the hours does not turn a defaulted week into one the employee sent. '
  || 'That combination is scenario 16, and the pair of columns exists so it '
  || 'can be held at all.');

  -- ── ApproveOverride ───────────────────────────────────────
  tr('ApproveOverride', 10, 'Submitted',      NULL, 'Approved', 'Overridden', '18',
     'The manager corrected the hours and approved in one step.');
  tr('ApproveOverride', 20, 'LateSubmission', NULL, 'Approved', 'Overridden', '18',
     'Same, on a late submission.');
  tr('ApproveOverride', 30, 'Defaulted',      NULL, 'Approved', 'Overridden', '18',
     'Correcting the hours the defaulting job put in is the commonest '
  || 'override there is -- the defaults are a placeholder, not a claim.');

  -- ── Reject ────────────────────────────────────────────────
  -- Rejection resets SUBMISSION to NotYetSubmitted: the week genuinely goes
  -- back to the employee to send again, and if the cut-off has passed by then
  -- their next submission lands as LateSubmission. That chain is why the
  -- submission axis has to move rather than the week just being 'Rejected'.
  tr('Reject', 10, 'Submitted',      'NotYetSubmitted', 'Rejected', NULL, '19',
     'Sent back with a reason. The week becomes editable again.');
  tr('Reject', 20, 'LateSubmission', 'NotYetSubmitted', 'Rejected', NULL, '19',
     'Sent back. The LateSubmission FLAG is not cleared -- flags are never '
  || 'cleared -- so the original lateness survives the round trip.');
  tr('Reject', 30, 'Defaulted',      'NotYetSubmitted', 'Rejected', NULL, '19',
     'A manager may reject what the defaulting job produced, which is the '
  || 'employee''s route back into a week that was auto-submitted for them.');

  -- ── Revoke ────────────────────────────────────────────────
  -- The EMPLOYEE pulling back their own submission, so it is narrower than
  -- the manager's actions: only what the employee themselves sent.
  --
  -- Defaulted is excluded ON PURPOSE, and it is the one that would have been
  -- easy to include for symmetry. A defaulted week is LOCKED -- only a manager
  -- can touch it (RULE-006) -- so letting the employee revoke it would hand
  -- back a week the cut-off deliberately took away, and with it the salary
  -- hold that default carries.
  tr('Revoke', 10, 'Submitted',      'NotYetSubmitted', NULL, NULL, 'revoke',
     'The employee pulls back their own submission before it is decided.');
  tr('Revoke', 20, 'LateSubmission', 'NotYetSubmitted', NULL, NULL, 'revoke',
     'Same for a late one. The flag stays: revoking does not un-happen the '
  || 'lateness.');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('11 guarded rules seeded across 4 events');
END;
/

PROMPT ============================================================
PROMPT [2/3] Prove the hole is closed
PROMPT ============================================================

DECLARE
  s VARCHAR2(30); a VARCHAR2(30); f VARCHAR2(30);
  v_new NUMBER; v_sub NUMBER;

  PROCEDURE try(p_lbl VARCHAR2, p_ev VARCHAR2, p_wk NUMBER, p_expect VARCHAR2) IS
  BEGIN
    IF p_wk IS NULL THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_lbl, 38) || 'no week available'); RETURN;
    END IF;
    oc_time_apply_event(p_wk, p_ev, 'TEST', s, a, f);
    DBMS_OUTPUT.PUT_LINE(RPAD(p_lbl, 38) || 'ALLOWED -> ' || s || ' / ' || a
      || CASE WHEN p_expect = 'refuse' THEN '   *** STILL OPEN ***' END);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_lbl, 38) || 'refused'
      || CASE WHEN p_expect = 'allow' THEN '   *** WRONGLY BLOCKED ***' END);
  END try;

BEGIN
  SELECT MIN(w.ts_week_id) INTO v_new FROM oc_ts_week w
    JOIN oc_time_period p ON p.period_id = w.period_id
   WHERE p.period_name = 'AUG-2026' AND w.submission_status = 'NotYetSubmitted';

  -- must all refuse
  try('Approve a week nobody sent',  'Approve',         v_new, 'refuse'); ROLLBACK;
  try('Override a week nobody sent', 'ApproveOverride', v_new, 'refuse'); ROLLBACK;
  try('Reject a week nobody sent',   'Reject',          v_new, 'refuse'); ROLLBACK;
  try('Revoke a week nobody sent',   'Revoke',          v_new, 'refuse'); ROLLBACK;

  -- and the same week, once submitted, must allow all of them
  oc_time_apply_event(v_new, 'Submit', 'TEST', s, a, f);
  v_sub := v_new;
  try('Approve it once submitted',   'Approve',         v_sub, 'allow');
  ROLLBACK;

  oc_time_apply_event(v_new, 'Submit', 'TEST', s, a, f);
  try('Reject it once submitted',    'Reject',          v_sub, 'allow');
  ROLLBACK;

  oc_time_apply_event(v_new, 'Submit', 'TEST', s, a, f);
  try('Revoke it once submitted',    'Revoke',          v_sub, 'allow');
  ROLLBACK;
END;
/

PROMPT
PROMPT Four refusals then three allowals. Any line marked STILL OPEN or
PROMPT WRONGLY BLOCKED is a rule that needs another look before the UI is
PROMPT exercised.

PROMPT ============================================================
PROMPT [3/3] Every rule, with the guards visible this time
PROMPT ============================================================

COLUMN event_code      FORMAT A16
COLUMN from_submission FORMAT A16
COLUMN from_approval   FORMAT A17
COLUMN to_submission   FORMAT A16
COLUMN to_approval     FORMAT A17
COLUMN raise_flag      FORMAT A16
COLUMN pstate          FORMAT A7
COLUMN timing          FORMAT A13
SELECT event_code, match_order, from_submission, from_approval,
       period_state AS pstate, timing,
       to_submission, to_approval, raise_flag
  FROM oc_ts_transition WHERE active_flag = 'Y'
 ORDER BY event_code, match_order;

PROMPT
PROMPT AdvanceApprove keeps its open guard deliberately: it matches from any
PROMPT submission state including NotYetSubmitted, because closing a month
PROMPT nobody has submitted is exactly the situation it exists for. It is
PROMPT reachable only from the admin's advance-closure action, never from a
PROMPT manager's queue.
