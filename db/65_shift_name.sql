--==============================================================
-- time/65_shift_name.sql
-- O2C Timesheet Module — the shift strip was showing a surrogate key
--
-- PAGE-001's Shift row read
--
--     Shift (per day, from HCM, read-only)      300000265863352
--
-- against Sunday, and a dash everywhere else. That number is
-- ZMM_SR_SCHEDULE_DTLS.SHIFT_ID, which the WORKER_SHIFTS extract emitted
-- directly: TO_CHAR(MAX(d.shift_id)) AS shift_code. It resolves to "8 hours a
-- day", and nothing in the chain ever looked it up.
--
-- WHY IT LOOKED PLAUSIBLE FOR SO LONG
--   FLD-008 is display-only, so a wrong value changes no hours and breaks no
--   rule. The strip rendered, the roster logic worked off IS_WORKING_DAY rather
--   than the code, and a 15-digit id in a column called SHIFT_CODE reads as a
--   code somebody chose. It is visible on the screen and was reported by
--   somebody looking at it, not by any check.
--
-- THE DICTIONARY IS ZMM_SR_SHIFTS_VL, NOT HTS_SHIFTS_VL. This matters and is
-- not guessable: the SHIFTS extract reads HTS_SHIFTS_VL (Workforce Scheduling)
-- and that table does not contain this id at all -- the per-worker roster comes
-- from the ZMM_SR_* work-schedule family, which keeps its own shift list. Two
-- shift dictionaries, one id space each. Joining the wrong one returns nothing
-- and would have looked like missing data.
--
-- SHIFT_CODE IS WIDENED FROM 20 TO 60 CHARACTERS, because Fusion's names do not
-- fit: of the 76 shifts actually referenced by a schedule, 39 are longer than
-- 20 characters and the longest is 31 ("US Retail 30 Hour Evening Shift").
-- SHORT_TXT exists and would fit, but only 32 of the 76 have one, so it cannot
-- be the source on its own. Truncating instead would put "8 Hour Shift - Facil"
-- on a screen, which is worse than the number it replaces.
--
-- Widening is additive: no data changes, no constraint moves, and every
-- existing value stays valid.
--
-- Idempotent -- re-running finds the columns already wide and says so.
-- Depends on: time/01, 03. Deploy the WORKER_SHIFTS model afterwards
-- (python integration/bip/run_extract.py --deploy WORKER_SHIFTS) or the pod
-- keeps sending ids.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_CALENDAR';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] What the strip holds today
PROMPT ============================================================

COLUMN shift_code FORMAT A22
SELECT NVL(shift_code,'(null)') AS shift_code,
       COUNT(*) AS days,
       -- A shift code that is all digits is an id, not a code. Reported rather
       -- than assumed so the fix can be seen to have worked.
       CASE WHEN TRIM(TRANSLATE(shift_code,'0123456789',' ')) IS NULL
             AND shift_code IS NOT NULL THEN 'SURROGATE ID'
            ELSE 'name' END AS looks_like
  FROM oc_time_calendar
 WHERE layer = 'SHIFT'
 GROUP BY shift_code
 ORDER BY 2 DESC
 FETCH FIRST 12 ROWS ONLY;

PROMPT ============================================================
PROMPT [2/3] Widen SHIFT_CODE to hold a name
PROMPT ============================================================

DECLARE
  PROCEDURE widen(p_table VARCHAR2) IS
    v_len NUMBER;
  BEGIN
    SELECT char_length INTO v_len FROM user_tab_columns
     WHERE table_name = p_table AND column_name = 'SHIFT_CODE';

    IF v_len >= 60 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_table, 20) || ' already ' || v_len || ' - skipped');
      RETURN;
    END IF;

    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table
                   || ' MODIFY (shift_code VARCHAR2(60 CHAR))';
    DBMS_OUTPUT.PUT_LINE(RPAD(p_table, 20) || ' ' || v_len || ' -> 60');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_table, 20) || ' has no SHIFT_CODE - skipped');
    WHEN OTHERS THEN
      -- ORA-01441 would mean existing data is longer than the new size, which
      -- cannot happen when widening. Anything else is worth seeing.
      DBMS_OUTPUT.PUT_LINE(RPAD(p_table, 20) || ' FAILED - '
                           || SUBSTR(SQLERRM, 1, 110));
  END widen;
BEGIN
  widen('OC_TIME_CALENDAR');
  widen('OC_TS_ENTRY');
END;
/

PROMPT ============================================================
PROMPT [3/3] Confirm, and what is left to do
PROMPT ============================================================

COLUMN table_name FORMAT A22
SELECT table_name, char_length AS shift_code_len
  FROM user_tab_columns
 WHERE column_name = 'SHIFT_CODE'
   AND table_name IN ('OC_TIME_CALENDAR','OC_TS_ENTRY')
 ORDER BY table_name;

PROMPT
PROMPT The column is ready; the DATA is still ids until the feed is redeployed
PROMPT and re-run. The extract change is local until then -- OIC executes the
PROMPT .xdm in the Fusion catalog, not integration/bip/extracts.py:
PROMPT
PROMPT   python integration/bip/run_extract.py --deploy WORKER_SHIFTS
PROMPT
PROMPT then re-run the sync. Section [1] above should then read names, and
PROMPT LOOKS_LIKE should say 'name' on every row.
PROMPT
PROMPT Existing OC_TS_ENTRY rows keep the id they were seeded with -- the value
PROMPT is display-only and populate does not revisit a seeded cell, so they
PROMPT correct themselves as new days are built rather than needing a sweep.
