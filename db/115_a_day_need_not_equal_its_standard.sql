--==============================================================
-- time/115_a_day_need_not_equal_its_standard.sql
-- O2C Timesheet Module — the standard-hours equality check goes on hold
--
-- Asked 21-Aug: "Lets put the standard hours per day validation on hold, it
-- can be more and less also."
--
-- -20028 refuses to submit a week unless EVERY day adds up to exactly its
-- standard hours. That is an equality, and the instruction is that the real
-- world is not one: a person may work nine hours on a hard day and seven on a
-- quiet one, and neither is an error the system should refuse.
--
-- ── ON HOLD, NOT DELETED, AND THE DIFFERENCE MATTERS ─────────
--
-- "On hold" was the word used, so this is a switch and not a deletion. The
-- rule stays in the package, reads OC_TIME_CONFIG, and comes back with an
-- UPDATE of one row if the decision reverses. Deleting the code would make the
-- return a development task instead of a configuration change.
--
-- NEITHER OF THESE RULES IS IN THE REQUIREMENT PACK. Checked 22-Aug against
-- the Rules sheet, all 22 rows. There is no rule that a day must EQUAL its
-- standard, and no rule that a day may not EXCEED it. The only daily maximum
-- in the pack is
--
--   RULE-003  Max 24 hours per day  daily_total <= 24  blocking  BRD 4.2
--             "Allocation can exceed 100% but a day cannot exceed 24h"
--
-- An earlier version of this file attributed -20028 to RULE-012. That was
-- wrong: RULE-012 is "Sat/Sun editable, default 0", sourced from the
-- prototype, and says nothing about standard hours. So the pack is not being
-- contradicted by switching these off -- it is being followed.
--
-- Same shape as ALLOW_SELF_APPROVAL (db/104): a named flag read at the point of
-- enforcement. Both default to ENFORCED in code, so a schema carrying db/09
-- without this script behaves as it did yesterday and nothing changes by
-- accident. The row this script inserts is what turns each one off.
--
-- Note the defaults point that way for OPERATIONAL safety, not because the
-- pack demands it -- unlike ALLOW_SELF_APPROVAL, where RULE-015 really does
-- block and the default is the pack speaking.
--
-- ── WHAT STAYS ON, DELIBERATELY ──────────────────────────────
--
-- What is NOT relaxed:
--
--   -20003   a day may not exceed 24 hours. This one IS the pack -- RULE-003,
--            blocking, BRD 4.2 -- and it is the only daily ceiling there is.
--   ShortOfStandard   the FLAG raised by db/112.
--
-- ── AND -20029 GOES WITH IT, ASKED 22-AUG ────────────────────
--
-- -20029 refuses a day that EXCEEDS its shift hours at save time. It was added
-- 20-Aug from a verbal ask -- db/88 records the exact words -- and it is the
-- upper half of the same pair: -20028 said "must equal", -20029 said "must not
-- exceed". Holding one and keeping the other would mean "it can be less but
-- not more", which is not what was decided; the words were "it can be more and
-- less also".
--
-- It is what stopped a manager correcting 8.00 to 8.25 on the Approval Detail
-- screen, which is how it surfaced.
--
-- SEPARATE FLAG, NOT ONE FLAG FOR BOTH. They can be wanted independently -- a
-- ceiling with no equality requirement is a perfectly reasonable policy -- and
-- a single switch would make reinstating one mean reinstating both.
--
-- The flag is the important one. Yesterday's decision was "let it stand short,
-- flag the week" -- so the week already carries a visible marker when a day
-- does not add up, and it is raised and cleared automatically. That marker is
-- what makes relaxing -20028 safe rather than silent: before db/112 removing
-- this gate would have meant a short day disappearing into the accrual batch
-- with nothing anywhere saying why, which is the failure mode CLAUDE.md §5
-- names five times over.
--
-- SO DO NOT REMOVE db/112 ON THE GROUNDS THAT THE VALIDATION IS GONE. The flag
-- is not a duplicate of the check; it is what replaces it.
--
-- Idempotent. Depends on: time/01, 09, 112.
-- RUN db/09 AFTER THIS: validate_day is edited there to read the flag.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/3] The switch
PROMPT ============================================================

MERGE INTO oc_time_config t
USING (SELECT 'ENFORCE_DAY_STANDARD_HOURS' AS nm, 'GLOBAL' AS sk FROM dual) s
   ON (t.config_name = s.nm AND t.scope_key = s.sk)
 WHEN MATCHED THEN UPDATE SET
   config_value = 'N',
   description  = '-20028. Y = a day must equal its standard hours '
               || 'before the week can be submitted. N = it may be more or '
               || 'less and the week carries the ShortOfStandard flag '
               || 'instead. Put on hold 21-Aug-2026.',
   updated_by   = 'DECISION_21AUG2026',
   updated_on   = SYSTIMESTAMP
 WHEN NOT MATCHED THEN INSERT
   (config_name, config_type, config_value, scope_key, description, created_by)
 VALUES
   ('ENFORCE_DAY_STANDARD_HOURS', 'feature_flag', 'N', 'GLOBAL',
    '-20028. Y = a day must equal its standard hours before the '
 || 'week can be submitted. N = it may be more or less and the week carries '
 || 'the ShortOfStandard flag instead. Put on hold 21-Aug-2026.',
    'DECISION_21AUG2026');

MERGE INTO oc_time_config t
USING (SELECT 'ENFORCE_DAY_SHIFT_CEILING' AS nm, 'GLOBAL' AS sk FROM dual) s
   ON (t.config_name = s.nm AND t.scope_key = s.sk)
 WHEN MATCHED THEN UPDATE SET
   config_value = 'N',
   description  = '-20029. Y = a day may not exceed the person''s shift hours. '
               || 'N = it may. Not a rule in the requirement pack; added 20-Aug '
               || 'from a call and put on hold 22-Aug. RULE-003 (24h) still '
               || 'applies and is the pack''s only daily ceiling.',
   updated_by   = 'DECISION_22AUG2026',
   updated_on   = SYSTIMESTAMP
 WHEN NOT MATCHED THEN INSERT
   (config_name, config_type, config_value, scope_key, description, created_by)
 VALUES
   ('ENFORCE_DAY_SHIFT_CEILING', 'feature_flag', 'N', 'GLOBAL',
    '-20029. Y = a day may not exceed the person''s shift hours. N = it may. '
 || 'Not a rule in the requirement pack; added 20-Aug from a call and put on '
 || 'hold 22-Aug. RULE-003 (24h) still applies and is the pack''s only daily '
 || 'ceiling.', 'DECISION_22AUG2026');

COMMIT;

COLUMN config_name  FORMAT A30
COLUMN config_value FORMAT A6
COLUMN config_type  FORMAT A14
SELECT config_name, config_value, config_type, scope_key
  FROM oc_time_config
 WHERE config_name IN ('ENFORCE_DAY_STANDARD_HOURS',
                        'ENFORCE_DAY_SHIFT_CEILING','ALLOW_SELF_APPROVAL')
 ORDER BY config_name;

PROMPT ============================================================
PROMPT [2/3] Weeks that could not be submitted under the old rule
PROMPT ============================================================

-- Read-only, and worth looking at before turning the gate off: these are the
-- weeks the equality was actually stopping. If this is empty the rule was
-- costing nothing and the change is free; if it is long, that is the size of
-- the problem being removed.
COLUMN nm    FORMAT A26
COLUMN week_ FORMAT A20
SELECT wk.employee_name AS nm,
       TO_CHAR(w.week_start,'DD-Mon') || ' - '
         || TO_CHAR(w.week_end,'DD-Mon') AS week_,
       w.submission_status,
       d.off_days,
       TRIM(TO_CHAR(d.over,  'FM9990.00')) AS hours_over,
       TRIM(TO_CHAR(d.under, 'FM9990.00')) AS hours_under
  FROM oc_ts_week w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
  JOIN (SELECT x.ts_week_id,
               COUNT(*) AS off_days,
               SUM(GREATEST(x.booked - x.std, 0)) AS over,
               SUM(GREATEST(x.std - x.booked, 0)) AS under
          FROM (SELECT e.ts_week_id, e.entry_date,
                       SUM(e.hours)          AS booked,
                       MAX(e.standard_hours) AS std
                  FROM oc_ts_entry e
                 WHERE e.entry_type IN ('Actual','Default')
                 GROUP BY e.ts_week_id, e.entry_date) x
         WHERE NVL(x.std,0) > 0
           AND NVL(x.booked,0) <> x.std
         GROUP BY x.ts_week_id) d ON d.ts_week_id = w.ts_week_id
 WHERE w.period_id IN (SELECT period_id FROM oc_time_period
                        WHERE status = 'Open')
 ORDER BY d.under DESC, d.over DESC
 FETCH FIRST 20 ROWS ONLY;

PROMPT ============================================================
PROMPT [3/3] The flag that replaces it
PROMPT ============================================================

SELECT flag_code, label, active_flag
  FROM oc_ts_flag_def
 WHERE flag_code = 'ShortOfStandard';

PROMPT
PROMPT If that returns no row, db/112 has not been run and turning -20028 off
PROMPT leaves a short day with NOTHING recording it. Run db/112 first.
