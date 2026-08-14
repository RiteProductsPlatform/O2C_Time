--==============================================================
-- time/38_week_versioning.sql
-- O2C Timesheet Module — every change to a week becomes a version
--
-- Three things, all raised 14-Aug-2026.
--
-- 1. VERSIONING. "Every change in the timesheet, if it is submitted or default
--    submitted by the system, needs to be saved as a version." And for a
--    backdated POET or allocation change: "we should have the old version and
--    the new version."
--
--    OC_TS_AUDIT already records entry-level before and after. What was
--    missing is the WEEK: what state it was in, what event moved it, what it
--    became, and what the hours were at that moment. That is what somebody
--    asking "what has this timesheet been through" actually wants, and it
--    could not be answered from the audit trail alone.
--
-- 2. ADVANCE CLOSE was computed wrongly. 36 used "any close-cycle date still
--    ahead of today", read off the Period Control screen's own help text. That
--    reproduced the screen -- and the screen is wrong, which was the point
--    being made when it was called a bug.
--
--    The phrase means billing proceeding BEFORE the month closes. So the test
--    is whether the DELIVERY cut-off -- the date time must be approved by for
--    billing -- falls before the MEC close. Not whether some date is in the
--    future, which is true of almost every open month and makes the flag say
--    nothing.
--
--    Measured against the four months: this makes it Yes for August alone,
--    where delivery 03-Sep precedes MEC close 07-Sep. The old rule said Yes to
--    three of four, which is a flag that has stopped distinguishing anything.
--
-- 3. THE DAY/WEEK POINT confirmed: approval and rejection are weekly, so days
--    receive the week's status and never vote on it. Versions are therefore
--    kept at WEEK grain too -- one row per event, not one per day.
--
-- AND TWO THINGS FOUND WHILE BUILDING IT, both of which would have failed at
-- runtime rather than at compile time:
--
-- 4. WEEK_STATUS / DAY_STATUS ARE NOW WRITTEN BY THE ENGINE. Phase 2b stops
--    the package writing them, and every screen still reads them. Without this
--    the engine would move a week to Submitted while the column still said
--    'Not yet submitted' -- wrong everywhere, with no error raised anywhere.
--
-- 5. TWO CHECK CONSTRAINTS REJECT WHAT THE ENGINE PRODUCES.
--    CHK_OC_TSE_DSTAT has no 'Defaulted', so cascading a defaulted week to its
--    days raises ORA-02290 on every row. CHK_OC_TSW_DEFBY_REQ demands
--    DEFAULTED_BY on any Defaulted week -- the identical trap recorded in
--    CLAUDE.md section 8.1, where it meant the weekly job had never once run
--    against real data. Both are handled in [3] and [5].
--
-- Idempotent. Depends on: time/36, time/37
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
PROMPT [1/4] OC_TS_WEEK_VERSION
PROMPT ============================================================

DECLARE
BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_ts_week_version (
      VERSION_ID      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      TS_WEEK_ID      NUMBER            NOT NULL,
      VERSION_NO      NUMBER(6)         NOT NULL,
      EVENT_CODE      VARCHAR2(30 CHAR) NOT NULL,
      -- Both sides on one row. Asking "what changed" should not require
      -- fetching the previous version and diffing it.
      FROM_SUBMISSION VARCHAR2(30 CHAR),
      FROM_APPROVAL   VARCHAR2(30 CHAR),
      TO_SUBMISSION   VARCHAR2(30 CHAR),
      TO_APPROVAL     VARCHAR2(30 CHAR),
      FLAG_RAISED     VARCHAR2(30 CHAR),
      -- The circumstances the rule was chosen under. Without these, a version
      -- says what happened but not why that was the right answer.
      TIMING          VARCHAR2(14 CHAR),
      PERIOD_STATE    VARCHAR2(10 CHAR),
      SCENARIO_REF    VARCHAR2(40 CHAR),
      -- Hours as they stood. A status history with no numbers cannot answer
      -- "what were the hours when the manager approved this".
      BILLABLE_HOURS     NUMBER(8,2),
      NON_BILLABLE_HOURS NUMBER(8,2),
      LEAVE_HOURS        NUMBER(8,2),
      TOTAL_HOURS        NUMBER(8,2),
      CHANGED_BY      VARCHAR2(100 CHAR) NOT NULL,
      CHANGED_ON      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      NOTES           VARCHAR2(400 CHAR),
      CONSTRAINT uk_oc_tswv UNIQUE (TS_WEEK_ID, VERSION_NO)
    )~';
  DBMS_OUTPUT.PUT_LINE('OC_TS_WEEK_VERSION created');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN DBMS_OUTPUT.PUT_LINE('OC_TS_WEEK_VERSION exists, skipped');
  ELSE RAISE; END IF;
END;
/

DECLARE
BEGIN
  EXECUTE IMMEDIATE
    'CREATE INDEX ix_oc_tswv_week ON oc_ts_week_version (ts_week_id, version_no)';
  DBMS_OUTPUT.PUT_LINE('ix_oc_tswv_week created');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-955, -1408) THEN DBMS_OUTPUT.PUT_LINE('index exists, skipped');
  ELSE RAISE; END IF;
END;
/

-- No foreign key to OC_TS_WEEK, and that is deliberate. A version is a
-- historical record: it must survive the week being rebuilt, which is exactly
-- what populate does every month. An ON DELETE CASCADE here would erase the
-- history at the moment it becomes most interesting.

PROMPT ============================================================
PROMPT [2/4] ADVANCE_CLOSE — delivery before close, not "some date ahead"
PROMPT ============================================================

CREATE OR REPLACE VIEW oc_time_period AS
SELECT m.period_id,
       UPPER(TO_CHAR(m.start_date, 'MON-YYYY'))  AS period_name,
       EXTRACT(YEAR  FROM m.start_date)          AS period_year,
       EXTRACT(MONTH FROM m.start_date)          AS period_month,
       m.status,
       m.start_date,
       m.end_date,
       m.accounting_date,
       m.delivery_cutoff_date AS delivery_cutoff,
       m.finance_cutoff_date  AS finance_cutoff,
       m.mec_close_date       AS mec_close,
       m.book_close_date      AS book_closure,
       c.ts_cutoff_day,
       c.ts_cutoff_time,
       CAST(NULL AS DATE)              AS client_cutoff,
       CAST(NULL AS VARCHAR2(60 CHAR)) AS payroll_country,
       CAST(NULL AS DATE)              AS payroll_cutoff,
       -- Advance close means billing proceeds BEFORE the month closes. So the
       -- test is the DELIVERY cut-off -- the date time must be approved by for
       -- billing -- against the MEC close.
       --
       -- 36 used the Period Control screen's own wording, "any close-cycle
       -- date still ahead of today", and reproduced the screen exactly. That
       -- turned out to reproduce a bug: it is true of nearly every open month,
       -- so the flag said Yes to three months in four and distinguished
       -- nothing. Corrected 14-Aug on the rule as stated by the business.
       CASE WHEN m.delivery_cutoff_date < m.mec_close_date
            THEN 'Y' ELSE 'N' END AS advance_close,
       c.contractor_resubmit_days,
       c.hold_release_days,
       c.adjustment_months,
       c.backdated_months,
       m.period_id   AS mec_period_id,
       m.period_name AS mec_period_name,
       'Y'           AS mec_linked,
       m.created_by, m.created_on, m.updated_by, m.updated_on
  FROM oc_mec_period_src m
 CROSS JOIN (
       SELECT MAX(CASE WHEN config_name='ts_cutoff_day'  THEN config_value END) AS ts_cutoff_day,
              MAX(CASE WHEN config_name='ts_cutoff_time' THEN config_value END) AS ts_cutoff_time,
              MAX(CASE WHEN config_name='contractor_resubmit_days' THEN TO_NUMBER(config_value) END) AS contractor_resubmit_days,
              MAX(CASE WHEN config_name='hold_release_days'        THEN TO_NUMBER(config_value) END) AS hold_release_days,
              MAX(CASE WHEN config_name='adjustment_months'        THEN TO_NUMBER(config_value) END) AS adjustment_months,
              MAX(CASE WHEN config_name='backdated_months'         THEN TO_NUMBER(config_value) END) AS backdated_months
         FROM oc_time_config WHERE scope_key = 'GLOBAL') c;

PROMPT ============================================================
PROMPT [3/6] DAY_STATUS must be allowed to say 'Defaulted'
PROMPT ============================================================

-- CHK_OC_TSE_DSTAT permits Pending / Approved / Rejected only. Cascading a
-- defaulted week down to its days therefore fails with ORA-02290 on every
-- row -- the same shape of fault as CHK_OC_TSW_DEFBY_REQ in section 8.1 of
-- CLAUDE.md, and for the same reason: the constraint predates defaulting
-- being a day-level idea.
--
-- The days now carry the week's status verbatim, so the day constraint has
-- to admit every value the week can hold.
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSE_DSTAT';
  IF v_n > 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_entry DROP CONSTRAINT chk_oc_tse_dstat';
  END IF;
  EXECUTE IMMEDIATE q'~
    ALTER TABLE oc_ts_entry ADD CONSTRAINT chk_oc_tse_dstat
      CHECK (day_status IN ('Pending','Approved','Rejected','Defaulted'))~';
  DBMS_OUTPUT.PUT_LINE('chk_oc_tse_dstat now admits Defaulted');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('chk_oc_tse_dstat: ' || SUBSTR(SQLERRM,1,150));
  RAISE;
END;
/

PROMPT ============================================================
PROMPT [4/6] WEEK_STATUS stays in step with the two axes
PROMPT ============================================================

-- Phase 2b points submit_week, approve_week, reject_week and the two cut-off
-- jobs at the engine. The moment it does, nothing writes WEEK_STATUS any more
-- -- and WEEK_STATUS is what every screen, every approval list and the accrual
-- confirm gate still read.
--
-- Left alone, the engine would move a week to Submitted/Pending while the
-- column still said 'Not yet submitted', and every screen would be wrong with
-- no error anywhere. So the engine derives it. One writer, two representations.
--
-- Revision 2 is not being kept alive out of sentiment: RULE-020 gates the
-- month confirm on all-Approved by reading this column, and rewriting that
-- gate is a Phase 3 job that should not ride along with the status engine.
CREATE OR REPLACE FUNCTION oc_time_derive_week_status(
  p_submission IN VARCHAR2,
  p_approval   IN VARCHAR2,
  p_overridden IN VARCHAR2 DEFAULT 'N') RETURN VARCHAR2
IS
BEGIN
  -- Approval decided, so it wins: an approved week reads Approved whether it
  -- got there by submission or by defaulting.
  IF p_approval = 'Approved' THEN
    RETURN CASE WHEN p_overridden = 'Y' THEN 'Overridden and approved'
                ELSE 'Approved' END;
  ELSIF p_approval = 'Rejected' THEN
    RETURN 'Rejected';
  ELSIF p_approval = 'ManagerDefaulted' THEN
    RETURN 'Defaulted';
  END IF;

  -- Approval still Pending, so the submission axis is the visible truth.
  RETURN CASE p_submission
           WHEN 'NotYetSubmitted' THEN 'Not yet submitted'
           WHEN 'Submitted'       THEN 'Submitted'
           WHEN 'Defaulted'       THEN 'Defaulted'
           -- Late submission became a FLAG in revision 2; the week itself is
           -- Submitted. This is exactly the collapse the two axes exist to
           -- undo, and the one place it has to be re-applied on the way out.
           WHEN 'LateSubmission'  THEN 'Submitted'
           ELSE 'Not yet submitted'
         END;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [5/6] APPLY_EVENT writes a version on every change
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
  v_ver    NUMBER;
  v_bill   NUMBER; v_nonbill NUMBER; v_leave NUMBER; v_total NUMBER;
  v_over   VARCHAR2(1);
  v_legacy VARCHAR2(40);
  v_defby  VARCHAR2(10);
  v_found  BOOLEAN := FALSE;
BEGIN
  SELECT w.submission_status, w.approval_status,
         CASE WHEN p.status = 'Open' THEN 'Open' ELSE 'Closed' END,
         w.billable_hours, w.non_billable_hours, w.leave_hours, w.total_hours,
         w.overridden_flag
    INTO v_sub, v_app, v_pstate, v_bill, v_nonbill, v_leave, v_total, v_over
    FROM oc_ts_week w
    JOIN oc_time_period p ON p.period_id = w.period_id
   WHERE w.ts_week_id = p_ts_week_id;

  v_timing := oc_time_week_timing(p_ts_week_id);

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
    o_submission := NVL(r.to_submission, v_sub);
    o_approval   := NVL(r.to_approval,   v_app);
    o_flag       := r.raise_flag;

    -- The Overridden flag is raised by THIS event, below, so the value read
    -- before the loop is stale for ApproveOverride. Without this the week
    -- would derive plain 'Approved' and the override would vanish from every
    -- screen at the exact moment it happened.
    IF r.raise_flag = 'Overridden' THEN v_over := 'Y'; END IF;
    v_legacy := oc_time_derive_week_status(o_submission, o_approval, v_over);

    -- CHK_OC_TSW_DEFBY_REQ: a Defaulted week MUST say who caused it, so this
    -- has to be written in the same statement or the update is rejected.
    --
    -- EMPLOYEE wins when both are true, and that ordering is load-bearing.
    -- run_salary_stopping filters on 'EMPLOYEE' -- an employee who missed the
    -- weekly cut-off and whose manager then also missed the delivery cut-off
    -- would, under the other ordering, have their default relabelled MANAGER
    -- and their salary hold quietly disappear. RULE-016 is that awaiting
    -- approval never stops pay; it does not say a manager's lateness erases
    -- the employee's.
    v_defby := CASE
                 WHEN v_legacy <> 'Defaulted'          THEN NULL
                 WHEN o_submission = 'Defaulted'       THEN 'EMPLOYEE'
                 WHEN o_approval = 'ManagerDefaulted'  THEN 'MANAGER'
                 ELSE 'EMPLOYEE'
               END;

    UPDATE oc_ts_week
       SET submission_status = o_submission,
           approval_status   = o_approval,
           week_status       = v_legacy,
           -- NVL keeps an existing EMPLOYEE attribution rather than letting a
           -- later manager default overwrite it.
           defaulted_by      = CASE WHEN v_defby IS NULL THEN NULL
                                    ELSE NVL(defaulted_by, v_defby) END,
           updated_by        = p_actor,
           updated_on        = SYSTIMESTAMP
     WHERE ts_week_id = p_ts_week_id;

    -- The days receive the week's status. Approval is weekly, so one
    -- statement writes them all and a day can never disagree with its week.
    -- DAY_STATUS is the day-level equivalent of WEEK_STATUS and is kept in
    -- step for the same reason: the timesheet grid still colours cells by it.
    UPDATE oc_ts_entry
       SET submission_status = o_submission,
           approval_status   = o_approval,
           day_status        = CASE o_approval
                                 WHEN 'Approved'         THEN 'Approved'
                                 WHEN 'Rejected'         THEN 'Rejected'
                                 WHEN 'ManagerDefaulted' THEN 'Defaulted'
                                 ELSE 'Pending'
                               END
     WHERE ts_week_id = p_ts_week_id;

    oc_time_raise_week_flag(p_ts_week_id, r.raise_flag, p_actor,
      p_event || ' / scenario ' || r.scenario_ref);

    -- ── THE VERSION ──────────────────────────────────────────
    -- Written for EVERY event, including the ones nobody chose: a week
    -- auto-submitted by the cut-off job gets a version exactly as a week
    -- submitted by hand does. That is the point -- "who did this and when"
    -- has to be answerable for the system's own actions too.
    SELECT NVL(MAX(version_no), 0) + 1 INTO v_ver
      FROM oc_ts_week_version WHERE ts_week_id = p_ts_week_id;

    INSERT INTO oc_ts_week_version (
      ts_week_id, version_no, event_code,
      from_submission, from_approval, to_submission, to_approval,
      flag_raised, timing, period_state, scenario_ref,
      billable_hours, non_billable_hours, leave_hours, total_hours,
      changed_by, notes)
    VALUES (
      p_ts_week_id, v_ver, p_event,
      v_sub, v_app, o_submission, o_approval,
      r.raise_flag, v_timing, v_pstate, r.scenario_ref,
      -- Hours as they stood BEFORE this event. A backdated allocation change
      -- reads as: version 3 had these hours on this project, version 4 has
      -- those -- which is the old-and-new the requirement asks for.
      v_bill, v_nonbill, v_leave, v_total,
      p_actor,
      CASE WHEN v_sub = o_submission AND v_app = o_approval
           THEN 'No status change; recorded because the event occurred.'
      END);

    EXIT;
  END LOOP;

  IF NOT v_found THEN
    RAISE_APPLICATION_ERROR(-20034,
      'No transition rule for event ' || p_event || ' from '
      || v_sub || '/' || v_app || ' (' || v_pstate || ', ' || v_timing
      || '). Add a row to OC_TS_TRANSITION rather than a branch to the code.');
  END IF;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [6/6] V_OC_TS_WEEK_HISTORY — the version trail, readable
PROMPT ============================================================

-- What a person means by "show me this timesheet's history": one line per
-- thing that happened, in order, in words.
CREATE OR REPLACE VIEW v_oc_ts_week_history AS
SELECT v.ts_week_id,
       v.version_no,
       w.employee_id,
       p.period_name,
       TO_CHAR(w.week_start, 'DD-MON-YY') || ' to '
         || TO_CHAR(w.week_end, 'DD-MON-YY') AS week_of,
       v.event_code,
       CASE v.event_code
         WHEN 'Submit'          THEN 'Submitted'
         WHEN 'Approve'         THEN 'Approved'
         WHEN 'ApproveOverride' THEN 'Approved after the manager edited the hours'
         WHEN 'Reject'          THEN 'Rejected and sent back'
         WHEN 'WeeklyCutoff'    THEN 'Auto-submitted at the weekly cut-off'
         WHEN 'DeliveryCutoff'  THEN 'Manager cut-off passed with no action'
         WHEN 'DailyChange'     THEN 'A backdated change invalidated the approval'
         ELSE v.event_code
       END AS what_happened,
       v.from_submission || ' / ' || v.from_approval AS was,
       v.to_submission   || ' / ' || v.to_approval   AS became,
       v.flag_raised,
       v.timing,
       v.total_hours AS hours_before,
       v.changed_by,
       TO_CHAR(v.changed_on, 'DD-MON-YY HH24:MI:SS') AS changed_on
  FROM oc_ts_week_version v
  JOIN oc_ts_week   w ON w.ts_week_id = v.ts_week_id
  JOIN oc_time_period p ON p.period_id = w.period_id;

PROMPT
PROMPT --- advance close under the corrected rule --------------------
COLUMN period_name FORMAT A12
COLUMN adv         FORMAT A4
SELECT period_name, status, advance_close AS adv,
       TO_CHAR(delivery_cutoff,'DD-MON-YY') AS delivery,
       TO_CHAR(mec_close,'DD-MON-YY')       AS mec_close
  FROM oc_time_period ORDER BY start_date;

PROMPT
PROMPT Expect Y for AUG-2026 alone -- delivery 03-Sep precedes MEC close
PROMPT 07-Sep, so billing runs ahead of the close. The Period Control screen
PROMPT will still show Yes on three of four; that screen computes it the old
PROMPT way and is the bug this corrects.

PROMPT
PROMPT --- version trail (empty until an event fires) ----------------
SELECT COUNT(*) AS versions FROM oc_ts_week_version;

PROMPT
PROMPT Nothing writes versions yet beyond apply_event itself. Phase 2b points
PROMPT submit_week, approve_week, reject_week and the two cut-off jobs at it,
PROMPT and from then on every change to a week -- including the ones the system
PROMPT makes on somebody's behalf -- leaves a numbered version behind.
