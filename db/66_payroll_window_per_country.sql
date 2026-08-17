--==============================================================
-- time/66_payroll_window_per_country.sql
-- O2C Timesheet Module — the cut-off belongs to the country, everywhere
--
-- The Payroll Configuration screen now carries four United States rows, one per
-- month, and its own banner states the rule this script implements:
--
--     "A cut-off date belongs to the COUNTRY rather than the period,
--      so one row carries one cut-off date."
--
--     Country        Start        End          Payout       Cut-off      Release
--     United States  01/06/2026   30/06/2026   30/06/2026   28/06/2026   60 days
--     United States  01/07/2026   31/07/2026   31/07/2026   26/07/2026   60 days
--     United States  01/08/2026   31/08/2026   31/08/2026   30/08/2026   60 days
--     United States  01/09/2026   30/09/2026   30/09/2026   01/09/2026   60 days
--
-- run_salary_stopping honoured that for the PER-PERSON GATE and not for the
-- WINDOW, and read a different table for each:
--
--   the window   OC_TIME_PERIOD.PAYROLL_CUTOFF        ours
--   the gate     oc_time_payroll_cutoff(emp, period)  theirs, per country
--
-- Two sources for one fact. They can disagree, and when they do the job holds
-- pay for dates one of them says are not yet due. Both now come from the
-- configuration.
--
-- THREE CORRECTIONS, and the third is why holds exist that should not:
--
-- 1. HOLD_RELEASE_DAYS comes from the configuration. It was
--    NVL(oc_time_period.hold_release_days, 60) -- our column, defaulting to
--    CFG-012's 60 -- while db/53 had already built oc_time_hold_release_days()
--    to read theirs and nothing ever called it. The two agree at 60 today,
--    which is exactly why nobody noticed; change it on the screen and only one
--    of them would move.
--
-- 2. The window is derived per COUNTRY, from consecutive configured cut-offs.
--    Contiguous by construction -- each run covers the day after the previous
--    cut-off up to this one -- so no date can fall between two runs and never
--    be examined. For the United States above, August is 27-Jul to 30-Aug.
--
-- 3. AUGUST'S CUT-OFF IS NOW 30-AUG, WHICH HAS NOT HAPPENED. It was 01-Aug
--    when the job last ran, so 118 holds were opened legitimately under the old
--    configuration and are now premature. Section [3] releases them: they are
--    not corrections, and leaving them would tell 118 people their pay is held
--    for a deadline still two weeks away.
--
-- WHAT THIS DOES *NOT* DO. The screen also carries START_DATE, END_DATE and
-- PAYOUT_DATE, and the window above ignores them -- it chains cut-offs instead.
-- Section [4] reports the actual column names on the source table so that can
-- be settled with facts. The two readings differ and the difference matters:
-- chaining covers 27-31 July inside the August run, while START_DATE would put
-- August at 01-Aug to 30-Aug and leave those five days examined by no run at
-- all. That is a business question, not a technical one.
--
-- Idempotent. Depends on: time/09, 53, 54.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_HOLD_RELEASE_DAYS' AND status = 'VALID';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'OC_TIME_HOLD_RELEASE_DAYS is missing. Run 53_payroll_cutoff.sql first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] What the configuration says, and what we were using
PROMPT ============================================================

COLUMN country FORMAT A16
COLUMN period_name FORMAT A11
SELECT x.period_name,
       x.country,
       TO_CHAR(x.payroll_cutoff,'DD-Mon-YY') AS their_cutoff,
       x.hold_release_days                   AS their_release_days,
       TO_CHAR(p.payroll_cutoff,'DD-Mon-YY') AS our_cutoff,
       p.hold_release_days                   AS our_release_days,
       CASE WHEN NVL(p.payroll_cutoff, DATE '4712-12-31')
                 <> NVL(x.payroll_cutoff, DATE '4712-12-31')
            THEN 'DIFFER' ELSE 'agree' END   AS cutoff
  FROM v_oc_time_payroll_cutoff x
  JOIN oc_time_period p ON p.period_id = x.period_id
 ORDER BY p.start_date, x.country;

PROMPT
PROMPT THEIR_CUTOFF is now the only one that counts. OUR_CUTOFF is shown to make
PROMPT the drift visible; it is no longer read by salary stopping.

PROMPT ============================================================
PROMPT [2/5] OC_TIME_PAYROLL_WINDOW — the window, per country per period
PROMPT ============================================================

-- One row per country per period, giving the span of dates that period's
-- payroll run is responsible for. Built from the configured cut-offs alone:
-- the run covers the day after the previous cut-off, up to this one.
--
-- A view rather than logic inside the job, so "which dates did we examine for
-- this country in August" can be answered without reading PL/SQL -- which is
-- the first question anybody asks about a hold.
CREATE OR REPLACE VIEW v_oc_time_payroll_window AS
SELECT x.period_id,
       x.period_name,
       x.country,
       x.payroll_cutoff,
       x.hold_release_days,
       -- The previous configured cut-off for THIS COUNTRY, +1. Ordering is by
       -- the cut-off itself rather than by period, so a country whose cut-offs
       -- are not in period order still chains correctly.
       NVL(LAG(x.payroll_cutoff) OVER (PARTITION BY x.country
                                       ORDER BY x.payroll_cutoff) + 1,
           -- Nothing earlier to chain from: bound at the period's own start
           -- rather than leaving the first run unbounded.
           p.start_date)                    AS window_from,
       -- Never past the cut-off, and never into the future. Holding pay for
       -- dates that have not happened is indefensible and the rows look exactly
       -- like real ones.
       LEAST(x.payroll_cutoff, TRUNC(SYSDATE)) AS window_to,
       CASE WHEN TRUNC(SYSDATE) > x.payroll_cutoff THEN 'Y' ELSE 'N' END
         AS cutoff_passed
  FROM v_oc_time_payroll_cutoff x
  JOIN oc_time_period p ON p.period_id = x.period_id;

COLUMN window FORMAT A26
SELECT w.period_name, w.country,
       TO_CHAR(w.payroll_cutoff,'DD-Mon-YY') AS cutoff,
       TO_CHAR(w.window_from,'DD-Mon') || ' .. '
         || TO_CHAR(w.window_to,'DD-Mon')    AS window,
       w.cutoff_passed,
       w.hold_release_days AS rel_days
  FROM v_oc_time_payroll_window w
 ORDER BY w.country, w.payroll_cutoff;

PROMPT
PROMPT CUTOFF_PASSED = N means this country's cut-off is still in the future and
PROMPT salary stopping must hold nobody for it, however many weeks are defaulted.

PROMPT ============================================================
PROMPT [3/5] Release holds opened before the cut-off moved
PROMPT ============================================================

-- These were correct when they were written -- August's configured cut-off was
-- 01-Aug -- and are wrong now that it is 30-Aug. Releasing rather than deleting
-- keeps the trail: somebody was told their pay was held, and the record of that
-- being withdrawn is worth as much as the hold was.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR h IN (SELECT h.hold_id, h.employee_id, h.period_id, w.country,
                   TO_CHAR(w.payroll_cutoff,'DD-Mon-YY') AS cut
              FROM oc_ts_salary_hold h
              JOIN oc_time_worker k ON k.employee_id = h.employee_id
              JOIN v_oc_time_payroll_window w
                ON w.period_id = h.period_id
               AND w.country   = k.base_country
             WHERE h.salary_status = 'Held'
               AND w.cutoff_passed = 'N')
  LOOP
    UPDATE oc_ts_salary_hold
       SET salary_status = 'Released',
           released_on   = SYSTIMESTAMP,
           released_by   = 'CUTOFF_MOVED',
           remarks       = SUBSTR('Released automatically: the configured '
                        || 'payroll cut-off for ' || h.country || ' is '
                        || h.cut || ', which has not passed. The hold was '
                        || 'opened under an earlier configuration.', 1, 400)
     WHERE hold_id = h.hold_id;
    v_n := v_n + 1;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' premature hold(s) released');
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Nothing to release - every open hold sits after its '
                      || 'country''s cut-off.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [4/5] The columns the configuration actually has
PROMPT ============================================================

-- Reported rather than assumed. The screen shows Start Date, End Date and
-- Payout Date; guessing their column names has already cost time twice today
-- (HRC_SQLLOADER against a registered owner, PJR_ASSIGNMENT against
-- PJT_PROJECT_RESOURCE), so the names are read from the dictionary and the
-- window question is settled afterwards with facts.
COLUMN column_name FORMAT A28
COLUMN data_type FORMAT A14
SELECT c.column_name, c.data_type, c.nullable
  FROM all_tab_columns c
  JOIN user_synonyms s
    ON s.table_name = c.table_name
   AND NVL(s.table_owner, USER) = c.owner
 WHERE s.synonym_name = 'OC_PAYROLL_CONFIG_SRC'
 ORDER BY c.column_id;

PROMPT
PROMPT If START/END columns exist, decide which defines the window:
PROMPT
PROMPT   chaining cut-offs  August = 27-Jul .. 30-Aug   contiguous, no date
PROMPT                      is ever missed
PROMPT   START_DATE/END     August = 01-Aug .. 30-Aug   27-31 July fall in no
PROMPT                      run at all, since July's cut-off was 26-Jul
PROMPT
PROMPT This file chains. Switching is one line in V_OC_TIME_PAYROLL_WINDOW.

PROMPT ============================================================
PROMPT [5/5] Next
PROMPT ============================================================
PROMPT
PROMPT Re-run 09_pkg_oc_time.sql -- run_salary_stopping is rewired there to read
PROMPT this view and oc_time_hold_release_days(). Then:
PROMPT
PROMPT   POST /oc/time/approval/salaryhold/run/46
PROMPT
PROMPT and it should hold NOBODY for AUG-2026 while the cut-off is 30-Aug.
