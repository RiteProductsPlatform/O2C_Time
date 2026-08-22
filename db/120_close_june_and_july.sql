--==============================================================
-- time/120_close_june_and_july.sql
-- O2C Timesheet Module -- close JUN-2026 and JUL-2026 again, which is what
-- makes them adjustable
--
-- DEVELOPMENT AND SIT ONLY. The other half of db/119.
--
-- RUN ONLY AFTER BOTH MONTHS ARE CONFIRMED. Closing a month whose weeks are
-- still Pending loses nothing, but it ends the walkthrough -- submit_week
-- refuses a closed period, so the employee half cannot be redone without
-- reopening.
--
-- -- WRITES TO THE BASE TABLE, FOR THE SAME REASON AS db/119 ----
--
-- OC_TIME_PERIOD is a view over OC_TIME_PERIOD_BASE joined to the main
-- application's MEC table (db/30). Updating it raises ORA-01779, and where a
-- MEC row exists the main application's value wins anyway. Section [2] checks
-- the view afterwards rather than assuming the write landed.
--
-- -- CLOSING IS NOT TIDYING UP, IT IS THE NEXT TEST --------------
--
-- Two rules pull in opposite directions on period status:
--
--   V_OC_TS_MY_PERIODS
--     adjustment_allowed = CASE WHEN p.status = 'Open' THEN 'N' ...
--
--   TRG_OC_TSADJ_WINDOW (RULE-019)
--     work_date >= ADD_MONTHS(TRUNC(post_period.start_date,'MM'),
--                             -adjustment_months)
--
-- The SOURCE month must be CLOSED -- an open month is edited directly, and
-- offering an adjustment on it would give two ways to change the same day --
-- while the POST month must be open and inside the window. June and July
-- closed, posting into August, satisfies both.
--
-- -- IT RESTORES WHAT db/119 SAVED, NOT WHAT ANYONE REMEMBERS ---
--
-- An earlier draft hard-coded July back to 03-Aug-2026. The real value is
-- 02-Aug-2026, and June's is 01-Sep-2026. A restore that puts back a plausible
-- wrong date is worse than none, because nothing afterwards looks wrong.
-- db/119 writes both into OC_TIME_CONFIG as PERIOD_SAVED_<name> and this reads
-- them back. If the saved row is missing the month is left alone and said so,
-- rather than guessed at.
--
-- Closing touches two columns on one table. No timesheet row, approval or
-- confirmed interface row is affected.
--
-- Idempotent. Reversible -- re-run db/119. Depends on: time/01, 08, 30, 119.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [0/5] Is each month finished
PROMPT ============================================================

-- Not a guard. Closing an unconfirmed month is allowed and sometimes wanted;
-- this is here so the decision is made with the numbers in view.
--
-- COUNT over the weeks themselves, not SUM(CASE) over a LEFT JOIN. The first
-- draft did the latter and reported PENDING = 1 for a month with no weeks at
-- all, because NVL(NULL,'Pending') is 'Pending' on the null row the join
-- manufactures. A count that invents a pending week out of an empty month is
-- exactly the kind of reassuring wrong number this file is meant to avoid.
COLUMN period_name FORMAT A12
SELECT p.period_name,
       (SELECT COUNT(*) FROM oc_ts_week w
         WHERE w.period_id = p.period_id) AS weeks,
       (SELECT COUNT(*) FROM oc_ts_week w
         WHERE w.period_id = p.period_id
           AND w.approval_status = 'Approved') AS approved,
       (SELECT COUNT(*) FROM oc_ts_week w
         WHERE w.period_id = p.period_id
           AND NVL(w.approval_status,'Pending') = 'Pending') AS pending,
       (SELECT COUNT(*) FROM oc_ts_month_confirm mc
         WHERE mc.period_id = p.period_id) AS confirms,
       (SELECT COUNT(*) FROM xx_o2c_timesheet_accrual_if i
         WHERE i.period_year  = p.period_year
           AND i.period_month = p.period_month) AS accrual_rows
  FROM oc_time_period p
 WHERE p.period_name IN ('JUN-2026','JUL-2026')
 ORDER BY p.period_name;

PROMPT
PROMPT WEEKS = 0 means the month was never populated. PENDING > 0 means a week
PROMPT nobody decided. CONFIRMS = 0 means it never reached accrual.

PROMPT ============================================================
PROMPT [1/5] Close them, restoring the saved values
PROMPT ============================================================

DECLARE
  v_saved VARCHAR2(200);
  v_st    VARCHAR2(20);
  v_dc    VARCHAR2(20);
  v_n     NUMBER := 0;
BEGIN
  FOR r IN (SELECT period_name FROM oc_time_period_base
             WHERE period_name IN ('JUN-2026','JUL-2026')
             ORDER BY period_name)
  LOOP
    BEGIN
      SELECT config_value INTO v_saved FROM oc_time_config
       WHERE config_name = 'PERIOD_SAVED_' || r.period_name
         AND scope_key   = 'GLOBAL';
    EXCEPTION WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE('  ' || r.period_name
        || ': no saved value - LEFT ALONE. Run db/119 first, or set it by hand.');
      CONTINUE;
    END;

    v_st := SUBSTR(v_saved, 1, INSTR(v_saved,'|') - 1);
    v_dc := SUBSTR(v_saved, INSTR(v_saved,'|') + 1);

    UPDATE oc_time_period_base
       SET status          = v_st,
           delivery_cutoff = CASE WHEN v_dc = 'NULL' THEN NULL
                                  ELSE TO_DATE(v_dc,'YYYY-MM-DD') END,
           updated_by      = 'DB_120_WALKTHROUGH_END',
           updated_on      = SYSTIMESTAMP
     WHERE period_name = r.period_name;

    v_n := v_n + SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('  ' || r.period_name || ' -> ' || v_st
      || ', delivery cut-off ' || v_dc);
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  base rows restored: ' || v_n);
END;
/

PROMPT ============================================================
PROMPT [2/5] What is adjustable now
PROMPT ============================================================

COLUMN period_state FORMAT A8
COLUMN delivery_cutoff FORMAT A12
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
     AND adjustment_allowed <> 'Y';

  IF v_bad = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  June and July are both adjustable.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  *** ' || v_bad
      || ' month(s) still read ADJ = N, so they are still Open. If MEC_LINKED');
    DBMS_OUTPUT.PUT_LINE('  was Y the main application supplies the status and '
      || 'the base write is ignored.');
  END IF;
END;
/

PROMPT
PROMPT AUG stays Open / Y / N and that is right: it is edited directly, so it
PROMPT is not adjusted.

PROMPT ============================================================
PROMPT [3/5] How far back an adjustment posted into August may reach
PROMPT ============================================================

-- Computed, not asserted: the answer depends on ADJUSTMENT_MONTHS, which
-- finance can change without touching code, and a refusal that names a date is
-- far easier to argue with than one that does not.
COLUMN post_into FORMAT A12
COLUMN earliest  FORMAT A14
SELECT p.period_name AS post_into,
       p.adjustment_months AS months,
       TO_CHAR(ADD_MONTHS(TRUNC(p.start_date,'MM'), -p.adjustment_months),
               'DD-Mon-YYYY') AS earliest,
       CASE WHEN DATE '2026-06-01'
              >= ADD_MONTHS(TRUNC(p.start_date,'MM'), -p.adjustment_months)
            THEN 'June reachable' ELSE 'JUNE IS OUT OF WINDOW' END AS verdict
  FROM oc_time_period p
 WHERE p.period_name = 'AUG-2026';

PROMPT
PROMPT The trigger tests the WORK DATE against this, not the period. If the
PROMPT verdict reads OUT OF WINDOW, widen ADJUSTMENT_MONTHS on AUG-2026 in
PROMPT OC_TIME_PERIOD_BASE rather than editing the rule.

PROMPT ============================================================
PROMPT [4/5] Candidate days for the WBS-change test
PROMPT ============================================================

-- What the test needs: an approved June day on a project that has more than
-- one chargeable task, so the hours have somewhere to move TO.
--
-- RA-014 before you run it: a reallocation that crosses PROJECTS needs BOTH
-- the old and the new project manager to approve. Moving between tasks on the
-- SAME project needs one. They are different code paths -- pick deliberately.
COLUMN nm   FORMAT A24
COLUMN proj FORMAT A10
COLUMN task FORMAT A26
SELECT wk.employee_name AS nm,
       TO_CHAR(e.entry_date,'DD-Mon-YY') AS work_date,
       p.project_number AS proj,
       t.task_name AS task,
       e.hours,
       (SELECT COUNT(*) FROM oc_time_task t2
         WHERE t2.project_id = e.project_id
           AND NVL(t2.chargeable_flag,'Y') = 'Y') AS tasks_on_project
  FROM oc_ts_entry e
  JOIN oc_ts_week     w  ON w.ts_week_id   = e.ts_week_id
  JOIN oc_time_period pr ON pr.period_id   = w.period_id
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
  JOIN oc_time_project p ON p.project_id   = e.project_id
  JOIN oc_time_task    t ON t.task_id      = e.task_id
 WHERE pr.period_name  = 'JUN-2026'
   AND e.entry_type    = 'Actual'
   AND e.is_leave      = 'N'
   AND w.approval_status = 'Approved'
 ORDER BY 6 DESC, wk.employee_name, e.entry_date
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT No rows means June was never approved, so there is nothing settled to
PROMPT correct. TASKS_ON_PROJECT of 1 means there is nowhere to move the hours.

PROMPT ============================================================
PROMPT [5/5] Clear the saved values
PROMPT ============================================================

-- Removed once used, so a later db/119 saves a fresh original rather than
-- restoring a state from two walkthroughs ago.
DELETE FROM oc_time_config WHERE config_name LIKE 'PERIOD_SAVED_%';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('  saved values cleared.');
END;
/
