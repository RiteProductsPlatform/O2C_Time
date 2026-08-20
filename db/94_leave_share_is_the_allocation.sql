--==============================================================
-- time/94_leave_share_is_the_allocation.sql
-- O2C Timesheet Module — a project carries the leave it was allocated, no more
--
-- Reported from the Monthly Summary for 555 / AUG-2026: Santosh Kumar Kanala's
-- LEAVE column reads 8.00 for a single day's absence, while Sam Joshuva S reads
-- 8.00 for FOUR days. The two cells are the same number for entirely different
-- reasons, and only one of them is right.
--
-- V_OC_TS_LEAVE_SHARE divided the day by PCT_TOTAL -- the sum of that person's
-- allocation percentages -- instead of by 100:
--
--   ROUND(absence_hours * alloc_pct / NULLIF(pct_total,0), 2)
--
-- which is only correct when somebody's allocations happen to add to exactly
-- 100. Measured across this team, three of seven do not:
--
--   employee            total    8h absence gave 555     should be
--   RI2824  Sam          100%    2.00                    2.00
--   RI9001  Navamani     100%    2.00                    2.00
--   RI2894  Santosh       50%    8.00                    4.00
--   CRI0398 Kishore      200%    4.00                    8.00
--   7781    User Rite    500%    1.60                    8.00
--
-- THE TELL IS INSIDE SANTOSH'S OWN ROW. 555 gets FOUR hours a day from him when
-- he works -- his billable 84.00 is 21 days at four -- and EIGHT when he is
-- away. The same person cannot be worth twice as much to a project absent as
-- present. He is 50% allocated; a day of his leave costs 555 four hours, and
-- the other four were never 555's to lose.
--
-- A SECOND BRANCH HAD THE SAME FAULT and would have survived fixing the first.
-- When somebody has one allocation, seq = n on their only row, so this fired:
--
--   CASE WHEN seq = n THEN absence_hours - NVL(prior_sum,0) ...
--
-- 8 - 0 = 8. The residue rule handed the whole day to the last project. It
-- existed to make the shares sum exactly to the day, and that is the property
-- being withdrawn, so the rule goes with it.
--
-- ── THE RULE NOW, AND IT IS THE ONE ALREADY USED FOR LOSS_HOURS ──────────
--
--   share = ROUND(absence_hours * alloc_pct / 100 * 4) / 4
--
-- Divided by 100. No normalising in either direction, by decision on 21-Aug:
-- an over-allocated person's projects each carry their full claim even though
-- that sums to more hours than the person was away. Over-allocation is a data
-- error in PPM and correcting it here would hide it -- Kishore at 100% on two
-- projects loses each of them a whole day, which is what each contract says.
--
-- QUARTER-ROUNDED, not to two decimals as before. CHK_OC_TSE_QUARTER on
-- OC_TS_ENTRY is MOD(ABS(hours)*100,25)=0 and applies to leave rows like any
-- other. The old view rounded to 2dp and leaned on the residue to make the sum
-- come out; with the residue gone a 10% allocation would have written 0.80 and
-- been refused. The pod carries 10 / 25 / 40 / 50 / 100, so that was reachable.
--
-- ── AND THE DISPLACEMENT TEST HAD TO MOVE WITH IT ────────────────────────
--
-- oc_time_leave_displace decides "was this a full day off" by summing the
-- APPORTIONED LEAVE ENTRIES on the day and comparing to the standard. That
-- worked only while the shares summed to the whole day. With Santosh's share
-- correctly at 4 against a standard of 8, the test fails and his four worked
-- hours would stay on a day he was provably absent -- 4 leave + 4 work, on the
-- sheet a manager approves.
--
-- The honest test is the ABSENCE itself, which is what "away all day" actually
-- means, so it now reads OC_TIME_ABSENCE rather than the rows derived from it.
-- Santosh: absence 8 >= standard 8, so his 555 line is put aside and the day
-- carries 4 hours of leave and nothing else.
--
-- Idempotent. Supersedes db/79 [1/4] and [2/4], and db/80 [2/4].
-- Depends on: time/03, 09, 79, 80.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views WHERE view_name = 'V_OC_TS_LEAVE_SHARE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/79 has not been run: V_OC_TS_LEAVE_SHARE is missing.');
  END IF;
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TS_ENTRY' AND column_name = 'PRE_LEAVE_HOURS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'db/80 has not been run here: '
      || 'OC_TS_ENTRY.PRE_LEAVE_HOURS is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] What the split says today, before changing it
PROMPT ============================================================

COLUMN emp FORMAT A10
COLUMN nm  FORMAT A22
SELECT ls.employee_id AS emp, w.employee_name AS nm,
       TO_CHAR(ls.absence_date,'DD-Mon') AS on_date,
       p.project_number, ls.alloc_pct, ls.pct_total,
       ls.day_hours, ls.share_hours AS now_share,
       ROUND(ls.day_hours * ls.alloc_pct / 100 * 4) / 4 AS will_be
  FROM v_oc_ts_leave_share ls
  JOIN oc_time_worker  w ON w.employee_id = ls.employee_id
  JOIN oc_time_project p ON p.project_id  = ls.project_id
 ORDER BY ls.employee_id, ls.absence_date, p.project_number;

PROMPT
PROMPT NOW_SHARE and WILL_BE agree wherever PCT_TOTAL is 100, and differ
PROMPT everywhere else. That is the whole of the defect.

PROMPT ============================================================
PROMPT [2/5] V_OC_TS_LEAVE_SHARE — allocation share, nothing else
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_leave_share AS
WITH day_abs AS (
  SELECT ab.employee_id, ab.absence_date,
         SUM(ab.absence_hours) AS absence_hours,
         MAX(ab.absence_type) KEEP (DENSE_RANK FIRST
             ORDER BY ab.absence_hours DESC) AS absence_type
    FROM oc_time_absence ab
   WHERE ab.approval_status = 'Approved'
   GROUP BY ab.employee_id, ab.absence_date
),
alloc AS (
  SELECT d.employee_id, d.absence_date, d.absence_hours, d.absence_type,
         al.project_id, al.alloc_pct,
         -- Kept for diagnosis only. Nothing divides by it any more; it is here
         -- so a reader can see at a glance whether a person's allocations add
         -- up, which is the thing that used to change the answer silently.
         SUM(al.alloc_pct) OVER (PARTITION BY d.employee_id, d.absence_date)
           AS pct_total
    FROM day_abs d
    JOIN oc_time_allocation al
      ON al.employee_id = d.employee_id
     AND al.status      = 'Active'
     AND d.absence_date BETWEEN al.start_date
                        AND NVL(al.end_date, d.absence_date)
)
SELECT employee_id, absence_date, absence_type, project_id, alloc_pct,
       pct_total, absence_hours AS day_hours,
       -- THE PROJECT'S OWN SHARE. Divided by 100, not by the person's total,
       -- so a 50%-allocated person costs a project half a day and a person on
       -- two full-time projects costs each of them a whole one.
       --
       -- Quarter-rounded because CHK_OC_TSE_QUARTER admits nothing else, and
       -- there is no residue row left to absorb the difference: each project's
       -- share stands on its own and none of them reconcile against the day.
       ROUND(absence_hours * alloc_pct / 100 * 4) / 4 AS share_hours
  FROM alloc
 -- A project that loses nothing gets no row, so the retract half of
 -- oc_time_sync_leave removes any leave entry standing behind a share that has
 -- rounded away to nothing.
 WHERE ROUND(absence_hours * alloc_pct / 100 * 4) / 4 > 0;

PROMPT ============================================================
PROMPT [3/5] The full-day test reads the absence, not its shares
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_leave_displace(
  p_from        IN  DATE,
  p_to          IN  DATE,
  p_employee_id IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'ABSENCE_SYNC',
  o_put_aside   OUT NUMBER,
  o_given_back  OUT NUMBER)
IS
BEGIN
  -- ── PUT ASIDE ──────────────────────────────────────────────
  -- A day whose leave covers the whole standard day carries no worked hours
  -- (RULE-008). The value is remembered, not discarded.
  UPDATE oc_ts_entry e
     SET e.pre_leave_hours = e.hours,
         e.hours           = 0,
         e.updated_by      = p_actor,
         e.updated_on      = SYSTIMESTAMP
   WHERE e.is_leave        = 'N'
     AND e.entry_type     IN ('Actual','Default')
     AND e.hours           > 0
     AND e.pre_leave_hours IS NULL
     AND e.entry_date BETWEEN p_from AND p_to
     AND EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id
                    AND (p_employee_id IS NULL OR w.employee_id = p_employee_id))
     -- THE ABSENCE, NOT THE LEAVE ROWS DERIVED FROM IT.
     --
     -- This summed the apportioned leave entries on the day and compared that
     -- to the standard, which held only while the shares summed to the whole
     -- day. They no longer do: a 50%-allocated person's share is half a day, so
     -- the old test would leave their worked hours standing on a day they were
     -- provably absent -- 4 hours of leave beside 4 hours of work.
     --
     -- "Was this person away all day" is a question about the person, and
     -- OC_TIME_ABSENCE is where that is recorded. Still compared against the
     -- standard on the DAY rather than the worker's global figure, so a
     -- nine-hour shift is judged against nine.
     AND (SELECT NVL(SUM(ab.absence_hours),0)
            FROM oc_time_absence ab
            JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
           WHERE ab.employee_id     = w2.employee_id
             AND ab.absence_date    = e.entry_date
             AND ab.approval_status = 'Approved')
         >= (SELECT NVL(MAX(s.standard_hours),0) FROM oc_ts_entry s
              WHERE s.ts_week_id = e.ts_week_id
                AND s.entry_date = e.entry_date)
     AND (SELECT NVL(MAX(s.standard_hours),0) FROM oc_ts_entry s
           WHERE s.ts_week_id = e.ts_week_id
             AND s.entry_date = e.entry_date) > 0;
  o_put_aside := SQL%ROWCOUNT;

  -- ── GIVE BACK ──────────────────────────────────────────────
  -- The leave has gone from the day and the cell has not been touched since,
  -- so what it held before is what it should hold now. Still keyed on the
  -- LEAVE ROWS rather than the absence: a share that has gone because the
  -- allocation ended should hand the hours back just as a withdrawal does.
  UPDATE oc_ts_entry e
     SET e.hours           = e.pre_leave_hours,
         e.pre_leave_hours = NULL,
         e.updated_by      = p_actor,
         e.updated_on      = SYSTIMESTAMP
   WHERE e.pre_leave_hours IS NOT NULL
     AND e.hours            = 0
     AND e.is_leave         = 'N'
     AND e.entry_date BETWEEN p_from AND p_to
     AND EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id
                    AND (p_employee_id IS NULL OR w.employee_id = p_employee_id))
     AND NOT EXISTS (SELECT 1 FROM oc_ts_entry l
                      WHERE l.ts_week_id = e.ts_week_id
                        AND l.entry_date = e.entry_date
                        AND l.is_leave   = 'Y'
                        AND l.hours      > 0);
  o_given_back := SQL%ROWCOUNT;
END oc_time_leave_displace;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] Re-apply what is already on the sheets
PROMPT ============================================================

-- Changing the view changes nothing already written. oc_time_sync_leave's
-- apply half MERGEs each project's share onto its leave row, so running it over
-- every open period rewrites the stale ones -- and its retract half removes any
-- leave row whose share has gone. The displacement above runs last inside it.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR p IN (SELECT period_id, period_name, start_date, end_date
              FROM oc_time_period
             WHERE status = 'Open'
             ORDER BY start_date)
  LOOP
    oc_time_sync_leave(p.start_date, p.end_date, NULL, 'FIX_90');
    DBMS_OUTPUT.PUT_LINE('  re-split ' || p.period_name);
    v_n := v_n + 1;
  END LOOP;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  No open period to re-split.');
  END IF;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

PROMPT
PROMPT Every leave entry against what the allocation says it should be.
PROMPT MISMATCH means a sheet still disagrees with the rule.

COLUMN nm FORMAT A22
SELECT w.employee_name AS nm,
       TO_CHAR(e.entry_date,'DD-Mon') AS on_date,
       p.project_number, ls.alloc_pct, e.hours AS on_sheet,
       ls.share_hours AS should_be,
       CASE WHEN e.hours = ls.share_hours THEN 'ok' ELSE 'MISMATCH' END AS state
  FROM oc_ts_entry e
  JOIN oc_ts_week  w2 ON w2.ts_week_id = e.ts_week_id
  JOIN oc_time_worker w ON w.employee_id = w2.employee_id
  JOIN oc_time_project p ON p.project_id = e.project_id
  LEFT JOIN v_oc_ts_leave_share ls
         ON ls.employee_id  = w2.employee_id
        AND ls.absence_date = e.entry_date
        AND ls.project_id   = e.project_id
 WHERE e.is_leave = 'Y'
 ORDER BY w.employee_name, e.entry_date, p.project_number;

PROMPT
PROMPT And the days that still carry both a full absence and worked hours.
PROMPT Must be none: the absence covers the standard day, so nothing was worked.

SELECT w.employee_name AS nm, TO_CHAR(e.entry_date,'DD-Mon') AS on_date,
       SUM(CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END) AS leave_hrs,
       SUM(CASE WHEN e.is_leave = 'N' THEN e.hours ELSE 0 END) AS worked_hrs,
       MAX(e.standard_hours) AS std
  FROM oc_ts_entry e
  JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
  JOIN oc_time_worker w ON w.employee_id = w2.employee_id
 WHERE e.entry_type IN ('Actual','Default')
   AND EXISTS (SELECT 1 FROM oc_time_absence ab
                WHERE ab.employee_id     = w2.employee_id
                  AND ab.absence_date    = e.entry_date
                  AND ab.approval_status = 'Approved'
                  AND ab.absence_hours  >= NVL(e.standard_hours, 8))
 GROUP BY w.employee_name, e.entry_date
HAVING SUM(CASE WHEN e.is_leave = 'N' THEN e.hours ELSE 0 END) > 0
 ORDER BY 1, 2;

PROMPT
PROMPT Santosh Kumar Kanala on 20-Aug should now read 4.00 of leave on 555 and
PROMPT nothing worked. Sam Joshuva S keeps 2.00 a day across four days, which
PROMPT was already right - his three allocations happen to total exactly 100.
