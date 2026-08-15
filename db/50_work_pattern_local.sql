--==============================================================
-- time/50_work_pattern_local.sql
-- O2C Timesheet Module — set a working pattern without waiting for OIC
--
-- RI2894 has "O2C Schedule Sunday to thursday" assigned in HCM, effective
-- 29-Dec-25 to 31-Dec-46, and OC_TIME_CALENDAR holds no SHIFT row for them at
-- all. The assignment is right; it has no route here.
--
-- WHY IT HAS NOT ARRIVED -- CORRECTED 16-Aug
--   An earlier version of this note said no individual pattern had ever
--   reached this database and that nothing expands a pattern into dates.
--   Both wrong. Measured: OC_TIME_CALENDAR holds 2,357 SHIFT days across 64
--   people, WORKER_SHIFTS is enabled in OC_TIME_SYNC_CONFIG against
--   OC_TIME_CALENDAR, and Fusion has already resolved pattern x schedule into
--   person x date rows -- which is exactly why WORK_PATTERNS and
--   WORK_SCHEDULES are deliberately off. The BLOCKED note in
--   16_oic_sync_config.sql is a 10-Aug measurement taken before the extract
--   aliases were corrected, and is stale.
--
--   The sync works. RI2894 is simply not in it: the last run was 15-Aug 00:00
--   and the schedule was assigned afterwards, so hts_schedule_shifts_vl had
--   nothing for them when the extract read it. Re-running the WORKER_SHIFTS
--   load is the real fix, and this script is only for testing before that.
--
--   Note the rostered window is 10-May to 12-Jul, entirely in the past. So no
--   August date is within a fortnight of a rostered day, and resolve_day's
--   roster check correctly leaves August to the country calendar.
--
-- WHAT THIS IS
--   A helper that writes the SHIFT rows directly, so a pattern can be tested
--   now and so anybody on a non-Mon-Fri week can be set up without OIC. It
--   writes exactly what the sync endpoint would write, to the same layer and
--   the same scope key, so switching to the real sync later overwrites it
--   rather than conflicting -- the upsert is on (layer, scope_key, cal_date).
--
--   This is a stop-gap and is named like one. The real fix is OIC expanding
--   HCM's work schedules into days for everybody, nightly.
--
-- Idempotent. Depends on: time/01
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
PROMPT [1/4] What is actually in the calendar
PROMPT ============================================================

COLUMN layer FORMAT A12
COLUMN span  FORMAT A26
SELECT layer,
       COUNT(*)                              AS days,
       COUNT(DISTINCT scope_key)             AS scopes,
       TO_CHAR(MIN(cal_date),'DD-Mon-YY') || ' to '
         || TO_CHAR(MAX(cal_date),'DD-Mon-YY') AS span,
       SUM(CASE WHEN is_working_day = 'N' THEN 1 ELSE 0 END) AS non_working
  FROM oc_time_calendar
 GROUP BY layer
 ORDER BY layer;

PROMPT
PROMPT A SHIFT row count of zero means no individual pattern has ever reached
PROMPT this database, and every worker is being treated as Monday to Friday
PROMPT regardless of what HCM says.

PROMPT ============================================================
PROMPT [2/4] OC_TIME_SET_WORK_PATTERN
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_set_work_pattern(
  p_employee_id IN VARCHAR2,
  p_from        IN DATE,
  p_to          IN DATE,
  -- Three-letter English day abbreviations, comma separated, in any order.
  -- 'SUN,MON,TUE,WED,THU' is the Sunday-to-Thursday week.
  p_working_days IN VARCHAR2,
  p_std_hours   IN NUMBER   DEFAULT NULL,
  p_shift_code  IN VARCHAR2 DEFAULT 'HCM',
  p_actor       IN VARCHAR2 DEFAULT 'WORK_PATTERN')
IS
  v_std   NUMBER;
  v_days  NUMBER := 0;
  v_work  NUMBER := 0;
  v_dow   VARCHAR2(3);
  v_is    VARCHAR2(1);
  v_list  VARCHAR2(200) := ',' || UPPER(REPLACE(p_working_days,' ','')) || ',';
BEGIN
  IF p_to < p_from THEN
    RAISE_APPLICATION_ERROR(-20013, 'The end date is before the start date.');
  END IF;

  SELECT NVL(p_std_hours, NVL(std_hours_per_day, 8)) INTO v_std
    FROM oc_time_worker WHERE employee_id = p_employee_id;

  FOR d IN 0 .. (p_to - p_from) LOOP
    -- NLS_DATE_LANGUAGE pinned. Without it the abbreviation follows the
    -- session's language and 'SUN' silently matches nothing for a caller
    -- connected in anything but English -- every day would read non-working
    -- and the person would have no timesheet at all.
    v_dow := TO_CHAR(p_from + d, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH');
    v_is  := CASE WHEN INSTR(v_list, ',' || v_dow || ',') > 0 THEN 'Y' ELSE 'N' END;

    MERGE INTO oc_time_calendar c
    USING (SELECT 'SHIFT' AS layer, p_employee_id AS scope_key,
                  p_from + d AS cal_date FROM dual) s
       ON (c.layer = s.layer AND c.scope_key = s.scope_key
       AND c.cal_date = s.cal_date)
     WHEN MATCHED THEN UPDATE
          SET c.is_working_day = v_is,
              -- RULE-012: a non-working day carries zero standard hours, so
              -- nothing is ever pre-filled onto it.
              c.std_hours      = CASE WHEN v_is = 'Y' THEN v_std ELSE 0 END,
              c.shift_code     = p_shift_code,
              c.synced_on      = SYSTIMESTAMP,
              c.updated_by     = p_actor
     WHEN NOT MATCHED THEN
          INSERT (layer, scope_key, cal_date, is_working_day, std_hours,
                  shift_code, precedence, source_system, synced_on, created_by)
          -- Precedence 4 = SHIFT, outranking CLIENT 3, PROJECT 2 and
          -- CORPORATE 1, which is what makes an individual schedule beat the
          -- country calendar. Passed explicitly for readability, though
          -- TRG_OC_TC_PRECEDENCE overwrites it from the layer regardless --
          -- which is also why the sync handler's hardcoded 1 is harmless. The
          -- column is NUMBER(1), so a larger number would not fit anyway.
          VALUES ('SHIFT', p_employee_id, p_from + d, v_is,
                  CASE WHEN v_is = 'Y' THEN v_std ELSE 0 END,
                  p_shift_code, 4, 'LOCAL', SYSTIMESTAMP, p_actor);

    v_days := v_days + 1;
    IF v_is = 'Y' THEN v_work := v_work + 1; END IF;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(p_employee_id || ': ' || v_days || ' day(s) written, '
    || v_work || ' working, at ' || v_std || 'h');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] Apply RI2894's Sunday-to-Thursday schedule
PROMPT ============================================================

-- The HCM assignment runs 29-Dec-25 to 31-Dec-46. Only the periods this
-- module knows about are written -- twenty-one years of rows would be a
-- pointless table, and a period that does not exist here cannot be
-- timesheeted anyway.
DECLARE
  v_from DATE;
  v_to   DATE;
BEGIN
  SELECT MIN(start_date), MAX(end_date) INTO v_from, v_to FROM oc_time_period;
  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('no periods loaded; nothing to write');
    RETURN;
  END IF;

  oc_time_set_work_pattern(
    p_employee_id  => 'RI2894',
    p_from         => v_from,
    p_to           => v_to,
    p_working_days => 'SUN,MON,TUE,WED,THU',
    p_shift_code   => 'O2C-SUN-THU',
    p_actor        => 'MANUAL-15AUG');
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN day FORMAT A14
SELECT TO_CHAR(cal_date,'DY DD-Mon') AS day, shift_code,
       is_working_day, std_hours
  FROM oc_time_calendar
 WHERE layer = 'SHIFT' AND scope_key = 'RI2894'
   AND cal_date BETWEEN DATE '2026-08-16' AND DATE '2026-08-23'
 ORDER BY cal_date;

PROMPT
PROMPT SUN MON TUE WED THU must read Y, FRI and SAT must read N. That is the
PROMPT inverse of the Mon-Fri default, so if it comes back the other way the
PROMPT day abbreviations did not match.

PROMPT
PROMPT --- and what resolve_day now says, which is what populate obeys
DECLARE
  v_shift VARCHAR2(30); v_std NUMBER; v_work VARCHAR2(1); v_hol VARCHAR2(200);
  v_proj  NUMBER;
BEGIN
  SELECT MIN(project_id) INTO v_proj FROM oc_time_allocation
   WHERE employee_id = 'RI2894' AND status = 'Active';

  FOR d IN 0 .. 6 LOOP
    oc_time_pkg.resolve_day('RI2894', v_proj, DATE '2026-08-16' + d,
                            v_shift, v_std, v_work, v_hol);
    DBMS_OUTPUT.PUT_LINE('  '
      || TO_CHAR(DATE '2026-08-16' + d, 'DY DD-Mon', 'NLS_DATE_LANGUAGE=ENGLISH')
      || '  working=' || v_work || '  std=' || NVL(TO_CHAR(v_std),'-')
      || '  shift=' || NVL(v_shift,'-'));
  END LOOP;
END;
/

PROMPT
PROMPT ============================================================
PROMPT TWO THINGS THIS DOES NOT DO
PROMPT ============================================================
PROMPT
PROMPT 1. It does not re-seed days already populated. populate inserts WHERE
PROMPT    NOT EXISTS, so 17-23 Aug keeps whatever it already has. To see the
PROMPT    new pattern on a week that is already built, clear that week's
PROMPT    prepopulated entries first and re-run jobs/daily.
PROMPT
PROMPT 2. It does not fix the sync. Every other worker still has no SHIFT row
PROMPT    and is still treated as Monday to Friday whatever HCM says. This
PROMPT    helper exists so one person can be tested, not so the gap can be
PROMPT    ignored -- OIC still has to expand HCM work schedules into days for
PROMPT    everybody and POST them to calendar/sync/SHIFT.
