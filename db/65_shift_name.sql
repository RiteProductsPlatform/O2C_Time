--==============================================================
-- time/65_shift_name.sql
-- O2C Timesheet Module — the roster is a PATTERN, at week grain
--
-- PAGE-001's day strip read "300000265863352" against Sunday and a dash
-- elsewhere. That is ZMM_SR_SCHEDULE_DTLS.SHIFT_ID, which WORKER_SHIFTS emitted
-- raw. Resolving it to the shift NAME ("8 hours a day") would still have been
-- the wrong answer, and this is the correction that matters:
--
--   A SHIFT is the standard hours of a day, and varies by location. The
--   timesheet already carries that as OC_TIME_WORKER.STD_HOURS_PER_DAY, so a
--   shift name only restates it -- "8 hours a day" beside a column already
--   showing 8.00.
--
--   A PATTERN is which days of the week somebody works. That is the fact the
--   grid is actually describing when Friday reads 0.00 for one person and 8.00
--   for another, and it is what "O2C Sunday to Thursday" says.
--
-- IT IS ALSO THE WRONG GRAIN. A pattern belongs to the WEEK. Repeating it down
-- a seven-cell day strip states the same thing seven times and invites the
-- reading that it could differ per day. Shown once, at week level.
--
-- SO PATTERN_NAME IS A NEW COLUMN, not SHIFT_CODE reused. SHIFT_CODE stays for
-- what it means -- the SHIFTS reference layer still loads real shift codes into
-- it -- and overloading it with a pattern would leave the next person reading
-- "shift" and seeing a weekly shape. VARCHAR2(240), because a rotating schedule
-- LISTAGGs its patterns and the longest on this pod is 111 characters:
-- "TWP-Monday to Friday - 08:00 AM - 05:00 PM - 44 Hours / TWP-Monday to
-- Thursday - 08:00 AM - 05:00 PM - 36 Hours". Four distinct values exceed 60,
-- so the 60 this file used to set would have failed the load with ORA-12899.
--
-- Idempotent. Depends on: time/01, 03, 08.
-- AFTER this, deploy and re-sync or the column stays empty:
--   python integration/bip/run_extract.py --deploy WORKER_SHIFTS
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
PROMPT [1/4] What the SHIFT layer holds today
PROMPT ============================================================

COLUMN shift_code FORMAT A26
SELECT NVL(shift_code,'(null)') AS shift_code,
       COUNT(*) AS days,
       -- All digits is a surrogate key, not a code anybody chose.
       CASE WHEN shift_code IS NOT NULL
             AND TRIM(TRANSLATE(shift_code,'0123456789',' ')) IS NULL
            THEN 'SURROGATE ID' ELSE 'text' END AS looks_like
  FROM oc_time_calendar
 WHERE layer = 'SHIFT'
 GROUP BY shift_code
 ORDER BY 2 DESC
 FETCH FIRST 10 ROWS ONLY;

PROMPT ============================================================
PROMPT [2/4] PATTERN_NAME
PROMPT ============================================================

DECLARE
  PROCEDURE add_col(p_table VARCHAR2) IS
    v_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_n FROM user_tab_columns
     WHERE table_name = p_table AND column_name = 'PATTERN_NAME';
    IF v_n > 0 THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(p_table,20) || ' already has PATTERN_NAME');
      RETURN;
    END IF;
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table
                   || ' ADD (pattern_name VARCHAR2(240 CHAR))';
    DBMS_OUTPUT.PUT_LINE(RPAD(p_table,20) || ' PATTERN_NAME added');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_table,20) || ' FAILED - '
                         || SUBSTR(SQLERRM,1,110));
  END add_col;
BEGIN
  add_col('OC_TIME_CALENDAR');
  add_col('OC_TS_ENTRY');
END;
/

PROMPT
PROMPT --- clear the surrogate ids out of SHIFT_CODE on the roster layer
DECLARE
  v_n NUMBER;
BEGIN
  -- Only where it is all digits, and only on the SHIFT layer. A real shift code
  -- somebody loaded deliberately is left alone, and so is every other layer.
  UPDATE oc_time_calendar
     SET shift_code = NULL,
         updated_by = 'PATTERN_MIGRATION',
         updated_on = SYSTIMESTAMP
   WHERE layer = 'SHIFT'
     AND shift_code IS NOT NULL
     AND TRIM(TRANSLATE(shift_code,'0123456789',' ')) IS NULL;
  v_n := SQL%ROWCOUNT;

  UPDATE oc_ts_entry
     SET shift_code = NULL,
         updated_by = 'PATTERN_MIGRATION',
         updated_on = SYSTIMESTAMP
   WHERE shift_code IS NOT NULL
     AND TRIM(TRANSLATE(shift_code,'0123456789',' ')) IS NULL;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' calendar row(s) and ' || SQL%ROWCOUNT
    || ' entry row(s) cleared of surrogate ids');
END;
/

PROMPT ============================================================
PROMPT [3/4] V_OC_TS_WEEK_PATTERN — one row per week, one pattern
PROMPT ============================================================

-- The week-grain answer, so no caller has to aggregate seven day rows to
-- discover a fact that was never per-day. LISTAGG guards the case where the
-- roster genuinely changes mid-week: two patterns across one week is real (a
-- schedule assignment can end on a Wednesday) and naming both beats picking.
CREATE OR REPLACE VIEW v_oc_ts_week_pattern AS
SELECT w.ts_week_id,
       w.employee_id,
       w.period_id,
       LISTAGG(DISTINCT c.pattern_name, ' / ')
               WITHIN GROUP (ORDER BY c.pattern_name) AS pattern_name,
       COUNT(DISTINCT c.pattern_name)                 AS pattern_count,
       SUM(CASE WHEN c.is_working_day = 'Y' THEN 1 ELSE 0 END) AS rostered_days
  FROM oc_ts_week w
  JOIN oc_time_calendar c
    ON c.layer     = 'SHIFT'
   AND c.scope_key = w.employee_id
   AND c.cal_date BETWEEN w.week_start AND w.week_end
 WHERE c.pattern_name IS NOT NULL
 GROUP BY w.ts_week_id, w.employee_id, w.period_id;

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

SELECT COUNT(*) AS surrogate_ids_left
  FROM oc_time_calendar
 WHERE layer = 'SHIFT'
   AND shift_code IS NOT NULL
   AND TRIM(TRANSLATE(shift_code,'0123456789',' ')) IS NULL;

COLUMN table_name FORMAT A22
SELECT table_name, data_type || '(' || char_length || ')' AS pattern_name_col
  FROM user_tab_columns
 WHERE column_name = 'PATTERN_NAME'
   AND table_name IN ('OC_TIME_CALENDAR','OC_TS_ENTRY')
 ORDER BY table_name;

PROMPT
PROMPT PATTERN_NAME is EMPTY until the feed is redeployed and re-run -- OIC runs
PROMPT the .xdm in the Fusion catalog, not integration/bip/extracts.py:
PROMPT
PROMPT   python integration/bip/run_extract.py --deploy WORKER_SHIFTS
PROMPT
PROMPT then re-run the sync. V_OC_TS_WEEK_PATTERN should then read
PROMPT 'O2C Sunday to Thursday' for RI2824 and RI2894, and 'O2C Pattern' for the
PROMPT rest of the cohort.
