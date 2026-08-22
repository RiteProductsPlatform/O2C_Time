--==============================================================
-- time/123_backfill_the_day_flags.sql
-- O2C Timesheet Module -- raise day flags for corrections made before db/122
-- existed
--
-- Asked 22-Aug: "override_approve only raises them from now on -- how to get
-- it reflected for previous changes."
--
-- -- IT IS RECOVERABLE, AND THAT IS NOT LUCK --------------------
--
-- Every manager correction already wrote a row to OC_TS_AUDIT carrying
-- TS_ENTRY_ID, ENTRY_DATE, the hours either side, the reason and who did it.
-- The flag was the only thing missing, and a flag is derived information --
-- it says "this happened", and the audit already says that with more detail.
--
-- So this reads the trail rather than inventing anything. Nothing is flagged
-- that cannot be pointed at a row somebody wrote.
--
-- -- SHORTOFSTANDARD IS TREATED DIFFERENTLY, ON PURPOSE ---------
--
-- db/112 decided NOT to back-flag it, and said why:
--
--   "Nothing is flagged here: the flag is raised by the manager's own action
--    from now on, and back-flagging history would put a mark on weeks nobody
--    can now explain."
--
-- That still holds for the 1,500-odd defaulted weeks that are short because
-- nobody filled them in -- flagging those says "somebody cut this" about weeks
-- no manager ever touched.
--
-- It does NOT hold for a week a manager demonstrably corrected. There the
-- shortfall IS attributable, and the flag is the record of it. So section [3]
-- recomputes ShortOfStandard only for weeks with an Override in the audit --
-- narrow enough to be explainable, which is the test db/112 set.
--
-- -- WHAT MAPS TO WHAT ------------------------------------------
--
--   Override, ManagerEdit, DefaultCorrection  ->  Overridden
--   Adjustment, Reversal                      ->  Adjusted
--
-- Import is excluded: that is the loader, not a person.
--
-- Idempotent -- oc_time_raise_day_flag is a MERGE and re-raising a live flag
-- does not move SET_ON, so running this twice changes nothing.
-- Depends on: time/04, 112, 122, and db/09 recompiled after 122.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/4] What the audit trail can account for
PROMPT ============================================================

COLUMN change_type FORMAT A20
COLUMN maps_to     FORMAT A16
SELECT a.change_type,
       CASE a.change_type
         WHEN 'Override'          THEN 'Overridden'
         WHEN 'ManagerEdit'       THEN 'Overridden'
         WHEN 'DefaultCorrection' THEN 'Overridden'
         WHEN 'Adjustment'        THEN 'Adjusted'
         WHEN 'Reversal'          THEN 'Adjusted'
         ELSE '(not flagged)'
       END AS maps_to,
       COUNT(*)                        AS audit_rows,
       COUNT(DISTINCT a.ts_entry_id)   AS entries,
       COUNT(DISTINCT a.ts_week_id)    AS weeks
  FROM oc_ts_audit a
 GROUP BY a.change_type
 ORDER BY 1;

PROMPT
PROMPT Import is the loader rather than a person and is deliberately not
PROMPT flagged. An entry counted twice under one change type is still one
PROMPT flag: the flag says it happened, the audit says how often.

PROMPT ============================================================
PROMPT [2/4] Raise Overridden and Adjusted from the trail
PROMPT ============================================================

DECLARE
  v_n NUMBER := 0;
  v_skip NUMBER := 0;
BEGIN
  FOR a IN (SELECT DISTINCT
                   a.ts_entry_id,
                   CASE a.change_type
                     WHEN 'Adjustment' THEN 'Adjusted'
                     WHEN 'Reversal'   THEN 'Adjusted'
                     ELSE 'Overridden'
                   END AS flag_code
              FROM oc_ts_audit a
             WHERE a.ts_entry_id IS NOT NULL
               AND a.change_type IN ('Override','ManagerEdit',
                                     'DefaultCorrection','Adjustment',
                                     'Reversal'))
  LOOP
    BEGIN
      oc_time_raise_day_flag(a.ts_entry_id, a.flag_code, 'DB_123_BACKFILL',
        'Backfilled from the audit trail.');
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      -- The entry may since have been deleted -- a rebuild, a period wipe --
      -- and the FK will refuse. That is a flag with nothing to attach to, not
      -- a failure of the backfill.
      v_skip := v_skip + 1;
    END;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  day flags raised : ' || v_n);
  DBMS_OUTPUT.PUT_LINE('  skipped          : ' || v_skip
    || ' (entry no longer exists)');
END;
/

PROMPT ============================================================
PROMPT [3/4] Recompute ShortOfStandard, but only where it is explainable
PROMPT ============================================================

-- Scoped to weeks a manager demonstrably corrected. db/112 refused to
-- back-flag the rest and was right to: a defaulted week is short because
-- nobody filled it in, and marking that "short of standard" says somebody cut
-- it. See the header.
--
-- oc_time_check_short_week both RAISES and CLEARS, so a week that was
-- corrected and then put right comes out clean rather than carrying a mark
-- nobody can account for.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR w IN (SELECT DISTINCT a.ts_week_id
              FROM oc_ts_audit a
             WHERE a.change_type IN ('Override','ManagerEdit',
                                     'DefaultCorrection')
               AND a.ts_week_id IS NOT NULL)
  LOOP
    BEGIN
      oc_time_check_short_week(w.ts_week_id, 'DB_123_BACKFILL');
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  weeks rechecked: ' || v_n);
END;
/

PROMPT ============================================================
PROMPT [4/4] What is flagged now
PROMPT ============================================================

COLUMN flag_code FORMAT A20
SELECT flag_code, COUNT(*) AS days_flagged,
       COUNT(DISTINCT ts_week_id) AS weeks
  FROM v_oc_ts_day_flags
 GROUP BY flag_code
 ORDER BY 1;

PROMPT
PROMPT --- and the same week the screen is open on
COLUMN nm         FORMAT A24
COLUMN flag_codes FORMAT A34
SELECT wk.employee_name AS nm, d.entry_date, d.hours,
       d.flag_count, d.flag_codes
  FROM v_oc_ts_day_detail d
  JOIN oc_ts_week     w  ON w.ts_week_id   = d.ts_week_id
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
 WHERE d.flag_count > 0
 ORDER BY d.entry_date
 FETCH FIRST 15 ROWS ONLY;

PROMPT
PROMPT Re-run ords/12 if these columns are populated here but still absent from
PROMPT GET days/:tsWeekId -- the handlers name their columns, so a view change
PROMPT does not reach the API on its own.
