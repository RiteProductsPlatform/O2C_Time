--==============================================================
-- time/39_engine_prereqs.sql
-- O2C Timesheet Module — what phase 2b needs before it can land
--
-- Four things, three of them found by actually running 37 and 38 rather than
-- by reading them. Worth recording how each showed up.
--
-- 1. THE AXIS COLUMNS ARE NULL ON EVERY WEEK. 37's verification block printed
--    blank SUBMISSION and APPROVAL for all 1,340 weeks.
--
--    27 added the columns with no DEFAULT and backfilled the rows that existed
--    at the time. The period migration (30-36) then REBUILT the weeks, and the
--    new rows came into existence NULL. Nothing was wrong with the backfill;
--    it simply ran against a set of rows that no longer exists.
--
--    This is a hard blocker, not untidiness. The WeeklyCutoff rule matches on
--    FROM_SUBMISSION = 'NotYetSubmitted', and NULL never equals anything, so
--    the cut-off job would raise -20034 on every week it touched. The engine
--    fails loudly rather than silently, which is the design working -- but it
--    fails on all of them.
--
-- 2. A STANDALONE PROCEDURE CANNOT BE OVERLOADED. 37 [4/5] created a 3-argument
--    wrapper with the same name as the 6-argument engine. Only PACKAGE members
--    overload; at schema level CREATE OR REPLACE simply REPLACED the engine,
--    and the wrapper's call to itself with 6 arguments failed PLS-00306.
--
--    38 happened to recreate the 6-argument version afterwards, so the engine
--    is intact -- but the wrapper does not exist, and anything written against
--    it would fail at compile time. Renamed here.
--
--    Same family as the traps in CLAUDE.md section 5: a PL/SQL feature reached
--    for on the wrong side of a boundary. Overloading needs a package.
--
-- 3. THE TIMING FUNCTION NEEDS AN AS-OF DATE. run_weekly_defaulting takes
--    p_as_of and phase 2b routes it through oc_time_week_timing, which reads
--    SYSDATE. Today every caller passes SYSDATE so the two agree; replay the
--    job with a past date and it would evaluate against today and default
--    everything in sight. Fixed before the rewire depends on it, not after.
--
-- 4. AND ONE THING TO RAISE, NOT FIX -- see the notes at the end.
--
-- Idempotent. Depends on: time/27, time/37, time/38
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
PROMPT [1/5] Backfill the two axes from WEEK_STATUS
PROMPT ============================================================

-- Reading revision 2 back out into V4. This is the inverse of
-- oc_time_derive_week_status, and the two must stay consistent: derive maps
-- (submission, approval) -> week_status, this maps it back. Where the round
-- trip loses information it is because revision 2 genuinely could not hold it.
DECLARE
  v_w NUMBER := 0;
  v_e NUMBER := 0;
BEGIN
  UPDATE oc_ts_week
     SET submission_status = CASE
           -- Rejection sends the week back to the employee as NOT YET
           -- SUBMITTED -- confirmed 13-Aug. The rejection lives on the
           -- approval axis; the submission axis genuinely resets.
           WHEN week_status = 'Rejected'          THEN 'NotYetSubmitted'
           WHEN week_status = 'Not yet submitted' THEN 'NotYetSubmitted'
           -- An EMPLOYEE default is a submission-axis fact: they missed their
           -- own cut-off. A MANAGER default is not -- the employee submitted
           -- perfectly well and the manager did not act, so the submission
           -- axis still reads Submitted. This split is exactly why there are
           -- two columns, and DEFAULTED_BY is what preserved it.
           WHEN week_status = 'Defaulted'
                AND NVL(defaulted_by,'EMPLOYEE') = 'EMPLOYEE' THEN 'Defaulted'
           WHEN week_status = 'Defaulted'         THEN 'Submitted'
           WHEN late_submission_flag = 'Y'        THEN 'LateSubmission'
           ELSE 'Submitted'
         END,
         approval_status = CASE
           WHEN week_status IN ('Approved','Overridden and approved','Closed')
                                                  THEN 'Approved'
           WHEN week_status = 'Rejected'          THEN 'Rejected'
           WHEN week_status = 'Defaulted'
                AND defaulted_by = 'MANAGER'      THEN 'ManagerDefaulted'
           ELSE 'Pending'
         END
   WHERE submission_status IS NULL OR approval_status IS NULL;
  v_w := SQL%ROWCOUNT;

  -- The days receive the week's, which is the whole day/week rule: approval is
  -- weekly, so a day cannot hold a status its week does not.
  UPDATE oc_ts_entry e
     SET (submission_status, approval_status) =
         (SELECT w.submission_status, w.approval_status
            FROM oc_ts_week w WHERE w.ts_week_id = e.ts_week_id)
   WHERE e.submission_status IS NULL OR e.approval_status IS NULL;
  v_e := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_w || ' week(s), ' || v_e || ' entry row(s) backfilled');
END;
/

PROMPT ============================================================
PROMPT [2/5] DEFAULTs, so a rebuild can never reintroduce NULL
PROMPT ============================================================

-- The backfill above fixes today. This is what stops it happening again:
-- populate_daily inserts without naming these columns, so without a DEFAULT
-- every newly built week starts NULL -- which is exactly how 1,340 weeks got
-- here after the period migration rebuilt them.
--
-- A DEFAULT applies only to INSERTs that omit the column, so this is safe on
-- existing rows and changes nothing already written.
DECLARE
  PROCEDURE defcol(p_tab VARCHAR2, p_col VARCHAR2, p_val VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_tab || ' MODIFY (' || p_col
                   || ' DEFAULT ''' || p_val || ''')';
    DBMS_OUTPUT.PUT_LINE('  ' || p_tab || '.' || p_col || ' DEFAULT ' || p_val);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  ' || p_tab || '.' || p_col || ': '
                      || SUBSTR(SQLERRM, 1, 90));
  END;
BEGIN
  defcol('oc_ts_week',  'SUBMISSION_STATUS', 'NotYetSubmitted');
  defcol('oc_ts_week',  'APPROVAL_STATUS',   'Pending');
  defcol('oc_ts_entry', 'SUBMISSION_STATUS', 'NotYetSubmitted');
  defcol('oc_ts_entry', 'APPROVAL_STATUS',   'Pending');
END;
/

PROMPT ============================================================
PROMPT [3/5] OC_TIME_WEEK_TIMING gains an as-of date
PROMPT ============================================================

-- p_as_of DEFAULT NULL means every existing one-argument call still compiles
-- and still means "now". Only the defaulting job passes the second argument.
CREATE OR REPLACE FUNCTION oc_time_week_timing(
  p_ts_week_id IN NUMBER,
  p_as_of      IN DATE DEFAULT NULL) RETURN VARCHAR2
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

  -- NEXT_DAY gives the first named day STRICTLY AFTER the date: a week ending
  -- Sunday is due the following Monday, not the Monday inside it.
  --
  -- Hours AND minutes. run_weekly_defaulting reads the hour alone, so at a
  -- 17:30 cut-off it would default weeks at 17:00 while the Submit rules still
  -- called them on time -- Defaulted and WithinCutoff at once. Phase 2b routes
  -- the job through here so there is one answer, computed once.
  v_due := NEXT_DAY(v_end, NVL(v_day, 'MONDAY'))
         + NVL(TO_NUMBER(SUBSTR(v_time, 1, 2)), 17) / 24
         + NVL(TO_NUMBER(SUBSTR(v_time, 4, 2)),  0) / 1440;

  RETURN CASE WHEN NVL(p_as_of, SYSDATE) > v_due
              THEN 'PastCutoff' ELSE 'WithinCutoff' END;
EXCEPTION WHEN NO_DATA_FOUND THEN
  -- A week that has not started still returns WithinCutoff: a submission
  -- cannot be late before its deadline exists.
  RETURN 'WithinCutoff';
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] The wrapper, under a name of its own
PROMPT ============================================================

-- Was oc_time_apply_event with 3 arguments, which at schema level does not
-- overload the 6-argument engine -- it replaces it. Renamed so both exist.
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
PROMPT [5/5] Verification
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
PROMPT No blanks in SUBMISSION or APPROVAL. A blank here means the backfill
PROMPT missed a WEEK_STATUS value, and the cut-off job will raise -20034 on
PROMPT every one of those weeks.

SELECT COUNT(*) AS still_null FROM oc_ts_week
 WHERE submission_status IS NULL OR approval_status IS NULL;

PROMPT
PROMPT --- both objects present, neither having replaced the other
COLUMN object_name FORMAT A26
SELECT object_name, status FROM user_objects
 WHERE object_name IN ('OC_TIME_APPLY_EVENT','OC_TIME_FIRE_EVENT',
                       'OC_TIME_WEEK_TIMING','OC_TIME_DERIVE_WEEK_STATUS')
 ORDER BY object_name;

PROMPT
PROMPT ============================================================
PROMPT TO RAISE, NOT FIXED HERE
PROMPT ============================================================
PROMPT
PROMPT (a) AUG-2026 is the only Open period and has NO WEEKS. JUL and SEP hold
PROMPT     670 each; August holds none. Nobody can record time in the only
PROMPT     month that accepts it. The monthly OIC run populates it -- until it
PROMPT     does, every screen is correctly empty and it is not a fault here.
PROMPT
PROMPT (b) JUN-2026's delivery cut-off reads 01-SEP-26, two months after the
PROMPT     month it governs, and identical to August's. A June timesheet would
PROMPT     stay editable until September. This is upstream data in
PROMPT     o2c_dev.oc_mec_period, which is authoritative -- so it is theirs to
PROMPT     correct, not ours to override. Worth asking about before UAT.
