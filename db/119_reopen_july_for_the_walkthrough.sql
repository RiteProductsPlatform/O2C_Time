--==============================================================
-- time/119_reopen_july_for_the_walkthrough.sql
-- O2C Timesheet Module -- make JUN-2026 and JUL-2026 enterable again so the
-- full cycle can be demonstrated: enter -> submit -> approve -> confirm, and
-- so there are two CLOSED confirmed months to raise retro adjustments against
--
-- DEVELOPMENT AND SIT ONLY.
--
-- -- OC_TIME_PERIOD IS A VIEW, NOT A TABLE ----------------------
--
-- The first version of this script did UPDATE oc_time_period and failed with
-- ORA-01779, "cannot modify a column which maps to a non key-preserved table".
-- That message names the mechanism and not the cause. The cause is db/30:
--
--   RENAME oc_time_period TO oc_time_period_base
--   CREATE VIEW oc_time_period AS
--     SELECT ... NVL(m.status, b.status)                        AS status,
--                NVL(m.delivery_cutoff_date, b.delivery_cutoff) AS delivery_cutoff
--       FROM oc_time_period_base b
--       LEFT JOIN oc_mec_period_src m ON m.start_date = b.start_date;
--
-- A join view is only updatable through its key-preserved side, and Oracle
-- cannot prove which side that is here. So writes go to OC_TIME_PERIOD_BASE.
--
-- -- AND THE BASE MAY NOT WIN --------------------------------------
--
-- This is the part worth reading twice. STATUS and DELIVERY_CUTOFF are
-- NVL(mec, base), so WHERE A MEC ROW EXISTS THE MAIN APPLICATION DECIDES and
-- writing to the base changes nothing visible.
--
-- OC_MEC_PERIOD_SRC is a synonym for o2c_dev.oc_mec_period -- the O2C main
-- application's month-end-close table. Period status is therefore theirs, not
-- ours, for any month they have a row for.
--
-- Section [1] reports MEC_LINKED before touching anything and section [3]
-- checks the base against the view afterwards, so if MEC is overriding you are
-- told in those words rather than left looking at a month that refuses to
-- open. NOTHING HERE WRITES TO o2c_dev. Reaching into the main application's
-- close table to stage a timesheet walkthrough would be the wrong fix by a
-- wide margin -- if MEC owns these months, ask whoever runs the close.
--
-- -- WHICH STEP ACTUALLY CARES ABOUT PERIOD STATUS --------------
--
--   populate_month   no guard at all -- this is how SEP-2026 came to be
--                    populated while Closed
--   submit_week      assert_editable, refuses status <> 'Open' with -20022
--   approve_week     no guard
--   confirm_month    no guard -- RULE-020 (every week Approved) and -20023
--                    (the main-app project link), not status
--
-- One step in four. If the months cannot be opened, everything except employee
-- submission still works.
--
-- -- STATUS ALONE IS NOT ENOUGH ANYWAY --------------------------
--
-- V_OC_TS_MY_PERIODS derives EDITABLE_FLAG from three conditions:
--
--   start_date > today                  -> N
--   status <> 'Open'                    -> N
--   today > delivery_cutoff (RULE-007)  -> N
--
-- Measured 22-Aug: June's delivery cut-off is 01-Sep-2026, still in the
-- future, so June needs only its status. July's is 02-Aug-2026 and has passed,
-- so July needs both. Moving only the status would leave July OPEN AND
-- READ-ONLY AT THE SAME TIME -- the state db/13 recorded finding and having to
-- correct.
--
-- -- WHY JUNE AS WELL --------------------------------------------
--
-- Asked 22-Aug: test a WBS change across the previous three months. One prior
-- month demonstrates confirmation; it does not exercise the adjustment window.
-- TRG_OC_TSADJ_WINDOW (RULE-019) measures from the month being POSTED INTO:
--
--   work_date >= ADD_MONTHS(TRUNC(post_period.start_date,'MM'),
--                           -adjustment_months)
--
-- Posting into August with 3 months reaches 01-May-2026, so June proves the
-- window rather than merely fitting inside it.
--
-- AND THE SOURCE MONTH MUST BE CLOSED AGAIN AFTERWARDS:
-- adjustment_allowed is 'N' while a period is Open, because an open month is
-- edited directly. db/120 closes them, and that is what makes the WBS test
-- possible. Opening without closing again leaves the adjustment path
-- untestable.
--
-- -- WHAT THIS DOES NOT FIX -------------------------------------
--
-- The WEEKLY cut-off is a day-of-week plus a time, not a date, so it cannot be
-- pushed forward the way a delivery cut-off can. June and July submissions
-- will be accepted and flagged LateSubmission. Those weeks did land late; the
-- flag is accurate.
--
-- SEQUENCING: do NOT run weekly defaulting on June or July before the
-- walkthrough. It would default every week and take the employee half away.
--
-- Idempotent. The original values are saved in [2] and db/120 restores exactly
-- those, so the reopen is reversible without anybody remembering the dates.
-- Depends on: time/01, 08, 30, 33.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [0/5] Periods now, and who owns each one
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN period_state FORMAT A8
COLUMN delivery_cutoff FORMAT A12
SELECT period_name, status, period_state, editable_flag AS edit,
       adjustment_allowed AS adj, delivery_cutoff
  FROM v_oc_ts_my_periods
 ORDER BY period_year, period_month;

PROMPT
PROMPT --- MEC_LINKED = Y means the MAIN APPLICATION supplies status and the
PROMPT --- delivery cut-off for that month, and this script cannot move them.
COLUMN base_status FORMAT A10
COLUMN view_status FORMAT A10
SELECT p.period_name,
       p.mec_linked,
       b.status                                    AS base_status,
       p.status                                    AS view_status,
       TO_CHAR(b.delivery_cutoff,'YYYY-MM-DD')     AS base_cutoff,
       p.delivery_cutoff                           AS view_cutoff
  FROM oc_time_period p
  JOIN oc_time_period_base b ON b.period_id = p.period_id
 WHERE p.period_name IN ('JUN-2026','JUL-2026','AUG-2026')
 ORDER BY p.period_year, p.period_month;

PROMPT ============================================================
PROMPT [1/5] Stop here if MEC owns these months
PROMPT ============================================================

DECLARE
  v_linked NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_linked
    FROM oc_time_period
   WHERE period_name IN ('JUN-2026','JUL-2026')
     AND mec_linked = 'Y';

  IF v_linked > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  WARNING: ' || v_linked
      || ' of the two months is MEC-linked. The UPDATE below will succeed and');
    DBMS_OUTPUT.PUT_LINE('  the view will NOT change, because status is '
      || 'NVL(mec, base). Section [4] will say so.');
    DBMS_OUTPUT.PUT_LINE('  Opening it is then a month-end-close action in the '
      || 'main application, not ours.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  Neither month is MEC-linked - the base value wins '
      || 'and this script is sufficient.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [2/5] Save the current values so db/120 can restore them exactly
PROMPT ============================================================

-- Saved rather than hard-coded. The first draft of db/120 restored July to
-- 03-Aug from memory; the real value is 02-Aug, and June's is 01-Sep. A
-- restore that quietly puts back the wrong date is worse than no restore,
-- because nothing afterwards looks wrong.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR r IN (SELECT period_name, status,
                   TO_CHAR(delivery_cutoff,'YYYY-MM-DD') AS dc
              FROM oc_time_period_base
             WHERE period_name IN ('JUN-2026','JUL-2026'))
  LOOP
    MERGE INTO oc_time_config t
    USING (SELECT 'PERIOD_SAVED_' || r.period_name AS nm FROM dual) s
       ON (t.config_name = s.nm AND t.scope_key = 'GLOBAL')
     WHEN MATCHED THEN UPDATE SET
       -- NOT overwritten on a re-run: the first save is the true original.
       -- Re-running this after [3] would otherwise save the OPENED state and
       -- db/120 would "restore" the month to Open.
       updated_on = t.updated_on
     WHEN NOT MATCHED THEN INSERT
       (config_name, config_type, config_value, scope_key, description,
        created_by)
     VALUES
       ('PERIOD_SAVED_' || r.period_name, 'business',
        r.status || '|' || NVL(r.dc,'NULL'), 'GLOBAL',
        'db/119 saved the pre-walkthrough status and delivery cut-off so '
     || 'db/120 can put them back exactly.', 'DB_119');
    v_n := v_n + 1;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' period(s) considered for saving.');
END;
/

COLUMN config_name  FORMAT A28
COLUMN config_value FORMAT A24
SELECT config_name, config_value FROM oc_time_config
 WHERE config_name LIKE 'PERIOD_SAVED_%' ORDER BY config_name;

PROMPT ============================================================
PROMPT [3/5] Open them -- on the BASE table
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_period_base
     SET status          = 'Open',
         -- Only moved where it has actually passed. June's is 01-Sep and still
         -- ahead, so leaving it alone keeps one fewer thing to restore.
         delivery_cutoff = CASE
                             WHEN delivery_cutoff IS NULL
                               OR delivery_cutoff >= TRUNC(SYSDATE)
                             THEN delivery_cutoff
                             ELSE DATE '2026-09-30'
                           END,
         updated_by      = 'DB_119_WALKTHROUGH',
         updated_on      = SYSTIMESTAMP
   WHERE period_name IN ('JUN-2026','JUL-2026');
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  base rows updated: ' || v_n || ' (expected 2)');
END;
/

PROMPT ============================================================
PROMPT [4/5] Did it reach the view
PROMPT ============================================================

SELECT period_name, status, period_state, editable_flag AS edit,
       adjustment_allowed AS adj, delivery_cutoff
  FROM v_oc_ts_my_periods
 ORDER BY period_year, period_month;

DECLARE
  v_bad NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_bad
    FROM v_oc_ts_my_periods
   WHERE period_name IN ('JUN-2026','JUL-2026')
     AND (status <> 'Open' OR editable_flag <> 'Y');

  IF v_bad = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Both months are Open and editable. Carry on.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  *** ' || v_bad || ' month(s) did NOT open.');
    DBMS_OUTPUT.PUT_LINE('  If MEC_LINKED was Y in [0], the main application '
      || 'is supplying the status and');
    DBMS_OUTPUT.PUT_LINE('  the base value is being ignored - that is the '
      || 'cause, and it is not fixable here.');
    DBMS_OUTPUT.PUT_LINE('  Everything except EMPLOYEE SUBMISSION still works '
      || 'on a closed month: populate,');
    DBMS_OUTPUT.PUT_LINE('  default, approve and confirm are all ungated.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [5/5] Who June and July will populate for
PROMPT ============================================================

-- populate_month seeds a day only if the allocation SPANS it, so somebody
-- whose allocation begins in August contributes nothing to June or July.
COLUMN nm    FORMAT A26
COLUMN projs FORMAT A40
SELECT w.employee_id, w.employee_name AS nm,
       NVL(SUM(al.alloc_pct),0) AS pct_jun_jul,
       LISTAGG(p.project_number || '@' || al.alloc_pct, ', ')
         WITHIN GROUP (ORDER BY p.project_number) AS projs
  FROM oc_time_worker w
  LEFT JOIN oc_time_allocation al
         ON al.employee_id = w.employee_id
        AND al.status      = 'Active'
        AND al.start_date <= DATE '2026-07-31'
        AND NVL(al.end_date, DATE '4712-12-31') >= DATE '2026-06-01'
  LEFT JOIN oc_time_project p ON p.project_id = al.project_id
 WHERE w.employee_id IN ('RI9001','RI2894','RI2824','RI2249','RI2900','RI2963',
                         'RI2935','RI2985','RI3004','RI2914','CRI0406','CRI0398')
 GROUP BY w.employee_id, w.employee_name
 ORDER BY w.employee_name;

PROMPT
PROMPT A zero is somebody whose allocation starts after July. No June or July
PROMPT timesheet for them, and that is correct rather than a gap to fill.

PROMPT ============================================================
PROMPT NEXT -- the order is not interchangeable
PROMPT ============================================================
PROMPT
PROMPT   1. POST jobs/populate/47              JUN-2026
PROMPT   2. POST jobs/populate/43              JUL-2026
PROMPT   3. POST jobs/populate/46              AUG-2026
PROMPT
PROMPT   4. WALKTHROUGH on June and July: employee enters and submits, manager
PROMPT      approves, then confirm each month to accrual.
PROMPT
PROMPT   5. db/120_close_june_and_july.sql     makes them adjustable
PROMPT   6. ADJUSTMENT TEST: change the WBS/task on a June day and post the
PROMPT      correction into AUG-2026.
PROMPT
PROMPT   7. POST jobs/defaulting/46            AUG weekly cut-off, employee
PROMPT   8. POST jobs/delivery-defaulting/46   AUG delivery cut-off, manager
PROMPT
PROMPT DO NOT run defaulting on 47 or 43 -- it would default every week before
PROMPT anybody submits. August is the month to default: nothing is submitted
PROMPT there and defaulting it is the honest outcome.
