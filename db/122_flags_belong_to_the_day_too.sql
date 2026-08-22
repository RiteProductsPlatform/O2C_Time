--==============================================================
-- time/122_flags_belong_to_the_day_too.sql
-- O2C Timesheet Module -- start writing OC_TS_DAY_FLAG, which db/27 created
-- and nothing has ever filled
--
-- Asked 22-Aug:
--
--   "I think we need to maintain the flag daywise, because if there is a WBS
--    change then it may be a few days in a week and we might need to flag
--    those."
--
-- -- THE TABLE IS ALREADY THERE ---------------------------------
--
-- db/27 created OC_TS_DAY_FLAG beside OC_TS_WEEK_FLAG: same columns, keyed on
-- TS_ENTRY_ID instead of TS_WEEK_ID, same foreign key to OC_TS_FLAG_DEF. And
-- OC_TS_FLAG_DEF.SCOPE_LEVEL has always admitted 'WEEK', 'DAY' and 'BOTH'.
--
-- So the two-level model was designed and then only half built: the week half
-- got oc_time_raise_week_flag and eleven callers, and the day half got a table
-- and nothing else. The only reference to it anywhere in db/ is db/35 wiping
-- it. This is a completion, not a change of direction.
--
-- -- ONE CORRECTION TO THE REASONING, WORTH RECORDING ----------
--
-- Accrual is NOT currently losing the day detail on a WBS change. A retro
-- reallocation writes day-wise Reversal(-) and Adjustment(+) rows into
-- OC_TS_ENTRY carrying the original WORK DATE, and run_accrual_top_up reads
-- those per entry. The granularity is already in the entries.
--
-- What the day flag adds is that a person can SEE which day moved -- on the
-- grid, in the annexure, in an audit -- without reconstructing it from
-- offsetting pairs. That is reason enough. But nobody should build this
-- believing accrual is currently blind, because it is not, and the next
-- person to read that assumption might "fix" something that works.
--
-- -- WHAT RAISES WHAT ------------------------------------------
--
--   Overridden        on the entry a manager corrected  (override_approve)
--   Adjusted          on both halves of a retro pair    (approve_adjustment)
--   ShortOfStandard   on each day that does not add up  (check_short_week)
--
-- The WEEK keeps its flag in every case. The week answers "is there anything
-- to look at here", which is what a list of weeks needs; the day answers
-- "which one", which is what the person who opened that week needs. Dropping
-- either would make one of those screens reconstruct the answer.
--
-- Idempotent. Depends on: time/09, 27, 37, 112.
-- RUN db/09 AFTER THIS: override_approve, approve_adjustment and
-- oc_time_check_short_week are edited there to call it.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/5] Confirm the table exists and is empty
PROMPT ============================================================

DECLARE
  v_t NUMBER; v_r NUMBER := 0;
BEGIN
  SELECT COUNT(*) INTO v_t FROM user_tables WHERE table_name = 'OC_TS_DAY_FLAG';
  IF v_t = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'OC_TS_DAY_FLAG is missing - db/27 has not been run.');
  END IF;
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM oc_ts_day_flag' INTO v_r;
  DBMS_OUTPUT.PUT_LINE('  OC_TS_DAY_FLAG exists, ' || v_r || ' row(s).');
  DBMS_OUTPUT.PUT_LINE('  Zero is expected: nothing has ever written to it.');
END;
/

PROMPT ============================================================
PROMPT [2/5] The scopes each flag is allowed at
PROMPT ============================================================

-- A flag is only raised at a level its dictionary row permits, so this is the
-- switch that turns the day half on.
--
-- Measured on the pod: only ONE row actually needed widening -- db/27 seeded
-- most of the dictionary as BOTH already, which is more evidence that the
-- day half was intended from the start and simply never wired up.
--
-- Widening the dictionary does NOT make a flag appear at day level. Nothing is
-- raised until something calls oc_time_raise_day_flag, and only three callers
-- do. Defaulted, LateSubmission and ManagerDefaulted stay week-only in
-- PRACTICE for a reason worth keeping: submission is a WEEK act -- there is no
-- day-level submit -- so no single day was late or defaulted on its own.
UPDATE oc_ts_flag_def
   SET scope_level = 'BOTH'
 WHERE flag_code IN ('Overridden','Adjusted','ShortOfStandard')
   AND scope_level <> 'BOTH';

BEGIN
  DBMS_OUTPUT.PUT_LINE('  flag definitions widened: ' || SQL%ROWCOUNT);
  COMMIT;
END;
/

COLUMN flag_code FORMAT A20
COLUMN label     FORMAT A26
SELECT flag_code, label, scope_level, active_flag
  FROM oc_ts_flag_def
 ORDER BY sort_order;

PROMPT ============================================================
PROMPT [3/5] OC_TIME_RAISE_DAY_FLAG
PROMPT ============================================================

-- Deliberately the same shape as oc_time_raise_week_flag: raise is a MERGE so
-- re-raising does not move SET_ON, and clearing stamps CLEARED_ON rather than
-- deleting. Flags are never deleted -- a week that went short and was put
-- right should still show that it happened.
--
-- REFUSES A FLAG THE DICTIONARY DOES NOT ALLOW AT DAY LEVEL, by name. Silently
-- ignoring it would leave somebody looking for a chip that was never going to
-- appear, and the FK only checks the code exists, not that DAY is permitted
-- for it.
CREATE OR REPLACE PROCEDURE oc_time_raise_day_flag(
  p_ts_entry_id IN NUMBER,
  p_flag        IN VARCHAR2,
  p_actor       IN VARCHAR2 DEFAULT 'SYSTEM',
  p_notes       IN VARCHAR2 DEFAULT NULL)
IS
  v_scope oc_ts_flag_def.scope_level%TYPE;
BEGIN
  IF p_flag IS NULL OR p_ts_entry_id IS NULL THEN RETURN; END IF;

  BEGIN
    SELECT scope_level INTO v_scope
      FROM oc_ts_flag_def WHERE flag_code = p_flag;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20031,
      'No such flag: ' || p_flag || '.');
  END;

  IF v_scope NOT IN ('DAY','BOTH') THEN
    RAISE_APPLICATION_ERROR(-20031,
      p_flag || ' is a ' || v_scope || '-level flag and cannot be raised on a '
      || 'day. Widen OC_TS_FLAG_DEF.SCOPE_LEVEL first if that is intended.');
  END IF;

  MERGE INTO oc_ts_day_flag t
  USING (SELECT p_ts_entry_id AS e, p_flag AS f FROM dual) s
     ON (t.ts_entry_id = s.e AND t.flag_code = s.f)
   WHEN MATCHED THEN UPDATE
        -- Re-raising a live flag changes nothing: SET_ON is when it FIRST
        -- became true. A flag that was cleared and comes back is a new
        -- occurrence, so that one does move.
        SET cleared_on = NULL, cleared_by = NULL,
            set_on     = CASE WHEN t.cleared_on IS NULL THEN t.set_on
                              ELSE SYSTIMESTAMP END,
            set_by     = CASE WHEN t.cleared_on IS NULL THEN t.set_by
                              ELSE p_actor END,
            notes      = NVL(p_notes, t.notes)
   WHEN NOT MATCHED THEN
        INSERT (ts_entry_id, flag_code, set_on, set_by, notes)
        VALUES (p_ts_entry_id, p_flag, SYSTIMESTAMP, p_actor, p_notes);
END oc_time_raise_day_flag;
/

SHOW ERRORS

CREATE OR REPLACE PROCEDURE oc_time_clear_day_flag(
  p_ts_entry_id IN NUMBER,
  p_flag        IN VARCHAR2,
  p_actor       IN VARCHAR2 DEFAULT 'SYSTEM')
IS
BEGIN
  UPDATE oc_ts_day_flag
     SET cleared_on = SYSTIMESTAMP, cleared_by = p_actor
   WHERE ts_entry_id = p_ts_entry_id
     AND flag_code   = p_flag
     AND cleared_on IS NULL;
END oc_time_clear_day_flag;
/

SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] The live flags, day by day
PROMPT ============================================================

-- What the grid will render from. Cleared flags are excluded here and kept in
-- the table, so history survives without cluttering the screen.
CREATE OR REPLACE VIEW v_oc_ts_day_flags AS
SELECT f.ts_entry_id,
       e.ts_week_id,
       TO_CHAR(e.entry_date,'YYYY-MM-DD') AS entry_date,
       f.flag_code,
       d.label,
       d.description,
       f.set_on,
       f.set_by,
       f.notes
  FROM oc_ts_day_flag  f
  JOIN oc_ts_flag_def  d ON d.flag_code = f.flag_code
  JOIN oc_ts_entry     e ON e.ts_entry_id = f.ts_entry_id
 WHERE f.cleared_on IS NULL
   AND NVL(d.active_flag,'Y') = 'Y';

SHOW ERRORS

-- One row per entry, flags folded into a single cell, so the day grid can add
-- a column without a second call. LISTAGG is safe here: six flags exist and an
-- entry can carry at most that many.
CREATE OR REPLACE VIEW v_oc_ts_day_flag_roll AS
SELECT ts_entry_id,
       COUNT(*) AS flag_count,
       LISTAGG(flag_code, ',') WITHIN GROUP (ORDER BY flag_code) AS flag_codes,
       LISTAGG(label, ', ')    WITHIN GROUP (ORDER BY flag_code) AS flag_labels
  FROM v_oc_ts_day_flags
 GROUP BY ts_entry_id;

SHOW ERRORS

PROMPT ============================================================
PROMPT [5/5] Put the flags on the day feed
PROMPT ============================================================

-- V_OC_TS_DAY_DETAIL is what GET days/:tsWeekId returns and what the Approval
-- Detail grid binds to.
--
-- THE COLUMNS DO NOT REACH ANYTHING BY THEMSELVES. Both day handlers and the
-- CSV export enumerate their select lists rather than using *, so a column
-- added here is invisible until each one names it. Measured: the view had the
-- columns and the feed returned none of them.
--
-- ords/12 names them in the two GET handlers. THE CSV EXPORT (ACT-018) IS
-- DELIBERATELY LEFT ALONE -- its column list is a contract somebody may be
-- parsing, and widening it is a decision rather than a consequence. So the
-- screen shows flags the download does not, and that is a known difference,
-- not an oversight.
--
-- LEFT JOIN, so an unflagged day is a null and not a missing row.
--
-- USER_VIEWS.TEXT IS A **LONG**, NOT A CLOB. Declaring the local as CLOB
-- raises ORA-00932 "expected CLOB got LONG", which reads like the two operands
-- disagree and invites a cast. There is no cast: PL/SQL will assign a LONG to
-- a VARCHAR2 implicitly and to nothing else. CLAUDE.md section 5 records this
-- for USER_IND_EXPRESSIONS.COLUMN_EXPRESSION and it is the same rule here --
-- written down, and walked into anyway.
--
-- 32760 is the implicit-assignment ceiling. A view source past it would
-- truncate, and a truncated source is a syntax error on the CREATE rather than
-- a silently wrong view -- loud, which is what you want. The explicit check
-- below makes it loud EARLIER and says why.
DECLARE
  v_src VARCHAR2(32760);
BEGIN
  SELECT text INTO v_src
    FROM user_views WHERE view_name = 'V_OC_TS_DAY_DETAIL';

  IF LENGTH(v_src) > 32000 THEN
    RAISE_APPLICATION_ERROR(-20032,
      'V_OC_TS_DAY_DETAIL is ' || LENGTH(v_src) || ' characters, too close to '
      || 'the 32760 LONG-to-VARCHAR2 ceiling to wrap safely. Add the flag '
      || 'columns to db/97 directly instead.');
  END IF;

  IF INSTR(UPPER(v_src), 'FLAG_CODES') > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Day feed already carries the flags - skipped.');
  ELSE
    EXECUTE IMMEDIATE
      'CREATE OR REPLACE VIEW v_oc_ts_day_detail AS '
      || 'SELECT d.*, NVL(r.flag_count,0) AS flag_count, '
      || '       r.flag_codes, r.flag_labels '
      || '  FROM (' || v_src || ') d '
      || '  LEFT JOIN v_oc_ts_day_flag_roll r ON r.ts_entry_id = d.ts_entry_id';
    DBMS_OUTPUT.PUT_LINE('  Day feed now carries flag_count, flag_codes, '
      || 'flag_labels.');
  END IF;
END;
/

COLUMN flag_codes FORMAT A34
SELECT ts_entry_id, entry_date, hours, flag_count, flag_codes
  FROM v_oc_ts_day_detail
 WHERE flag_count > 0
 ORDER BY entry_date
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT No rows yet is correct - nothing has raised a day flag until db/09 is
PROMPT recompiled. Correct a day afterwards and it should appear here.
PROMPT
PROMPT NEXT: db/09_pkg_oc_time.sql
