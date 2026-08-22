--==============================================================
-- time/124_short_is_a_week_thing.sql
-- O2C Timesheet Module -- ShortOfStandard goes back to week-only
--
-- Asked 22-Aug, on seeing the backfill put two chips on one row:
--
--   "17-Aug gets Overridden + Short (8.00 -> 7.00) -- we don't care if it is
--    short, lets remove 'Short'."
--
-- -- WHY THE DAY CHIP WAS WRONG AND THE WEEK ONE IS NOT ---------
--
-- These are not the same statement at two grains. On the DAY, "short" reads as
-- a fault with that day -- and a day the manager deliberately cut from 8 to 7
-- is not a fault, it is the decision they just made, sitting on the screen
-- where they made it. Overridden already says a person changed it; adding
-- Short says the change was not big enough, which nobody asked the system to
-- judge.
--
-- On the WEEK it is the opposite. The week is what reaches the accrual batch,
-- and the whole reason db/112 exists is that two hours could vanish from that
-- batch with nothing anywhere saying why. That is still true and the week flag
-- still carries it.
--
-- So the original decision -- "let it stand short, FLAG THE WEEK" (21-Aug) --
-- was right as stated, and db/122 over-applied it by giving every flag a day
-- home whether or not it meant anything there. This puts that one back.
--
-- -- THE SCOPE REVERT IS A GUARD, NOT JUST TIDYING -------------
--
-- oc_time_raise_day_flag refuses a code the dictionary does not permit at day
-- level, by name, with -20031. Setting SCOPE_LEVEL back to WEEK therefore
-- means a future call cannot quietly reintroduce this: it fails loudly and
-- says to widen the dictionary first if that is really intended.
--
-- RUN db/112 BEFORE THIS. The other order leaves a window in which a manager
-- correction calls a raiser the dictionary has already refused.
--
-- Idempotent. Depends on: time/27, 112, 122.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/4] Check db/112 has already been re-run
PROMPT ============================================================

-- Reverting the scope while the old procedure still calls the day raiser would
-- make the next correction fail with -20031. Cheap to check, and the failure
-- it prevents lands on a manager mid-approval rather than here.
DECLARE
  v_bad NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_bad
    FROM user_source
   WHERE name = 'OC_TIME_CHECK_SHORT_WEEK'
     AND UPPER(text) LIKE '%RAISE_DAY_FLAG%';

  IF v_bad > 0 THEN
    RAISE_APPLICATION_ERROR(-20033,
      'OC_TIME_CHECK_SHORT_WEEK still calls oc_time_raise_day_flag. Re-run '
      || 'db/112 first, or the next correction fails with -20031.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('  db/112 is current - no day raiser in the procedure.');
END;
/

PROMPT ============================================================
PROMPT [2/4] Clear the day flags already raised
PROMPT ============================================================

-- CLEARED, not deleted. The rule everywhere else in this model is that a flag
-- is never removed -- CLEARED_ON is what lets somebody see it was once true --
-- and a flag withdrawn by a decision is still something that happened. It also
-- keeps the row available if the decision reverses.
UPDATE oc_ts_day_flag
   SET cleared_on = SYSTIMESTAMP,
       cleared_by = 'DB_124',
       notes      = 'Withdrawn: ShortOfStandard is a week-level flag '
                 || '(decision 22-Aug-2026).'
 WHERE flag_code  = 'ShortOfStandard'
   AND cleared_on IS NULL;

BEGIN
  DBMS_OUTPUT.PUT_LINE('  day flags cleared: ' || SQL%ROWCOUNT);
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [3/4] Take DAY out of what the flag permits
PROMPT ============================================================

UPDATE oc_ts_flag_def
   SET scope_level = 'WEEK'
 WHERE flag_code   = 'ShortOfStandard'
   AND scope_level <> 'WEEK';

BEGIN
  DBMS_OUTPUT.PUT_LINE('  scope reverted: ' || SQL%ROWCOUNT);
  COMMIT;
END;
/

COLUMN flag_code FORMAT A20
COLUMN label     FORMAT A26
SELECT flag_code, label, scope_level, sort_order
  FROM oc_ts_flag_def
 ORDER BY sort_order;

PROMPT
PROMPT ShortOfStandard must read WEEK. Overridden and Adjusted stay BOTH --
PROMPT those two genuinely belong to a day, which is the case that started this.

PROMPT ============================================================
PROMPT [4/4] What the day rows carry now
PROMPT ============================================================

COLUMN nm         FORMAT A24
COLUMN flag_codes FORMAT A30
SELECT wk.employee_name AS nm, d.entry_date, d.hours,
       d.flag_count, d.flag_codes
  FROM v_oc_ts_day_detail d
  JOIN oc_ts_week     w  ON w.ts_week_id   = d.ts_week_id
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
 WHERE d.flag_count > 0
 ORDER BY d.entry_date
 FETCH FIRST 15 ROWS ONLY;

PROMPT
PROMPT --- and the week still says it, which is the point
COLUMN week_ FORMAT A20
SELECT wk.employee_name AS nm,
       TO_CHAR(w.week_start,'DD-Mon') || ' - '
         || TO_CHAR(w.week_end,'DD-Mon') AS week_,
       f.flag_code, f.notes
  FROM oc_ts_week_flag f
  JOIN oc_ts_week     w  ON w.ts_week_id   = f.ts_week_id
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
 WHERE f.flag_code  = 'ShortOfStandard'
   AND f.cleared_on IS NULL
 ORDER BY w.week_start
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT A day row should now show Overridden alone. The week keeps
PROMPT ShortOfStandard with the shortfall in its notes -- that is where it
PROMPT matters, because the week is what reaches accrual.
