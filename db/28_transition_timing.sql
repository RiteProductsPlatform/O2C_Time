--==============================================================
-- time/28_transition_timing.sql
-- O2C Timesheet Module — lateness is decided by the cut-off, not by history
--
-- Corrects the Submit transitions seeded by time/27.
--
-- WHAT I HAD WRONG
--   27 made a resubmission Late Submission when the week carried the
--   Defaulted flag -- reading the workbook's "resubmits rejected sheet ->
--   Late submission" rows as being about what had happened before.
--
-- WHAT WAS CONFIRMED 13-Aug-2026
--   "Once the week is rejected with a reason then it will go to employee as
--    Not Yet Submitted, but when he submits it will go to Late Submission
--    IF ITS PAST THE CUTOFF DATE."
--
--   So lateness is a property of WHEN the employee submits, not of how the
--   week got into the state it is in. A week that defaulted and is resubmitted
--   inside a still-open cut-off is an ordinary submission; a week that was
--   never defaulted and is resubmitted after Monday 17:00 is late.
--
--   That is also why the workbook's rows agree with it: those resubmissions
--   are all of PAST weeks, so the cut-off has passed in every one of them.
--   The Defaulted flag correlated with lateness without causing it, which is
--   exactly the kind of coincidence that survives a reading of the spec and
--   fails on the first week that does not fit the pattern.
--
-- WHY THIS NEEDS A NEW COLUMN
--   Timing is not derivable from the two status axes. A week sitting at
--   Not Yet Submitted says nothing about whether Monday 17:00 has passed, so
--   the engine has to be told, and the transition table has to be able to
--   match on it.
--
-- CONTRACTORS. Their 60-day window means they are nearly always past the
-- cut-off, so nearly every contractor resubmission is Late Submission. That
-- follows from this rule rather than needing one of its own -- the workbook
-- says the same thing: "that will be considered as late submission".
--
-- Idempotent. Depends on: time/27
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ── AM I IN THE SCHEMA THAT OWNS THIS MODULE? ────────────────
-- Checks for the module itself rather than for a schema NAME. The first
-- version of this guard hardcoded 'O2C_TIME' and was wrong: o2c_time in the
-- ORDS url is a URL MAPPING, and the module actually lives in O2C_DEV
-- alongside OC_MEC_PERIOD. A guard that asserts the wrong name blocks the
-- right schema, which is worse than no guard at all.
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') ||
      ', which does not own this module -- OC_TIME_WORKER is not here. ' ||
      'Connect as the schema holding the timesheet tables and re-run.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] OC_TS_TRANSITION gains TIMING
PROMPT ============================================================

DECLARE
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_transition ADD (
    TIMING VARCHAR2(14 CHAR))~';
  DBMS_OUTPUT.PUT_LINE('TIMING added');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN DBMS_OUTPUT.PUT_LINE('TIMING exists, skipped');
  ELSE RAISE; END IF;
END;
/

DECLARE
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_transition ADD CONSTRAINT chk_oc_ttr_timing
    CHECK (TIMING IN ('WithinCutoff','PastCutoff'))~';
  DBMS_OUTPUT.PUT_LINE('chk_oc_ttr_timing added');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -2264 THEN DBMS_OUTPUT.PUT_LINE('chk_oc_ttr_timing exists, skipped');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/3] Reseat the Submit rules on timing
PROMPT ============================================================

DECLARE
  PROCEDURE tr(ev VARCHAR2, ord NUMBER, fsub VARCHAR2, fapp VARCHAR2,
               pst VARCHAR2, tim VARCHAR2, rq VARCHAR2,
               tsub VARCHAR2, tapp VARCHAR2, rf VARCHAR2,
               ref VARCHAR2, nt VARCHAR2 DEFAULT NULL) IS
  BEGIN
    MERGE INTO oc_ts_transition t
    USING (SELECT ev AS e, ord AS o FROM dual) s
       ON (t.event_code = s.e AND t.match_order = s.o)
     WHEN MATCHED THEN UPDATE
          SET from_submission=fsub, from_approval=fapp, period_state=pst,
              timing=tim, require_flag=rq, to_submission=tsub,
              to_approval=tapp, raise_flag=rf, scenario_ref=ref, notes=nt
     WHEN NOT MATCHED THEN
          INSERT (event_code, match_order, from_submission, from_approval,
                  period_state, timing, require_flag, to_submission,
                  to_approval, raise_flag, scenario_ref, notes)
          VALUES (ev, ord, fsub, fapp, pst, tim, rq, tsub, tapp, rf, ref, nt);
  END;
BEGIN
  -- REQUIRE_FLAG is cleared off the Submit rules. It stays on the table for
  -- rules that genuinely need to look at history; lateness is not one.
  tr('Submit', 10, NULL, NULL, NULL, 'PastCutoff', NULL,
     'LateSubmission', 'Pending', 'LateSubmission', '12 / 13 / 2.2 / 2.3 / 2.4',
     'Past the weekly cut-off, whatever the week was before. Contractors '
     || 'submitting inside their 60 days land here almost by definition.');

  tr('Submit', 20, NULL, NULL, NULL, 'WithinCutoff', NULL,
     'Submitted', 'Pending', NULL, '4 / 7',
     'Inside the cut-off. A week that had defaulted and is corrected in time '
     || 'is an ordinary submission -- the Defaulted flag stays as the record '
     || 'of what happened, but it does not make this submission late.');

  -- The old rule 30 is now unreachable: 10 and 20 between them cover every
  -- case, because a submission is either inside the cut-off or past it.
  -- Deactivated rather than deleted, so the change is visible in the table.
  UPDATE oc_ts_transition
     SET active_flag = 'N',
         notes = 'Superseded 13-Aug by the timing rules above. Kept for the record.'
   WHERE event_code = 'Submit' AND match_order = 30;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Submit rules reseated on TIMING');
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

COLUMN event_code FORMAT A14
COLUMN timing     FORMAT A14
COLUMN to_s       FORMAT A16
COLUMN to_a       FORMAT A12
COLUMN rf         FORMAT A16
COLUMN act        FORMAT A3
SELECT event_code, match_order, timing, require_flag,
       to_submission AS to_s, to_approval AS to_a, raise_flag AS rf,
       active_flag AS act
  FROM oc_ts_transition
 WHERE event_code = 'Submit'
 ORDER BY match_order;

PROMPT
PROMPT Two live rules, split on TIMING and nothing else. The engine passes
PROMPT 'PastCutoff' or 'WithinCutoff' by comparing the submission moment with
PROMPT the week's weekly cut-off; everything about lateness follows from that
PROMPT one comparison rather than from the week's history.
PROMPT
PROMPT REJECTION IS UNCHANGED and still sends the week back to Not Yet
PROMPT Submitted. That is the confirmed behaviour: the employee sees an
PROMPT unsubmitted week, and whether their next submission is late is decided
PROMPT when they make it -- not when the manager rejected.
