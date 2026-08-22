--==============================================================
-- time/112_manager_may_leave_a_day_short.sql
-- O2C Timesheet Module — a manager may cut a day below its standard, and the
-- week says so
--
-- Decided 21-Aug, on the question of what happens when a MANAGER reduces hours:
-- "let it stand short, flag the week". The manager is the authority -- if they
-- say six hours, it was six hours -- and the reason they typed is the record.
--
-- ── THE HOLE THIS CLOSES ─────────────────────────────────────
--
-- -20028 requires each day to EQUAL its standard, and it fires at SUBMIT, which
-- is the employee asserting the week is complete. A manager correcting
-- afterwards never passes through that gate. So today a manager can cut a day
-- from 8 to 6 and nothing anywhere records that the day stopped adding up: the
-- two hours simply do not appear in the accrual batch, and no screen, flag or
-- column says why.
--
-- The decision is NOT to refuse the reduction. It is to stop it being silent.
--
-- ── WHY A NEW FLAG RATHER THAN REUSING Overridden ────────────
--
-- override_approve already raises Overridden, so the week is already flagged --
-- but Overridden means "a manager changed this", which is equally true of
-- moving hours between tasks, and that leaves the day adding up. It cannot
-- answer "is this week short, and by how much". Distinguishing them is the
-- whole point of the ask.
--
-- Adding one is an INSERT, which is what the V4 model promised: FLAG_CODE is a
-- foreign key to OC_TS_FLAG_DEF, so the dictionary is the definition and no
-- code enumerates the set. This is the sixth flag.
--
-- ── IT IS RAISED *AND* CLEARED ───────────────────────────────
--
-- Flags are never deleted -- clearing sets CLEARED_ON -- so a week that goes
-- short and is then put right keeps the history and stops showing as short.
-- Without the clear, the first correction would mark a week short forever, and
-- a flag nobody can get rid of is one people learn to ignore.
--
-- Idempotent. Depends on: time/09, 27, 37.
-- RUN THIS BEFORE db/124, which reverts the flag's scope -- the other way
-- round leaves a window where a correction calls a day raiser the
-- dictionary has already refused.
-- RUN db/09 AFTER THIS: override_approve is edited there to call the check.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TS_FLAG_DEF';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/27 has not been run: OC_TS_FLAG_DEF is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] The sixth flag
PROMPT ============================================================

MERGE INTO oc_ts_flag_def t
USING (SELECT 'ShortOfStandard' AS cd FROM dual) s
   ON (t.flag_code = s.cd)
 WHEN MATCHED THEN UPDATE SET
   label       = 'Short of standard',
   description = 'A manager reduced one or more days below the standard hours '
              || 'for that day and the hours were not reassigned. The day is '
              || 'allowed to stand short - the manager is the authority and '
              || 'their override reason is the record - but the week carries '
              || 'this so the shortfall is visible rather than silent. Cleared '
              || 'automatically once every day adds up again.',
   sort_order  = 60
 WHEN NOT MATCHED THEN INSERT
   (flag_code, label, description, scope_level, sort_order, created_by)
 VALUES
   ('ShortOfStandard', 'Short of standard',
    'A manager reduced one or more days below the standard hours for that day '
 || 'and the hours were not reassigned. The day is allowed to stand short - the '
 || 'manager is the authority and their override reason is the record - but the '
 || 'week carries this so the shortfall is visible rather than silent. Cleared '
 || 'automatically once every day adds up again.',
    'WEEK', 60, 'DECISION_21AUG2026');

COMMIT;

COLUMN flag_code FORMAT A20
COLUMN label     FORMAT A24
SELECT flag_code, label, scope_level, sort_order, active_flag
  FROM oc_ts_flag_def
 WHERE scope_level IN ('WEEK','BOTH')
 ORDER BY sort_order;

PROMPT ============================================================
PROMPT [2/3] The check itself
PROMPT ============================================================

-- A standalone procedure rather than a private one inside OC_TIME_PKG, so the
-- flag rule is readable on its own and can be called from a job later without
-- widening the package spec.
--
-- Compares each day's booked hours against the standard recorded ON THE ENTRY,
-- not against the worker or the calendar. STANDARD_HOURS is copied onto the row
-- when the day is populated, so it is the figure that applied when the day was
-- worked -- a later shift change must not retrospectively make an old week look
-- short.
--
-- Zero-standard days are skipped: a weekend or a holiday has no standard to
-- fall short of, and RULE-012 still allows voluntary hours there.
CREATE OR REPLACE PROCEDURE oc_time_check_short_week(
  p_ts_week_id IN NUMBER,
  p_actor      IN VARCHAR2 DEFAULT 'SYSTEM')
IS
  v_short NUMBER;
  v_gap   NUMBER;
  v_note  VARCHAR2(400);
BEGIN
  SELECT COUNT(*), NVL(SUM(d.std - d.booked), 0)
    INTO v_short, v_gap
    FROM (SELECT e.entry_date,
                 SUM(e.hours)          AS booked,
                 MAX(e.standard_hours) AS std
            FROM oc_ts_entry e
           WHERE e.ts_week_id = p_ts_week_id
             AND e.entry_type IN ('Actual','Default')
           GROUP BY e.entry_date) d
   WHERE NVL(d.std, 0) > 0
     AND NVL(d.booked, 0) < d.std;

  -- WEEK ONLY. NOT PER DAY -- and it was, for about an hour.
  --
  -- db/122 gave every flag a day-level home and this one followed the others
  -- there. Seeing it land, the answer was "we don't care if it is short, remove
  -- Short" (22-Aug): a day the manager deliberately cut from 8 to 7 is not a
  -- problem with that day, so labelling the row is noise on the screen where
  -- the correction was just made.
  --
  -- The WEEK flag stays, because the original decision was precisely "let it
  -- stand short, FLAG THE WEEK" (21-Aug). The week is where the shortfall
  -- matters -- it is what reaches the accrual batch, and the number nobody
  -- could account for before this flag existed.
  --
  -- Overridden still lands on the day, so the row does say a manager changed
  -- it. What it no longer does is editorialise about whether the new figure
  -- was big enough.
  --
  -- db/124 sets SCOPE_LEVEL back to WEEK, so oc_time_raise_day_flag now
  -- REFUSES this code with -20031. Re-adding a call here without widening the
  -- dictionary again will fail loudly rather than silently doing nothing.

  IF v_short > 0 THEN
    v_note := v_short || ' day(s) short by '
           || TRIM(TO_CHAR(v_gap, 'FM9990.00')) || ' hours in total.';
    oc_time_raise_week_flag(p_ts_week_id, 'ShortOfStandard', p_actor, v_note);
  ELSE
    -- Cleared, not deleted. CLEARED_ON is what makes the history survive the
    -- week being put right.
    UPDATE oc_ts_week_flag
       SET cleared_on = SYSTIMESTAMP,
           cleared_by = p_actor
     WHERE ts_week_id = p_ts_week_id
       AND flag_code  = 'ShortOfStandard'
       AND cleared_on IS NULL;
  END IF;
END oc_time_check_short_week;
/

SHOW ERRORS

PROMPT ============================================================
PROMPT [3/3] Which weeks are short right now
PROMPT ============================================================

-- Read-only. Nothing is flagged here: the flag is raised by the manager's own
-- action from now on, and back-flagging history would put a mark on weeks
-- nobody can now explain.
COLUMN nm FORMAT A28
SELECT w.ts_week_id, wk.employee_name AS nm,
       TO_CHAR(w.week_start,'DD-Mon') || ' - ' || TO_CHAR(w.week_end,'DD-Mon') AS week_,
       d.short_days, TRIM(TO_CHAR(d.gap,'FM9990.00')) AS short_by
  FROM oc_ts_week w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
  JOIN (SELECT x.ts_week_id,
               COUNT(*) AS short_days,
               SUM(x.std - x.booked) AS gap
          FROM (SELECT e.ts_week_id, e.entry_date,
                       SUM(e.hours)          AS booked,
                       MAX(e.standard_hours) AS std
                  FROM oc_ts_entry e
                 WHERE e.entry_type IN ('Actual','Default')
                 GROUP BY e.ts_week_id, e.entry_date) x
         WHERE NVL(x.std,0) > 0
           AND NVL(x.booked,0) < x.std
         GROUP BY x.ts_week_id) d ON d.ts_week_id = w.ts_week_id
 WHERE w.period_id IN (SELECT period_id FROM oc_time_period
                        WHERE period_name IN ('JUL-2026','AUG-2026'))
 ORDER BY d.gap DESC
 FETCH FIRST 20 ROWS ONLY;

PROMPT
PROMPT Rows here are weeks that do not add up TODAY, for any reason - including
PROMPT the shift-calendar gap db/09 fixed, which left days with a standard and
PROMPT no hours. Re-run populate before reading this as manager corrections.
