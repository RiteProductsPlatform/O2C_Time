--==============================================================
-- time/37_status_engine_v4.sql
-- O2C Timesheet Module — status & flag model V4, phase 2: the engine
--
-- Phase 1 (time/27, time/28) built the vocabulary, the flag tables and the
-- transition rules. Nothing writes to any of them: submit_week, approve_week,
-- reject_week and the two cut-off jobs still set the old WEEK_STATUS and the
-- six boolean columns, and OC_TS_WEEK_FLAG holds only what the backfill put
-- there.
--
-- This is the piece that makes them real. ONE procedure decides every status
-- change, by reading OC_TS_TRANSITION rather than by containing the rules.
--
--   oc_time_apply_event(week, event, actor)
--     -> work out the timing
--     -> find the matching transition row
--     -> write both axes on the week
--     -> cascade both to the week's days
--     -> raise the flag, with its timestamp
--
-- WHY THE RULES ARE NOT IN HERE
--   The mail carrying the V4 workbook said it will change again as
--   integrations are built. Sixteen branches of IF/ELSE would have to be
--   re-read, re-tested and re-reviewed every revision. Rows do not. Adding a
--   rule in V5 is an INSERT.
--
-- THE WEEK ACTS, THE DAY RECORDS
--   Confirmed 13-Aug from the discussion: "It's always weekly. Submission is
--   weekly, so approval also. So even if one day there is a wrong thing, we
--   will reject the entire week." So the week's status is SET by the action
--   and the days RECEIVE it -- top-down, never rolled up. That is why there is
--   no precedence table here and why a week can never disagree with its own
--   days: one statement writes them all.
--
--   Days still carry the rejection reason per day, which is display detail
--   rather than state, and is written by the caller rather than by this.
--
-- TIMING IS COMPUTED, NOT PASSED
--   Lateness depends on whether the weekly cut-off has passed (confirmed
--   13-Aug), and the week knows its own cut-off: NEXT_DAY(week_end,
--   TS_CUTOFF_DAY) at TS_CUTOFF_TIME. Asking the caller for it would let two
--   callers disagree about the same week.
--
-- Idempotent. Depends on: time/27, time/28
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
PROMPT [1/5] OC_TIME_WEEK_TIMING — has the weekly cut-off passed?
PROMPT ============================================================

-- The single comparison everything about lateness rests on. A week that has
-- not started still returns WithinCutoff, which is right: a submission cannot
-- be late before its deadline exists.
CREATE OR REPLACE FUNCTION oc_time_week_timing(p_ts_week_id IN NUMBER)
RETURN VARCHAR2
IS
  v_end   DATE;
  v_day   VARCHAR2(10);
  v_time  VARCHAR2(5);
  v_due   DATE;
BEGIN
  SELECT w.week_end, p.ts_cutoff_day, p.ts_cutoff_time
    INTO v_end, v_day, v_time
    FROM oc_ts_week w
    JOIN oc_time_period p ON p.period_id = w.period_id
   WHERE w.ts_week_id = p_ts_week_id;

  -- NEXT_DAY gives the first named day STRICTLY AFTER the date, which is what
  -- is wanted: a week ending Sunday is due the following Monday, not the
  -- Monday inside it. Reading the day name from configuration rather than
  -- assuming Monday means changing the cut-off is a config row, not a patch.
  v_due := NEXT_DAY(v_end, NVL(v_day, 'MONDAY'))
         + NVL(TO_NUMBER(SUBSTR(v_time, 1, 2)), 17) / 24
         + NVL(TO_NUMBER(SUBSTR(v_time, 4, 2)),  0) / 1440;

  RETURN CASE WHEN SYSDATE > v_due THEN 'PastCutoff' ELSE 'WithinCutoff' END;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RETURN 'WithinCutoff';
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/5] Flag helpers — a flag is a row with a timestamp
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_raise_week_flag(
  p_ts_week_id IN NUMBER,
  p_flag       IN VARCHAR2,
  p_actor      IN VARCHAR2 DEFAULT 'SYSTEM',
  p_notes      IN VARCHAR2 DEFAULT NULL)
IS
BEGIN
  IF p_flag IS NULL THEN RETURN; END IF;

  -- Raising a flag that is already raised must not move its timestamp. WHEN
  -- a week first defaulted is the fact worth keeping; re-running a job would
  -- otherwise quietly rewrite history to today.
  MERGE INTO oc_ts_week_flag t
  USING (SELECT p_ts_week_id AS w, p_flag AS f FROM dual) s
     ON (t.ts_week_id = s.w AND t.flag_code = s.f)
   WHEN MATCHED THEN UPDATE SET cleared_on = NULL, cleared_by = NULL
   WHEN NOT MATCHED THEN
     INSERT (ts_week_id, flag_code, set_on, set_by, notes)
     VALUES (p_ts_week_id, p_flag, SYSTIMESTAMP, p_actor, p_notes);

  -- The revision-2 booleans stay in step for as long as anything reads them.
  -- Phase 3 removes them; until then a screen reading either gets the truth.
  CASE p_flag
    WHEN 'Defaulted' THEN
      UPDATE oc_ts_week SET defaulted_flag = 'Y' WHERE ts_week_id = p_ts_week_id;
    WHEN 'LateSubmission' THEN
      UPDATE oc_ts_week SET late_submission_flag = 'Y' WHERE ts_week_id = p_ts_week_id;
    WHEN 'Overridden' THEN
      UPDATE oc_ts_week SET overridden_flag = 'Y' WHERE ts_week_id = p_ts_week_id;
    WHEN 'Adjusted' THEN
      UPDATE oc_ts_week SET has_adjustment_flag = 'Y' WHERE ts_week_id = p_ts_week_id;
    ELSE NULL;   -- ManagerDefaulted has no revision-2 column; it was DEFAULTED_BY
  END CASE;
END;
/
SHOW ERRORS

CREATE OR REPLACE PROCEDURE oc_time_clear_week_flag(
  p_ts_week_id IN NUMBER,
  p_flag       IN VARCHAR2,
  p_actor      IN VARCHAR2 DEFAULT 'SYSTEM')
IS
BEGIN
  -- Cleared, not deleted. The row stays with SET_ON and CLEARED_ON both
  -- populated, so "this week was defaulted and then it was not" is still
  -- answerable. Deleting would leave no trace that it ever happened.
  UPDATE oc_ts_week_flag
     SET cleared_on = SYSTIMESTAMP, cleared_by = p_actor
   WHERE ts_week_id = p_ts_week_id AND flag_code = p_flag
     AND cleared_on IS NULL;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/5] OC_TIME_APPLY_EVENT — the engine
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_apply_event(
  p_ts_week_id IN  NUMBER,
  p_event      IN  VARCHAR2,
  p_actor      IN  VARCHAR2 DEFAULT 'SYSTEM',
  o_submission OUT VARCHAR2,
  o_approval   OUT VARCHAR2,
  o_flag       OUT VARCHAR2)
IS
  v_sub    VARCHAR2(30);
  v_app    VARCHAR2(30);
  v_pstate VARCHAR2(10);
  v_timing VARCHAR2(14);
  v_found  BOOLEAN := FALSE;
BEGIN
  SELECT w.submission_status, w.approval_status,
         CASE WHEN p.status = 'Open' THEN 'Open' ELSE 'Closed' END
    INTO v_sub, v_app, v_pstate
    FROM oc_ts_week w
    JOIN oc_time_period p ON p.period_id = w.period_id
   WHERE w.ts_week_id = p_ts_week_id;

  v_timing := oc_time_week_timing(p_ts_week_id);

  -- The first rule that matches, by MATCH_ORDER. NULL on a FROM column means
  -- "any", so a specific rule sits above the catch-all and wins.
  FOR r IN (
    SELECT to_submission, to_approval, raise_flag, scenario_ref, match_order
      FROM oc_ts_transition
     WHERE active_flag = 'Y'
       AND event_code  = p_event
       AND (from_submission IS NULL OR from_submission = v_sub)
       AND (from_approval   IS NULL OR from_approval   = v_app)
       AND (period_state    IS NULL OR period_state    = v_pstate)
       AND (timing          IS NULL OR timing          = v_timing)
       AND (require_flag    IS NULL OR EXISTS (
              SELECT 1 FROM oc_ts_week_flag f
               WHERE f.ts_week_id = p_ts_week_id
                 AND f.flag_code  = require_flag
                 AND f.cleared_on IS NULL))
     ORDER BY match_order
  ) LOOP
    v_found := TRUE;

    -- NULL on a TO column means "leave this axis alone". That is how Approve
    -- keeps a Defaulted week Defaulted while approving it -- scenario 16, the
    -- combination one status column could never hold.
    o_submission := NVL(r.to_submission, v_sub);
    o_approval   := NVL(r.to_approval,   v_app);
    o_flag       := r.raise_flag;

    UPDATE oc_ts_week
       SET submission_status = o_submission,
           approval_status   = o_approval,
           updated_by        = p_actor,
           updated_on        = SYSTIMESTAMP
     WHERE ts_week_id = p_ts_week_id;

    -- THE DAYS RECEIVE, THEY DO NOT VOTE. One statement writes every day in
    -- the week, so a day can never disagree with the week it belongs to.
    UPDATE oc_ts_entry
       SET submission_status = o_submission,
           approval_status   = o_approval
     WHERE ts_week_id = p_ts_week_id;

    oc_time_raise_week_flag(p_ts_week_id, r.raise_flag, p_actor,
      p_event || ' / scenario ' || r.scenario_ref);

    EXIT;   -- first match only
  END LOOP;

  IF NOT v_found THEN
    -- Silence here would be the worst outcome: a status change that quietly
    -- did nothing, on the one table that decides whether anybody gets paid.
    RAISE_APPLICATION_ERROR(-20034,
      'No transition rule for event ' || p_event || ' from '
      || v_sub || '/' || v_app || ' (' || v_pstate || ', ' || v_timing
      || '). Add a row to OC_TS_TRANSITION rather than a branch to the code.');
  END IF;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] A thin wrapper for callers that do not need the outputs
PROMPT ============================================================

-- A DIFFERENT NAME, and it has to be.
--
-- This was written as a 3-argument oc_time_apply_event, on the assumption it
-- would overload the 6-argument engine above. Only PACKAGE members overload.
-- At schema level CREATE OR REPLACE does exactly what it says: it REPLACED the
-- engine, and this body's call to itself with 6 arguments failed PLS-00306.
--
-- The damage was not the error -- it was that the engine was gone and the
-- error pointed at the wrapper. Anything running between that and the next
-- script would have found oc_time_apply_event taking three arguments and
-- doing nothing.
--
-- Same family as the traps in CLAUDE.md section 5: a PL/SQL feature reached
-- for on the wrong side of a boundary. Overloading needs a package.
CREATE OR REPLACE PROCEDURE oc_time_fire_event(
  p_ts_week_id IN NUMBER,
  p_event      IN VARCHAR2,
  p_actor      IN VARCHAR2 DEFAULT 'SYSTEM')
IS
  v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
BEGIN
  oc_time_apply_event(p_ts_week_id, p_event, p_actor, v_s, v_a, v_f);
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [5/5] Verification — dry-run the rules against real weeks
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN submission  FORMAT A18
COLUMN approval    FORMAT A18
COLUMN timing      FORMAT A14
SELECT p.period_name,
       w.submission_status AS submission,
       w.approval_status   AS approval,
       oc_time_week_timing(MIN(w.ts_week_id)) AS timing,
       COUNT(*) AS weeks
  FROM oc_ts_week w
  JOIN oc_time_period p ON p.period_id = w.period_id
 GROUP BY p.period_name, w.submission_status, w.approval_status
 ORDER BY p.period_name;

PROMPT
PROMPT Every week should read NotYetSubmitted / Pending after the rebuild
PROMPT populate creates them and nobody has acted yet.

COLUMN event_code FORMAT A16
COLUMN timing     FORMAT A14
COLUMN to_s       FORMAT A18
COLUMN to_a       FORMAT A18
SELECT event_code, match_order, timing, require_flag,
       to_submission AS to_s, to_approval AS to_a, raise_flag
  FROM oc_ts_transition WHERE active_flag = 'Y'
 ORDER BY event_code, match_order;

PROMPT
PROMPT These rows ARE the rules. Nothing in the engine knows what Submit or
PROMPT DailyChange mean -- it reads them here. V5 reloads this table.
PROMPT
PROMPT NEXT: phase 2b rewires submit_week, approve_week, reject_week and the
PROMPT two cut-off jobs to call oc_time_apply_event instead of setting
PROMPT WEEK_STATUS themselves. Until that lands the engine is built and unused,
PROMPT which is deliberate -- it can be tested on a single week first.
