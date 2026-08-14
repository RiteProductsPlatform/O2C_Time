--==============================================================
-- time/27_status_model_v4.sql
-- O2C Timesheet Module — status & flag model V4, phase 1
--
-- From Time scenarios_V4.xlsx (visible sheets only: Statuses, Flags,
-- Scenarios, Other requirements). Supersedes the revision-2 model.
--
-- THE MAIL CARRYING THAT WORKBOOK SAID:
--   "This might undergo changes as we build integrations. Kindly structure
--    the code accordingly."
--
-- Taken seriously, that rules out the obvious implementation. Statuses in
-- CHECK constraints, flags as boolean columns and transitions as IF/ELSE in
-- PL/SQL each make the next revision a schema migration plus a package
-- rewrite plus a regression pass. So all three are DATA here:
--
--   OC_TS_STATUS_DEF   the vocabulary        -> FK, never CHECK
--   OC_TS_FLAG_DEF     the flags
--   OC_TS_TRANSITION   the sixteen scenario rows, as rows
--
-- V5 then reloads three tables instead of rewriting a package.
--
-- WHAT CHANGES CONCEPTUALLY
--
-- 1. ONE STATUS BECOMES TWO. Submission (the employee axis) and Approval
--    (the manager axis) are independent. Scenario 14 is Defaulted +
--    Manager Defaulted -- both cut-offs missed -- and scenario 16 is
--    Defaulted + Approved. Neither fits in one column, and today the module
--    loses half of each.
--
--    DEFAULTED_BY exists only because one column could not say WHOSE cut-off
--    was missed. The split makes it redundant, which is a good sign: this is
--    the shape the module has been approximating.
--
-- 2. BOTH AXES EXIST AT BOTH GRAINS. OC_TS_ENTRY.DAY_STATUS was already a
--    day-level approval axis, half-built and never named as one.
--
-- 3. FLAGS BECOME ROWS. "Every flag should be maintained with time stamp" --
--    six booleans today record THAT something happened and never WHEN.
--    Advance closure and Reversal fold into Adjusted (confirmed 13-Aug); no
--    detail is lost because the flag was only ever a summary --
--    OC_TS_MONTH_CONFIRM.CONFIRM_TYPE and OC_TS_ENTRY.ENTRY_TYPE still carry
--    the specifics.
--
-- PHASE 1 IS ADDITIVE AND REVERSIBLE. Nothing is dropped, and WEEK_STATUS /
-- DAY_STATUS stay maintained in parallel so every existing reader keeps
-- working and the mapping can be proven against a real period before any
-- behaviour changes. Phase 2 moves the rules onto the engine.
--
-- Idempotent. Depends on: time/03, time/04
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ── WHICH SCHEMA AM I? ───────────────────────────────────────
-- Run in the wrong one and every statement fails with ORA-00942 naming a
-- table that plainly exists -- because it exists in the OTHER schema. That
-- happened on 14-Aug against O2C_DEV, and the output is long enough that the
-- cause is not obvious from it. So: refuse immediately, and say so.
--
-- O2C_DEV owns OC_MEC_PERIOD and is the schema this module READS FROM.
-- O2C_TIME owns everything else here and is the schema to be CONNECTED AS.
DECLARE
  v_me VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
BEGIN
  IF v_me <> 'O2C_TIME' THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || v_me || '. This script must run as O2C_TIME -- ' ||
      'O2C_DEV owns OC_MEC_PERIOD and is only read FROM. Reconnect and re-run.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || v_me);
END;
/

PROMPT ============================================================
PROMPT [1/7] OC_TS_STATUS_DEF — the vocabulary
PROMPT ============================================================

DECLARE
  PROCEDURE ddl(p_sql VARCHAR2, p_what VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34) || 'created');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE IN (-955, -1430, -2260, -2275) THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34) || 'exists, skipped');
    ELSE RAISE; END IF;
  END;
BEGIN
  -- STATUS_CODE is the primary key on its own, not (AXIS, STATUS_CODE).
  -- The eight values do not collide across the two axes -- Submitted and
  -- Pending belong to exactly one each -- so a single-column key lets the
  -- status columns carry an ordinary foreign key. A composite key would need
  -- the axis stored redundantly on every week and every entry to point at it.
  ddl(q'~
    CREATE TABLE oc_ts_status_def (
      STATUS_CODE   VARCHAR2(30 CHAR) PRIMARY KEY,
      AXIS          VARCHAR2(12 CHAR) NOT NULL,
      LABEL         VARCHAR2(60 CHAR) NOT NULL,
      DESCRIPTION   VARCHAR2(400 CHAR),
      SORT_ORDER    NUMBER(3) DEFAULT 100 NOT NULL,
      ACTIVE_FLAG   CHAR(1) DEFAULT 'Y' NOT NULL,
      CREATED_BY    VARCHAR2(100) DEFAULT 'SEED' NOT NULL,
      CREATED_ON    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT chk_oc_tsd_axis CHECK (AXIS IN ('SUBMISSION','APPROVAL')),
      CONSTRAINT chk_oc_tsd_act  CHECK (ACTIVE_FLAG IN ('Y','N'))
    )~', 'OC_TS_STATUS_DEF');

  ddl(q'~
    CREATE TABLE oc_ts_flag_def (
      FLAG_CODE     VARCHAR2(30 CHAR) PRIMARY KEY,
      LABEL         VARCHAR2(60 CHAR) NOT NULL,
      DESCRIPTION   VARCHAR2(400 CHAR),
      SCOPE_LEVEL   VARCHAR2(6 CHAR) DEFAULT 'BOTH' NOT NULL,
      SORT_ORDER    NUMBER(3) DEFAULT 100 NOT NULL,
      ACTIVE_FLAG   CHAR(1) DEFAULT 'Y' NOT NULL,
      CREATED_BY    VARCHAR2(100) DEFAULT 'SEED' NOT NULL,
      CREATED_ON    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT chk_oc_tfd_scope CHECK (SCOPE_LEVEL IN ('WEEK','DAY','BOTH')),
      CONSTRAINT chk_oc_tfd_act   CHECK (ACTIVE_FLAG IN ('Y','N'))
    )~', 'OC_TS_FLAG_DEF');
END;
/

PROMPT ============================================================
PROMPT [2/7] Seed the vocabulary
PROMPT ============================================================

DECLARE
  PROCEDURE st(c VARCHAR2, a VARCHAR2, l VARCHAR2, d VARCHAR2, o NUMBER) IS
  BEGIN
    MERGE INTO oc_ts_status_def t USING (SELECT c AS cd FROM dual) s
       ON (t.status_code = s.cd)
     WHEN MATCHED THEN UPDATE SET axis=a, label=l, description=d, sort_order=o
     WHEN NOT MATCHED THEN INSERT (status_code, axis, label, description, sort_order)
          VALUES (c, a, l, d, o);
  END;
  PROCEDURE fl(c VARCHAR2, l VARCHAR2, d VARCHAR2, o NUMBER) IS
  BEGIN
    MERGE INTO oc_ts_flag_def t USING (SELECT c AS cd FROM dual) s
       ON (t.flag_code = s.cd)
     WHEN MATCHED THEN UPDATE SET label=l, description=d, sort_order=o
     WHEN NOT MATCHED THEN INSERT (flag_code, label, description, sort_order)
          VALUES (c, l, d, o);
  END;
BEGIN
  -- Wording taken from the workbook's Statuses sheet verbatim, so the screen
  -- and the specification cannot drift apart.
  st('NotYetSubmitted','SUBMISSION','Not Yet Submitted',
     'Initial state right after monthly pre-population; employee has not submitted the week yet.', 10);
  st('Submitted','SUBMISSION','Submitted',
     'Employee submitted the week within the weekly cutoff.', 20);
  st('Defaulted','SUBMISSION','Defaulted',
     'Employee took no action by the weekly cutoff; the cutoff job auto-submitted on their behalf.', 30);
  st('LateSubmission','SUBMISSION','Late Submission',
     'Employee (re)submits outside the normal weekly cycle, after a prior Rejected or Defaulted status.', 40);

  st('Pending','APPROVAL','Pending',
     'Submitted and awaiting manager review.', 10);
  st('Approved','APPROVAL','Approved',
     'Manager approved, with or without edits.', 20);
  st('Rejected','APPROVAL','Rejected',
     'Manager rejected, with a mandatory reason and optional remarks.', 30);
  st('ManagerDefaulted','APPROVAL','Manager Defaulted',
     'Manager cutoff passed with no manager action on a submitted/defaulted timesheet.', 40);

  fl('Overridden','Overridden',
     'Manager edited the employee-entered hours before or at approval.', 10);
  fl('Adjusted','Adjusted',
     'A correction was made to a day in an already-approved or closed period, inside the '
     || 'backdate window. Advance closure and reversal both surface as this (13-Aug-2026); '
     || 'the specifics stay on OC_TS_MONTH_CONFIRM.CONFIRM_TYPE and OC_TS_ENTRY.ENTRY_TYPE.', 20);
  fl('Defaulted','Defaulted',
     'Employee took no action by the weekly cutoff; the cutoff job auto-submitted.', 30);
  fl('ManagerDefaulted','Manager Defaulted',
     'Manager cutoff passed with no manager action.', 40);
  fl('LateSubmission','Late Submission',
     'Employee (re)submitted outside the normal weekly cycle.', 50);

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('8 statuses, 5 flags seeded');
END;
/

PROMPT ============================================================
PROMPT [3/7] OC_TS_TRANSITION — the scenario sheet, as rows
PROMPT ============================================================

DECLARE
  PROCEDURE ddl(p_sql VARCHAR2, p_what VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34) || 'created');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE IN (-955, -1430, -2260, -2275) THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34) || 'exists, skipped');
    ELSE RAISE; END IF;
  END;
BEGIN
  -- NULL means "any" on every FROM column, and "leave alone" on every TO
  -- column. MATCH_ORDER decides which row wins when several match: lowest
  -- first, so a specific rule beats the catch-all beneath it.
  --
  -- REQUIRE_FLAG is what makes the Late Submission rule expressible. The
  -- workbook says a resubmission after a DEFAULTED week is Late Submission
  -- rather than Submitted -- but by the time the employee resubmits, the
  -- daily change has already reset the submission axis to Not Yet Submitted
  -- and that history is gone from the status. It survives on the FLAG, which
  -- is precisely why flags are not merely decoration.
  ddl(q'~
    CREATE TABLE oc_ts_transition (
      TRANSITION_ID   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EVENT_CODE      VARCHAR2(30 CHAR) NOT NULL,
      MATCH_ORDER     NUMBER(4) DEFAULT 100 NOT NULL,
      FROM_SUBMISSION VARCHAR2(30 CHAR),
      FROM_APPROVAL   VARCHAR2(30 CHAR),
      PERIOD_STATE    VARCHAR2(10 CHAR),
      REQUIRE_FLAG    VARCHAR2(30 CHAR),
      TO_SUBMISSION   VARCHAR2(30 CHAR),
      TO_APPROVAL     VARCHAR2(30 CHAR),
      RAISE_FLAG      VARCHAR2(30 CHAR),
      SCENARIO_REF    VARCHAR2(40 CHAR),
      NOTES           VARCHAR2(400 CHAR),
      ACTIVE_FLAG     CHAR(1) DEFAULT 'Y' NOT NULL,
      CONSTRAINT chk_oc_ttr_pstate CHECK (PERIOD_STATE IN ('Open','Closed')),
      CONSTRAINT chk_oc_ttr_act    CHECK (ACTIVE_FLAG IN ('Y','N')),
      CONSTRAINT fk_oc_ttr_fsub  FOREIGN KEY (FROM_SUBMISSION) REFERENCES oc_ts_status_def,
      CONSTRAINT fk_oc_ttr_fapp  FOREIGN KEY (FROM_APPROVAL)   REFERENCES oc_ts_status_def,
      CONSTRAINT fk_oc_ttr_tsub  FOREIGN KEY (TO_SUBMISSION)   REFERENCES oc_ts_status_def,
      CONSTRAINT fk_oc_ttr_tapp  FOREIGN KEY (TO_APPROVAL)     REFERENCES oc_ts_status_def,
      CONSTRAINT fk_oc_ttr_rflag FOREIGN KEY (RAISE_FLAG)      REFERENCES oc_ts_flag_def,
      CONSTRAINT fk_oc_ttr_qflag FOREIGN KEY (REQUIRE_FLAG)    REFERENCES oc_ts_flag_def
    )~', 'OC_TS_TRANSITION');
END;
/

PROMPT ============================================================
PROMPT [4/7] Load the transitions
PROMPT ============================================================

DECLARE
  PROCEDURE tr(ev VARCHAR2, ord NUMBER, fsub VARCHAR2, fapp VARCHAR2,
               pst VARCHAR2, rq VARCHAR2, tsub VARCHAR2, tapp VARCHAR2,
               rf VARCHAR2, ref VARCHAR2, nt VARCHAR2 DEFAULT NULL) IS
  BEGIN
    MERGE INTO oc_ts_transition t
    USING (SELECT ev AS e, ord AS o FROM dual) s
       ON (t.event_code = s.e AND t.match_order = s.o)
     WHEN MATCHED THEN UPDATE
          SET from_submission=fsub, from_approval=fapp, period_state=pst,
              require_flag=rq, to_submission=tsub, to_approval=tapp,
              raise_flag=rf, scenario_ref=ref, notes=nt
     WHEN NOT MATCHED THEN
          INSERT (event_code, match_order, from_submission, from_approval,
                  period_state, require_flag, to_submission, to_approval,
                  raise_flag, scenario_ref, notes)
          VALUES (ev, ord, fsub, fapp, pst, rq, tsub, tapp, rf, ref, nt);
  END;
BEGIN
  ----------------------------------------------------------------
  -- DailyChange — a backdated leave or allocation change lands on a week.
  --
  -- CONFIRMED 13-Aug-2026: both axes move. The prior approval is void and the
  -- week goes back to the employee. The Scenarios sheet writes this as
  -- "Rejected | Not Yet submitted", which reads as the two columns swapped --
  -- it is shorthand for "sent back", and both values are the new state.
  -- Everywhere else in the sheet the labelled Employee | Manager order holds
  -- (scenarios 4, 5, 8, 9, 12, 14, 16 all confirm it).
  ----------------------------------------------------------------
  tr('DailyChange', 10, 'NotYetSubmitted', 'Pending', NULL, NULL,
     NULL, NULL, NULL, '2.1.1 / 3.1',
     'Nobody has acted, so there is nothing to invalidate. No-op.');

  tr('DailyChange', 20, NULL, NULL, 'Closed', NULL,
     'NotYetSubmitted', 'Rejected', 'Adjusted', '2.3.x / 2.4.x',
     'Closed period: the correction is an adjustment and is flagged as one.');

  tr('DailyChange', 30, NULL, NULL, NULL, NULL,
     'NotYetSubmitted', 'Rejected', NULL, '2.2.x',
     'Open period: sent back, no Adjusted flag.');

  ----------------------------------------------------------------
  -- Submit — the employee submits or resubmits.
  -- A week that was ever Defaulted resubmits as Late Submission. The status
  -- has been reset by then, so the DEFAULTED FLAG is what remembers.
  ----------------------------------------------------------------
  tr('Submit', 10, NULL, NULL, NULL, 'Defaulted',
     'LateSubmission', 'Pending', 'LateSubmission', '2.2 / 2.3 / 2.4 / 12',
     'Resubmission after a defaulted week is late by definition.');

  tr('Submit', 20, NULL, 'Rejected', NULL, NULL,
     'Submitted', 'Pending', NULL, '7',
     'Resubmission after a rejection, inside the cut-off.');

  tr('Submit', 30, NULL, NULL, NULL, NULL,
     'Submitted', 'Pending', NULL, '4',
     'Ordinary weekly submission.');

  ----------------------------------------------------------------
  -- Approve / Reject
  ----------------------------------------------------------------
  tr('Approve', 10, NULL, NULL, NULL, NULL,
     NULL, 'Approved', NULL, '5 / 10 / 12',
     'Submission axis untouched -- Defaulted stays Defaulted when approved (16).');

  tr('ApproveOverride', 10, NULL, NULL, NULL, NULL,
     NULL, 'Approved', 'Overridden', '15 / 16',
     'Manager edited the hours before approving.');

  tr('Reject', 10, NULL, NULL, NULL, NULL,
     'NotYetSubmitted', 'Rejected', NULL, '6 / 11 / 13',
     'Same shape as a backdated change: void the approval, send it back.');

  ----------------------------------------------------------------
  -- The two cut-off jobs
  ----------------------------------------------------------------
  tr('WeeklyCutoff', 10, 'NotYetSubmitted', NULL, NULL, NULL,
     'Defaulted', 'Pending', 'Defaulted', '9',
     'Employee missed their cut-off; the job submits on their behalf.');

  tr('DeliveryCutoff', 10, NULL, 'Pending', NULL, NULL,
     NULL, 'ManagerDefaulted', 'ManagerDefaulted', '8 / 14',
     'Manager missed the delivery cut-off. Submission axis untouched, so '
     || 'Defaulted + Manager Defaulted is expressible (14).');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('transitions loaded');
END;
/

PROMPT ============================================================
PROMPT [5/7] The two axes, on both grains
PROMPT ============================================================

DECLARE
  PROCEDURE addcol(p_tab VARCHAR2, p_col VARCHAR2, p_spec VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_tab || ' ADD (' || p_col || ' ' || p_spec || ')';
    DBMS_OUTPUT.PUT_LINE(RPAD(p_tab || '.' || p_col, 40) || 'added');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_tab || '.' || p_col, 40) || 'exists, skipped');
    ELSE RAISE; END IF;
  END;
  PROCEDURE addfk(p_tab VARCHAR2, p_con VARCHAR2, p_col VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_tab || ' ADD CONSTRAINT ' || p_con
                   || ' FOREIGN KEY (' || p_col || ') REFERENCES oc_ts_status_def';
    DBMS_OUTPUT.PUT_LINE(RPAD(p_con, 40) || 'added');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -2275 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_con, 40) || 'exists, skipped');
    ELSE RAISE; END IF;
  END;
BEGIN
  -- ONE column per axis per grain, each a foreign key to the vocabulary.
  -- Deliberately NOT a CHECK constraint: the whole point of the disclaimer is
  -- that a new status should be an INSERT, not an ALTER plus a rebuild.
  addcol('oc_ts_week',  'SUBMISSION_STATUS', 'VARCHAR2(30 CHAR)');
  addcol('oc_ts_week',  'APPROVAL_STATUS',   'VARCHAR2(30 CHAR)');
  addcol('oc_ts_entry', 'SUBMISSION_STATUS', 'VARCHAR2(30 CHAR)');
  addcol('oc_ts_entry', 'APPROVAL_STATUS',   'VARCHAR2(30 CHAR)');

  addfk('oc_ts_week',  'fk_oc_tsw_sub',  'SUBMISSION_STATUS');
  addfk('oc_ts_week',  'fk_oc_tsw_app',  'APPROVAL_STATUS');
  addfk('oc_ts_entry', 'fk_oc_tse_sub',  'SUBMISSION_STATUS');
  addfk('oc_ts_entry', 'fk_oc_tse_app',  'APPROVAL_STATUS');
END;
/

PROMPT ============================================================
PROMPT [6/7] Flag tables — a flag is a row with a timestamp
PROMPT ============================================================

DECLARE
  PROCEDURE ddl(p_sql VARCHAR2, p_what VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34) || 'created');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -955 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 34) || 'exists, skipped');
    ELSE RAISE; END IF;
  END;
BEGIN
  -- Two tables rather than one polymorphic table, so each keeps a real
  -- foreign key. A single OC_TS_FLAG with a SCOPE discriminator could not.
  ddl(q'~
    CREATE TABLE oc_ts_week_flag (
      TS_WEEK_ID  NUMBER            NOT NULL,
      FLAG_CODE   VARCHAR2(30 CHAR) NOT NULL,
      SET_ON      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      SET_BY      VARCHAR2(100 CHAR),
      CLEARED_ON  TIMESTAMP,
      CLEARED_BY  VARCHAR2(100 CHAR),
      NOTES       VARCHAR2(400 CHAR),
      CONSTRAINT pk_oc_tswf PRIMARY KEY (TS_WEEK_ID, FLAG_CODE),
      CONSTRAINT fk_oc_tswf_wk FOREIGN KEY (TS_WEEK_ID)
        REFERENCES oc_ts_week(ts_week_id) ON DELETE CASCADE,
      CONSTRAINT fk_oc_tswf_fl FOREIGN KEY (FLAG_CODE) REFERENCES oc_ts_flag_def
    )~', 'OC_TS_WEEK_FLAG');

  ddl(q'~
    CREATE TABLE oc_ts_day_flag (
      TS_ENTRY_ID NUMBER            NOT NULL,
      FLAG_CODE   VARCHAR2(30 CHAR) NOT NULL,
      SET_ON      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      SET_BY      VARCHAR2(100 CHAR),
      CLEARED_ON  TIMESTAMP,
      CLEARED_BY  VARCHAR2(100 CHAR),
      NOTES       VARCHAR2(400 CHAR),
      CONSTRAINT pk_oc_tsdf PRIMARY KEY (TS_ENTRY_ID, FLAG_CODE),
      CONSTRAINT fk_oc_tsdf_en FOREIGN KEY (TS_ENTRY_ID)
        REFERENCES oc_ts_entry(ts_entry_id) ON DELETE CASCADE,
      CONSTRAINT fk_oc_tsdf_fl FOREIGN KEY (FLAG_CODE) REFERENCES oc_ts_flag_def
    )~', 'OC_TS_DAY_FLAG');
END;
/

PROMPT ============================================================
PROMPT [7/7] Backfill from the current model, then verify
PROMPT ============================================================

DECLARE
  v_w NUMBER; v_e NUMBER; v_f NUMBER := 0;
  PROCEDURE raise_flag(p_code VARCHAR2, p_where VARCHAR2) IS
    v_n NUMBER;
  BEGIN
    EXECUTE IMMEDIATE
      'INSERT INTO oc_ts_week_flag (ts_week_id, flag_code, set_on, set_by, notes) '
      || 'SELECT w.ts_week_id, :1, NVL(w.updated_on, w.created_on), ''BACKFILL'', '
      || '''carried over from the revision-2 boolean'' '
      || '  FROM oc_ts_week w WHERE ' || p_where
      || '   AND NOT EXISTS (SELECT 1 FROM oc_ts_week_flag f '
      || '        WHERE f.ts_week_id = w.ts_week_id AND f.flag_code = :2)'
      USING p_code, p_code;
    v_n := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE(RPAD('flag ' || p_code, 34) || v_n);
  END;
BEGIN
  -- Week: the mapping table from the plan. Every current value lands
  -- somewhere and nothing is invented.
  UPDATE oc_ts_week SET
    submission_status = CASE
        WHEN week_status = 'Not yet submitted' THEN 'NotYetSubmitted'
        WHEN week_status = 'Defaulted' AND NVL(defaulted_by,'EMPLOYEE') = 'EMPLOYEE'
             THEN 'Defaulted'
        WHEN late_submission_flag = 'Y' THEN 'LateSubmission'
        ELSE 'Submitted' END,
    approval_status = CASE
        WHEN week_status IN ('Approved','Overridden and approved') THEN 'Approved'
        WHEN week_status = 'Rejected' THEN 'Rejected'
        WHEN week_status = 'Defaulted' AND defaulted_by = 'MANAGER'
             THEN 'ManagerDefaulted'
        ELSE 'Pending' END
   WHERE submission_status IS NULL OR approval_status IS NULL;
  v_w := SQL%ROWCOUNT;

  -- Day: DAY_STATUS was always the approval axis. The submission axis is
  -- inherited from the week, because days have never had one of their own.
  UPDATE oc_ts_entry e SET
    approval_status = CASE NVL(e.day_status,'Pending')
                        WHEN 'Approved' THEN 'Approved'
                        WHEN 'Rejected' THEN 'Rejected'
                        ELSE 'Pending' END,
    submission_status = (SELECT w.submission_status FROM oc_ts_week w
                          WHERE w.ts_week_id = e.ts_week_id)
   WHERE e.submission_status IS NULL OR e.approval_status IS NULL;
  v_e := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(RPAD('weeks backfilled', 34) || v_w);
  DBMS_OUTPUT.PUT_LINE(RPAD('entries backfilled', 34) || v_e);

  -- Flags. Advance closure and reversal both become Adjusted (13-Aug), so
  -- three source columns feed one flag and the MERGE-style guard stops the
  -- second and third inserting a duplicate.
  raise_flag('Overridden',       q'~w.overridden_flag = 'Y'~');
  raise_flag('Defaulted',        q'~w.defaulted_flag = 'Y'~');
  raise_flag('LateSubmission',   q'~w.late_submission_flag = 'Y'~');
  raise_flag('ManagerDefaulted', q'~w.week_status = 'Defaulted' AND w.defaulted_by = 'MANAGER'~');
  raise_flag('Adjusted',         q'~w.has_adjustment_flag = 'Y'~');
  raise_flag('Adjusted',         q'~w.advance_closure_flag = 'Y'~');
  raise_flag('Adjusted',         q'~w.has_reversal_flag = 'Y'~');
  COMMIT;
END;
/

PROMPT
PROMPT --- the two axes against the old column -----------------------
COLUMN week_status FORMAT A26
COLUMN submission  FORMAT A18
COLUMN approval    FORMAT A18
SELECT week_status, submission_status AS submission,
       approval_status AS approval, COUNT(*) AS weeks
  FROM oc_ts_week
 GROUP BY week_status, submission_status, approval_status
 ORDER BY week_status;

PROMPT
PROMPT --- flags now carried, with the timestamp they never had ------
COLUMN flag_code FORMAT A20
SELECT flag_code, COUNT(*) AS weeks,
       TO_CHAR(MIN(set_on),'DD-MON HH24:MI') AS earliest
  FROM oc_ts_week_flag GROUP BY flag_code ORDER BY flag_code;

PROMPT
PROMPT --- the rules, as data ---------------------------------------
COLUMN event_code FORMAT A16
COLUMN from_s FORMAT A16
COLUMN to_s   FORMAT A16
COLUMN to_a   FORMAT A16
COLUMN rf     FORMAT A16
SELECT event_code, match_order, from_submission AS from_s, period_state,
       require_flag, to_submission AS to_s, to_approval AS to_a, raise_flag AS rf
  FROM oc_ts_transition WHERE active_flag = 'Y'
 ORDER BY event_code, match_order;

PROMPT
PROMPT PHASE 1 IS ADDITIVE. WEEK_STATUS, DAY_STATUS, DEFAULTED_BY and the six
PROMPT boolean flags are all still written by the package and still correct --
PROMPT nothing reading them has changed. Phase 2 moves the rules onto
PROMPT OC_TS_TRANSITION; only after that is proven should anything be dropped.
PROMPT
PROMPT Adding a status, a flag or a rule in V5 is an INSERT into one of three
PROMPT tables. That is the whole reason for this shape.
