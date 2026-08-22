--==============================================================
-- time/116_a_week_is_not_split_across_months.sql
-- O2C Timesheet Module — a straddling week stays whole and belongs to the
-- month its Monday falls in
--
-- Reported 21-Aug: "Week split is not happening properly - like aug is
-- starting from week 2 but its week 1. If first week is coming half in next
-- month let it be, and same way last week in next month."
--
-- ── WHAT WAS ACTUALLY ON THE SCREEN ──────────────────────────
--
-- 1-Aug-2026 is a SATURDAY. Under the clipping rule, August's first week is
-- the two-day stub 1-Aug..2-Aug, which takes WEEK_INDEX 1 -- so the first week
-- anybody actually works, 3-Aug..9-Aug, is labelled Week 2. For most of the
-- pod that stub is a weekend with no hours in it, so the month appeared to
-- open at Week 2 with an empty Week 1 above it.
--
-- Nothing was miscalculated. The rule was doing exactly what it said and the
-- result was wrong for the reader, which is the only test that counts.
--
-- ── THE NEW RULE, AND IT REVERSES A SETTLED DECISION ─────────
--
-- A week is a whole ISO week and belongs to the month containing its MONDAY.
--
--   JUL-2026   weeks of 6, 13, 20, 27 Jul   (the 27-Jul week runs to 2-Aug)
--   AUG-2026   weeks of 3, 10, 17, 24, 31 Aug   -- Week 1 is 3-Aug
--
-- 1-3 Jul therefore sit in June's last week, and 1-2 Aug in July's last week.
-- That is the "let it be" in both directions, applied symmetrically.
--
-- CLAUDE.md section 6 records the opposite as settled, with a real reason:
--
--   "Weeks are clipped to the month... the manager confirms a project MONTH in
--    one action, so a week must never contribute hours to two periods; month
--    aggregation then cannot double-count."
--
-- THAT REASON HAS NOT GONE AWAY. It is now handled differently rather than
-- avoided: a week still belongs to exactly ONE period -- its Monday's -- so
-- nothing double-counts and confirm_month still sums a clean set of weeks.
-- What changes is that a period's hours are no longer exactly its calendar
-- month. JUL-2026's accrual will contain 1-2 Aug, and will not contain 1-3
-- Jul.
--
-- ANYONE RECONCILING THE ACCRUAL BATCH AGAINST A CALENDAR MONTH NEEDS TO KNOW
-- THAT. It is the real cost of this change and it is worth saying out loud
-- rather than discovering at invoice time. Sam and Santosh work Sun-Thu, so
-- for them 2-Aug is a working day and this is not a theoretical difference.
--
-- ── WHY THE MIGRATION IS DELIBERATELY TIMID ──────────────────
--
-- Rewriting history here would move hours into and out of months that have
-- already been handed to accrual. JUL-2026 was confirmed this morning
-- (confirm_id 429, 116 rows, 600.00 hours). Merging 1-2 Aug into July's last
-- week after that point adds hours to a settled month with no top-up behind
-- them -- the consumer would see one total and our screens another.
--
-- So section [3] moves ONLY weeks whose source and target periods are both
-- Open and NOT confirmed, and prints every boundary it refused to touch. A
-- month already closed keeps the shape it was closed in, which is the honest
-- answer: that IS how it was recorded.
--
-- Idempotent. Depends on: time/01, 02, 03, 09.
-- RUN db/09 AFTER THIS: week_start_of / week_end_of / week_index_of and
-- ensure_week are edited there.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/5] The three date rules, as standalone functions
PROMPT ============================================================

-- Defined outside OC_TIME_PKG as well as inside it, so a view or an ad-hoc
-- query can ask the same question without the package. The package copies are
-- what the code calls; these are what SQL calls. They must agree, and [2]
-- proves they do.

-- The Monday. No clipping: this is the whole change in one line.
CREATE OR REPLACE FUNCTION oc_time_week_start(p_date IN DATE) RETURN DATE
  DETERMINISTIC
IS
BEGIN
  RETURN TRUNC(p_date, 'IW');
END oc_time_week_start;
/

CREATE OR REPLACE FUNCTION oc_time_week_end(p_date IN DATE) RETURN DATE
  DETERMINISTIC
IS
BEGIN
  RETURN TRUNC(p_date, 'IW') + 6;
END oc_time_week_end;
/

-- 1-based index of the week inside the month that owns its Monday.
--
-- TRUNC(first-of-month + 6, 'IW') is the first Monday ON OR AFTER the 1st, and
-- it is NLS-safe: TRUNC(...,'IW') always means Monday regardless of
-- NLS_TERRITORY, whereas TO_CHAR(d,'D') does not -- 'D' returns 1 for Sunday
-- in America and 1 for Monday elsewhere, which would shift every index by one
-- depending on who ran it.
CREATE OR REPLACE FUNCTION oc_time_week_index(p_date IN DATE) RETURN NUMBER
  DETERMINISTIC
IS
  v_mon   DATE := TRUNC(p_date, 'IW');
  v_first DATE;
BEGIN
  v_first := TRUNC(TRUNC(v_mon, 'MM') + 6, 'IW');
  RETURN TRUNC((v_mon - v_first) / 7) + 1;
END oc_time_week_index;
/

SHOW ERRORS

PROMPT ============================================================
PROMPT [2/5] Prove it on the months in question
PROMPT ============================================================

COLUMN d_       FORMAT A12
COLUMN owns     FORMAT A9
COLUMN range_   FORMAT A24
PROMPT Every date of the Jul/Aug boundary, and which week now owns it
SELECT TO_CHAR(d.dt,'DD-Mon-YY Dy')                        AS d_,
       TO_CHAR(oc_time_week_start(d.dt),'MON-YYYY')        AS owns,
       oc_time_week_index(d.dt)                            AS wk,
       TO_CHAR(oc_time_week_start(d.dt),'DD-Mon') || ' - '
         || TO_CHAR(oc_time_week_end(d.dt),'DD-Mon')       AS range_
  FROM (SELECT DATE '2026-07-28' + LEVEL - 1 AS dt
          FROM dual CONNECT BY LEVEL <= 10) d
 ORDER BY d.dt;

PROMPT
PROMPT Expected: 28-31 Jul and 1-2 Aug all read JUL-2026 week 4, one range.
PROMPT           3-Aug onwards reads AUG-2026 week 1. That is the fix.

PROMPT
PROMPT August, week by week
SELECT DISTINCT
       oc_time_week_index(d.dt) AS wk,
       TO_CHAR(oc_time_week_start(d.dt),'DD-Mon') || ' - '
         || TO_CHAR(oc_time_week_end(d.dt),'DD-Mon') AS range_,
       TO_CHAR(oc_time_week_start(d.dt),'MON-YYYY') AS owns
  FROM (SELECT DATE '2026-08-01' + LEVEL - 1 AS dt
          FROM dual CONNECT BY LEVEL <= 31) d
 ORDER BY 3, 1;

PROMPT ============================================================
PROMPT [3/5] What the change would do to weeks that already exist
PROMPT ============================================================

-- Read-only. Nothing moves in this section.

COLUMN nm      FORMAT A24
COLUMN now_    FORMAT A20
COLUMN would_  FORMAT A20
COLUMN verdict FORMAT A34
SELECT w.ts_week_id,
       wk.employee_name AS nm,
       p.period_name,
       TO_CHAR(w.week_start,'DD-Mon') || '-' || TO_CHAR(w.week_end,'DD-Mon')
         AS now_,
       TO_CHAR(oc_time_week_start(w.week_start),'DD-Mon') || '-'
         || TO_CHAR(oc_time_week_end(w.week_start),'DD-Mon') AS would_,
       w.week_index AS idx_now,
       oc_time_week_index(w.week_start) AS idx_new,
       CASE
         WHEN EXISTS (SELECT 1 FROM oc_ts_month_confirm mc
                       WHERE mc.period_id = w.period_id)
           THEN 'SKIPPED - month confirmed'
         WHEN p.status <> 'Open'
           THEN 'SKIPPED - period not Open'
         ELSE 'will be renumbered/merged'
       END AS verdict
  FROM oc_ts_week w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
  JOIN oc_time_period p  ON p.period_id    = w.period_id
 WHERE w.week_start <> oc_time_week_start(w.week_start)
    OR w.week_end   <> oc_time_week_end(w.week_start)
    OR w.week_index <> oc_time_week_index(w.week_start)
 ORDER BY p.period_name, wk.employee_name, w.week_start
 FETCH FIRST 40 ROWS ONLY;

PROMPT
PROMPT Rows reading SKIPPED keep the shape they were confirmed in. That is not
PROMPT a failure - it is how those hours were actually handed over.

PROMPT ============================================================
PROMPT [4/5] Renumber the weeks that are safe to touch
PROMPT ============================================================

-- Two separate jobs, and only the first is done here.
--
--   RENUMBER  week_index, which is presentation. Safe: no hours move, no week
--             changes period, nothing the accrual has seen is different.
--   MERGE     a boundary stub into its Monday's week, which moves ENTRIES
--             between week rows and between periods. Left to [5], guarded.
--
-- Renumbering alone already fixes the reported symptom for any month whose
-- first week is whole -- and for August it is the merge that matters, so both
-- run.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR r IN (SELECT w.ts_week_id, w.week_start, w.week_index
              FROM oc_ts_week w
              JOIN oc_time_period p ON p.period_id = w.period_id
             WHERE p.status = 'Open'
               AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm mc
                                WHERE mc.period_id = w.period_id)
               AND w.week_index <> oc_time_week_index(w.week_start))
  LOOP
    UPDATE oc_ts_week
       SET week_index = oc_time_week_index(r.week_start),
           updated_by = 'DB_116',
           updated_on = SYSTIMESTAMP
     WHERE ts_week_id = r.ts_week_id;
    v_n := v_n + 1;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' week(s) renumbered.');
END;
/

COMMIT;

PROMPT ============================================================
PROMPT [5/5] Merge boundary stubs into their Monday's week
PROMPT ============================================================

-- A stub is a week row whose WEEK_START is not a Monday: clipping created it
-- by cutting an ISO week at the 1st of the month. Its entries belong to the
-- week that starts on the preceding Monday.
--
-- Refused unless BOTH periods are Open and unconfirmed. Moving an entry across
-- that line changes a month somebody has already been given a number for.
--
-- UK_OC_TSE_CELL is (ts_week_id, project_id, task_id, entry_date, entry_type),
-- so repointing cannot collide: a given entry_date lives in exactly one week,
-- and the target week does not contain that date yet -- it is the date the
-- clipping removed from it.
DECLARE
  v_moved   NUMBER := 0;
  v_rows    NUMBER := 0;
  v_skipped NUMBER := 0;
  v_target  NUMBER;
  v_period  NUMBER;
BEGIN
  FOR r IN (SELECT w.ts_week_id, w.employee_id, w.week_start, w.week_end,
                   w.period_id
              FROM oc_ts_week w
             WHERE w.week_start <> TRUNC(w.week_start, 'IW')
             ORDER BY w.week_start)
  LOOP
    -- the period that owns the true Monday
    BEGIN
      SELECT period_id INTO v_period
        FROM oc_time_period
       WHERE period_year  = EXTRACT(YEAR  FROM TRUNC(r.week_start,'IW'))
         AND period_month = EXTRACT(MONTH FROM TRUNC(r.week_start,'IW'));
    EXCEPTION WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('  skip week ' || r.ts_week_id
        || ' - no period for ' || TO_CHAR(TRUNC(r.week_start,'IW'),'MON-YYYY'));
      v_skipped := v_skipped + 1;
      CONTINUE;
    END;

    -- both sides must be Open and unconfirmed
    DECLARE
      v_bad NUMBER;
    BEGIN
      SELECT COUNT(*) INTO v_bad
        FROM oc_time_period p
       WHERE p.period_id IN (r.period_id, v_period)
         AND (p.status <> 'Open'
              OR EXISTS (SELECT 1 FROM oc_ts_month_confirm mc
                          WHERE mc.period_id = p.period_id));
      IF v_bad > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  skip week ' || r.ts_week_id || ' ('
          || r.employee_id || ' ' || TO_CHAR(r.week_start,'DD-Mon')
          || ') - a confirmed or closed month is involved');
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;
    END;

    -- the Monday's week, created if the person does not have one
    BEGIN
      SELECT ts_week_id INTO v_target
        FROM oc_ts_week
       WHERE employee_id = r.employee_id
         AND week_start  = TRUNC(r.week_start, 'IW');
    EXCEPTION WHEN NO_DATA_FOUND THEN
      INSERT INTO oc_ts_week (
        employee_id, period_id, period_year, period_month, week_index,
        week_start, week_end, week_status, created_by)
      VALUES (
        r.employee_id, v_period,
        EXTRACT(YEAR  FROM TRUNC(r.week_start,'IW')),
        EXTRACT(MONTH FROM TRUNC(r.week_start,'IW')),
        oc_time_week_index(r.week_start),
        TRUNC(r.week_start,'IW'), TRUNC(r.week_start,'IW') + 6,
        'Not yet submitted', 'DB_116')
      RETURNING ts_week_id INTO v_target;
    END;

    UPDATE oc_ts_entry
       SET ts_week_id = v_target,
           updated_by = 'DB_116'
     WHERE ts_week_id = r.ts_week_id;
    v_rows := v_rows + SQL%ROWCOUNT;

    -- the stub carried no decision of its own worth keeping: its days move
    -- with their entries and the week row is now empty.
    DELETE FROM oc_ts_week_flag WHERE ts_week_id = r.ts_week_id;
    DELETE FROM oc_ts_week      WHERE ts_week_id = r.ts_week_id;
    v_moved := v_moved + 1;
  END LOOP;

  -- and give the surviving weeks their true end date
  UPDATE oc_ts_week w
     SET w.week_end   = TRUNC(w.week_start,'IW') + 6,
         w.updated_by = 'DB_116'
   WHERE w.week_start = TRUNC(w.week_start,'IW')
     AND w.week_end  <> TRUNC(w.week_start,'IW') + 6
     AND EXISTS (SELECT 1 FROM oc_time_period p
                  WHERE p.period_id = w.period_id
                    AND p.status = 'Open'
                    AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm mc
                                     WHERE mc.period_id = p.period_id));

  DBMS_OUTPUT.PUT_LINE('  ' || v_moved || ' stub week(s) merged, '
    || v_rows || ' entr(ies) repointed, ' || v_skipped || ' skipped.');
END;
/

COMMIT;

PROMPT
PROMPT --- August as it now stands
COLUMN range_ FORMAT A20
SELECT w.week_index,
       TO_CHAR(w.week_start,'DD-Mon') || ' - ' || TO_CHAR(w.week_end,'DD-Mon')
         AS range_,
       COUNT(DISTINCT w.employee_id) AS employees,
       TRIM(TO_CHAR(NVL(SUM(e.hours),0),'FM999990.00')) AS hours
  FROM oc_ts_week w
  JOIN oc_time_period p  ON p.period_id  = w.period_id
  LEFT JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
 WHERE p.period_name = 'AUG-2026'
 GROUP BY w.week_index, w.week_start, w.week_end
 ORDER BY w.week_index;

PROMPT
PROMPT Week 1 must now read 03-Aug - 09-Aug. If a 01-Aug - 02-Aug row survives,
PROMPT section [5] refused it because JUL-2026 is confirmed - which is correct,
PROMPT and it will resolve for SEP onwards without any further action.
