--==============================================================
-- time/105_bisect_the_confirm.sql
-- O2C Timesheet Module — run confirm_month's four statements one at a time
--
-- POST /oc/time/approval/confirm on JUL-2026 / 555 still answers
--
--   500  {"error":"ORA-00979: not a GROUP BY expression"}
--
-- and that is now the only thing between July and accrual: as of today every
-- one of the six employees on 555 reads Approved, so the RULE-020 gate passes
-- and this is a NORMAL confirm, not even an advance closure.
--
-- ── WHY THIS IS A SCRIPT AND NOT ANOTHER READ-THROUGH ────────
--
-- db/103 already proved the interface INSERT's SELECT is fine: run standalone
-- with literals it returned 116 rows and the scalar subquery resolved all three
-- projects. I have twice concluded from reading that the fault must be in a
-- particular statement and been wrong both times, because PL/SQL reports the
-- line of the enclosing statement and the arithmetic that maps a body line back
-- to a file line is exactly what I keep getting wrong.
--
-- So this stops reading. confirm_month runs four statements against the
-- database; this runs the same four, separately, in order, each with its own
-- handler, and prints which one raises. Oracle names the column.
--
-- The four, in the order confirm_month executes them:
--
--   [3]  the RULE-020 gate   SELECT COUNT(*), SUM(CASE...) FROM v_oc_ts_month_summary
--   [4]  the header        MERGE INTO oc_ts_month_confirm
--   [5a] the payload       INSERT INTO xx_o2c_timesheet_accrual_if SELECT ...
--   [6a] the roll-up       UPDATE oc_ts_month_confirm SET (5 cols) = (SELECT 5 aggregates)
--
-- and after each of the two untested ones, [5b] / [6b] run a proposed rewrite,
-- so a single run says both WHICH statement is wrong and WHETHER the fix works.
--
-- [5] is the one never yet tested. It is the only statement in the function
-- that puts aggregates inside a MULTI-COLUMN SET whose subquery is correlated
-- back to the row being updated -- and that shape is a far better fit for
-- ORA-00979 than anything in [4], which db/103 cleared.
--
-- ** NOTHING IS COMMITTED. ** Every section runs inside one transaction and the
-- last statement is a ROLLBACK, so the MERGE and the INSERT are undone even on
-- the success path. Re-runnable as often as you like. It does NOT confirm July;
-- it only finds out why confirming July fails.
--
-- Depends on: time/09, 82, 101.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/6] What we are aiming at
PROMPT ============================================================

COLUMN pname FORMAT A26
SELECT p.project_id, p.project_number, p.project_name AS pname,
       pe.period_id, pe.period_name, pe.status
  FROM oc_time_project p
 CROSS JOIN oc_time_period pe
 WHERE p.project_number = '555' AND pe.period_name = 'JUL-2026';

PROMPT
PROMPT And whether anything is already confirmed for it:

SELECT confirm_id, confirm_type, accrual_status, accrual_rows,
       TO_CHAR(confirmed_on,'DD-Mon-YY HH24:MI') AS confirmed_on
  FROM oc_ts_month_confirm
 WHERE project_id = (SELECT project_id FROM oc_time_project WHERE project_number = '555')
   AND period_id  = (SELECT period_id  FROM oc_time_period  WHERE period_name = 'JUL-2026');

PROMPT
PROMPT (no rows = never confirmed, which is what we expect)

PROMPT ============================================================
PROMPT [2] .. [6b] Each statement alone, and its proposed rewrite
PROMPT ============================================================

DECLARE
  v_project NUMBER;
  v_period  NUMBER;
  v_year    NUMBER;
  v_month   NUMBER;
  v_pname   VARCHAR2(30);
  v_emps    NUMBER;
  v_appr    NUMBER;
  v_confirm NUMBER;
  v_rows    NUMBER;
  v_batch   VARCHAR2(64);
  v_err     VARCHAR2(500);
  v_type    VARCHAR2(30) := 'Normal';
  v_trace   VARCHAR2(64) := 'BISECT-105';
  v_failed  VARCHAR2(30) := 'none';
  v_fixed   VARCHAR2(30) := 'none';
  v_err2    VARCHAR2(500);
BEGIN
  SELECT project_id INTO v_project FROM oc_time_project WHERE project_number = '555';
  SELECT period_id, period_year, period_month, period_name
    INTO v_period, v_year, v_month, v_pname
    FROM oc_time_period WHERE period_name = 'JUL-2026';

  DBMS_OUTPUT.PUT_LINE('project ' || v_project || ' period ' || v_period
                    || ' (' || v_pname || ' ' || v_year || '-' || v_month || ')');
  DBMS_OUTPUT.PUT_LINE(' ');

  ----------------------------------------------------------------
  -- [3/6] the RULE-020 gate
  ----------------------------------------------------------------
  BEGIN
    SELECT COUNT(*),
           SUM(CASE WHEN month_status = 'Approved'
                      OR (v_type = 'Advance closure'
                          AND month_status = 'Pending')
                    THEN 1 ELSE 0 END)
      INTO v_emps, v_appr
      FROM v_oc_ts_month_summary
     WHERE project_id = v_project AND period_id = v_period;
    DBMS_OUTPUT.PUT_LINE('[3/6] gate            OK   employees=' || v_emps
                      || ' approved=' || NVL(v_appr,0));
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM; v_failed := 'gate';
    DBMS_OUTPUT.PUT_LINE('[3/6] gate            *** ' || SUBSTR(v_err,1,200));
    RAISE;
  END;

  ----------------------------------------------------------------
  -- [4/6] the header MERGE
  ----------------------------------------------------------------
  v_batch := 'BISECT-' || TO_CHAR(v_project) || '-' || TO_CHAR(v_period);
  BEGIN
    MERGE INTO oc_ts_month_confirm c
    USING (SELECT v_project AS project_id, v_period AS period_id FROM dual) s
       ON (c.project_id = s.project_id AND c.period_id = s.period_id)
     WHEN MATCHED THEN UPDATE
          SET c.confirm_type   = v_type,
              c.confirmed_by   = 'BISECT',
              c.confirmed_on   = SYSTIMESTAMP,
              c.accrual_status = 'Pending',
              c.trace_id       = v_trace
     WHEN NOT MATCHED THEN
          INSERT (project_id, period_id, period_year, period_month,
                  confirm_type, confirmed_by, trace_id)
          VALUES (v_project, v_period, v_year, v_month,
                  v_type, 'BISECT', v_trace);

    SELECT confirm_id INTO v_confirm
      FROM oc_ts_month_confirm
     WHERE project_id = v_project AND period_id = v_period;
    DBMS_OUTPUT.PUT_LINE('[4/6] header MERGE    OK   confirm_id=' || v_confirm);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM; v_failed := 'merge';
    DBMS_OUTPUT.PUT_LINE('[4/6] header MERGE    *** ' || SUBSTR(v_err,1,200));
    RAISE;
  END;

  ----------------------------------------------------------------
  -- [5a] the payload INSERT, exactly as confirm_month has it.
  --
  -- db/103 did NOT clear this, though it was reported as having done so.
  -- Its section 4 wrapped the SELECT in SELECT COUNT(*) FROM ( ... ), and
  -- under a COUNT(*) Oracle is free to eliminate select-list expressions
  -- nothing reads -- including the correlated MAX(client_role) subquery. So
  -- that subquery may never have been evaluated by the test that supposedly
  -- proved the statement good.
  --
  -- Which matters, because a CORRELATED SCALAR SUBQUERY CONTAINING AN
  -- AGGREGATE is a known route to ORA-00979: the optimiser unnests it into a
  -- grouped view, the correlation columns have to survive into that GROUP BY,
  -- and this is the error when the transformation does not work out.
  --
  -- Handler does not re-raise, so every later section still runs.
  ----------------------------------------------------------------
  BEGIN
    INSERT INTO xx_o2c_timesheet_accrual_if (
      period, period_year, period_month, confirm_id,
      employee_id, employee_name, worker_type,
      project_number, project_name, customer_name, revenue_model,
      main_project_id, main_project_number,
      client_role, wbs_task, wbs_task_name, work_date,
      billable_hours, non_billable_hours, leave_hours, unbilled_reason,
      entry_type, flag, approved_date,
      source_entry_id, source_adjustment_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           p.main_project_id,
           (SELECT m.project_number FROM oc_main_project_src m
             WHERE m.project_id = p.main_project_id),
           (SELECT MAX(al.client_role) FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id
               AND al.project_id  = e.project_id),
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           CASE
             WHEN e.entry_type = 'Reversal'    THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'  THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y' THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y' THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y' THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y' THEN 'Late submission'
             ELSE NULL
           END,
           NVL(TRUNC(CAST(w.approved_on AS DATE)), TRUNC(SYSDATE)),
           e.ts_entry_id, e.adjustment_id, v_batch, v_trace
      FROM oc_ts_week      w
      JOIN oc_ts_entry     e  ON e.ts_week_id  = w.ts_week_id
      JOIN oc_time_project p  ON p.project_id  = e.project_id
      JOIN oc_time_task    t  ON t.task_id     = e.task_id
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
     WHERE w.period_id  = v_period
       AND e.project_id = v_project
       AND e.hours     <> 0
       AND (e.day_status = 'Approved'
            OR (v_type = 'Advance closure' AND e.day_status = 'Pending'))
       AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                        WHERE i.confirm_id     = v_confirm
                          AND i.source_entry_id = e.ts_entry_id);
    v_rows := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('[5a] INSERT as-is       OK   rows=' || v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM; v_failed := 'insert';
    DBMS_OUTPUT.PUT_LINE('[5a] INSERT as-is       *** ' || SUBSTR(v_err,1,220));
  END;

  ----------------------------------------------------------------
  -- [5b] THE PROPOSED FIX for [5a]: the same INSERT with the correlated
  --      aggregate subquery replaced by a LEFT JOIN onto a pre-grouped
  --      inline view. There is nothing left to unnest, and one row per
  --      employee+project is guaranteed by the GROUP BY -- which is what the
  --      MAX() was there to ensure in the first place.
  --
  --      Skipped when [5a] worked, so the interface is not double-loaded.
  ----------------------------------------------------------------
  IF v_failed = 'insert' THEN
    BEGIN
      INSERT INTO xx_o2c_timesheet_accrual_if (
        period, period_year, period_month, confirm_id,
        employee_id, employee_name, worker_type,
        project_number, project_name, customer_name, revenue_model,
        main_project_id, main_project_number,
        client_role, wbs_task, wbs_task_name, work_date,
        billable_hours, non_billable_hours, leave_hours, unbilled_reason,
        entry_type, flag, approved_date,
        source_entry_id, source_adjustment_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           p.main_project_id,
           (SELECT m.project_number FROM oc_main_project_src m
             WHERE m.project_id = p.main_project_id),
           alr.client_role,
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           CASE
             WHEN e.entry_type = 'Reversal'    THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'  THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y' THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y' THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y' THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y' THEN 'Late submission'
             ELSE NULL
           END,
           NVL(TRUNC(CAST(w.approved_on AS DATE)), TRUNC(SYSDATE)),
           e.ts_entry_id, e.adjustment_id, v_batch, v_trace
      FROM oc_ts_week      w
      JOIN oc_ts_entry     e  ON e.ts_week_id  = w.ts_week_id
      JOIN oc_time_project p  ON p.project_id  = e.project_id
      JOIN oc_time_task    t  ON t.task_id     = e.task_id
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
      LEFT JOIN (SELECT employee_id, project_id, MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
     WHERE w.period_id  = v_period
       AND e.project_id = v_project
       AND e.hours     <> 0
       AND (e.day_status = 'Approved'
            OR (v_type = 'Advance closure' AND e.day_status = 'Pending'))
       AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                        WHERE i.confirm_id     = v_confirm
                          AND i.source_entry_id = e.ts_entry_id);
      v_rows := SQL%ROWCOUNT;
      DBMS_OUTPUT.PUT_LINE('[5b] INSERT rewritten   OK   rows=' || v_rows
                        || '   <-- this rewrite is the fix');
      v_fixed := 'insert';
    EXCEPTION WHEN OTHERS THEN
      v_err2 := SQLERRM;
      DBMS_OUTPUT.PUT_LINE('[5b] INSERT rewritten   *** ' || SUBSTR(v_err2,1,220));
    END;
  ELSE
    DBMS_OUTPUT.PUT_LINE('[5b] INSERT rewritten   -    skipped, [5a] worked');
  END IF;

  ----------------------------------------------------------------
  -- [6a] the roll-up UPDATE as confirm_month has it: five aggregates inside a
  --      multi-column SET whose subquery correlates back to the row being
  --      updated. Also never tested alone. Does not re-raise either.
  ----------------------------------------------------------------
  BEGIN
    UPDATE oc_ts_month_confirm c
       SET (c.employee_count, c.billable_hours, c.non_billable_hours,
            c.leave_hours, c.adjustment_hours) =
           (SELECT COUNT(DISTINCT i.employee_id),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                                THEN i.billable_hours END),0),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                                THEN i.non_billable_hours END),0),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                                THEN i.leave_hours END),0),
                   NVL(SUM(CASE WHEN i.entry_type IN ('Reversal','Adjustment')
                                THEN i.billable_hours + i.non_billable_hours
                                     + i.leave_hours END),0)
              FROM xx_o2c_timesheet_accrual_if i
             WHERE i.confirm_id = c.confirm_id),
           c.accrual_status    = 'Success',
           c.accrual_rows      = (SELECT COUNT(*) FROM xx_o2c_timesheet_accrual_if i
                                   WHERE i.confirm_id = c.confirm_id),
           c.accrual_pushed_on = SYSTIMESTAMP,
           c.accrual_message   = 'Interface table filled; batch ' || v_batch
     WHERE c.confirm_id = v_confirm;
    DBMS_OUTPUT.PUT_LINE('[6a] UPDATE as-is       OK   rows=' || SQL%ROWCOUNT);
  EXCEPTION WHEN OTHERS THEN
    IF v_failed = 'none' THEN v_err := SQLERRM; v_failed := 'update';
    ELSE v_failed := v_failed || '+update'; END IF;
    DBMS_OUTPUT.PUT_LINE('[6a] UPDATE as-is       *** ' || SUBSTR(SQLERRM,1,220));
  END;

  ----------------------------------------------------------------
  -- [6b] THE PROPOSED FIX for [6a]: aggregate into locals, then a plain
  --      single-column UPDATE carrying no subquery at all. Cannot raise
  --      ORA-00979 whatever the cause was, and reads better besides.
  ----------------------------------------------------------------
  DECLARE
    v_ec NUMBER; v_bh NUMBER; v_nb NUMBER; v_lh NUMBER; v_ah NUMBER; v_ar NUMBER;
  BEGIN
    SELECT COUNT(DISTINCT i.employee_id),
           NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                        THEN i.billable_hours END),0),
           NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                        THEN i.non_billable_hours END),0),
           NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                        THEN i.leave_hours END),0),
           NVL(SUM(CASE WHEN i.entry_type IN ('Reversal','Adjustment')
                        THEN i.billable_hours + i.non_billable_hours
                             + i.leave_hours END),0),
           COUNT(*)
      INTO v_ec, v_bh, v_nb, v_lh, v_ah, v_ar
      FROM xx_o2c_timesheet_accrual_if i
     WHERE i.confirm_id = v_confirm;

    UPDATE oc_ts_month_confirm
       SET employee_count     = v_ec,
           billable_hours     = v_bh,
           non_billable_hours = v_nb,
           leave_hours        = v_lh,
           adjustment_hours   = v_ah,
           accrual_status     = 'Success',
           accrual_rows       = v_ar,
           accrual_pushed_on  = SYSTIMESTAMP,
           accrual_message    = 'Interface table filled; batch ' || v_batch
     WHERE confirm_id = v_confirm;
    DBMS_OUTPUT.PUT_LINE('[6b] UPDATE rewritten   OK   rows=' || SQL%ROWCOUNT
                      || '  employees=' || v_ec || ' billable=' || v_bh
                      || ' nonbill=' || v_nb || ' leave=' || v_lh
                      || ' adj=' || v_ah || ' iface=' || v_ar);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[6b] UPDATE rewritten   *** ' || SUBSTR(SQLERRM,1,220));
  END;

  DBMS_OUTPUT.PUT_LINE(' ');
  IF v_failed = 'none' THEN
    DBMS_OUTPUT.PUT_LINE('>>> ALL FOUR SUCCEEDED individually. Unexpected, and it '
                      || 'would point at how confirm_month sequences them rather '
                      || 'than at any one statement.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('>>> GUILTY: ' || v_failed);
    DBMS_OUTPUT.PUT_LINE('>>> ' || SUBSTR(v_err,1,300));
    IF v_fixed = 'insert' THEN
      DBMS_OUTPUT.PUT_LINE('>>> AND THE FIX IS CONFIRMED: the LEFT JOIN rewrite in '
                        || '[5b] loaded the interface. That goes into db/09.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('>>> Whichever rewrite above reads OK is what goes into db/09.');
    END IF;
  END IF;
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('Rolled back - nothing was confirmed.');

EXCEPTION WHEN OTHERS THEN
  v_err := SQLERRM;
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('>>> FAILED AT: ' || v_failed);
  DBMS_OUTPUT.PUT_LINE('>>> ' || SUBSTR(v_err,1,400));
  DBMS_OUTPUT.PUT_LINE('Rolled back - nothing was confirmed.');
END;
/

PROMPT ============================================================
PROMPT Nothing was committed
PROMPT ============================================================

SELECT COUNT(*) AS confirm_rows_for_jul_555
  FROM oc_ts_month_confirm
 WHERE project_id = (SELECT project_id FROM oc_time_project WHERE project_number = '555')
   AND period_id  = (SELECT period_id  FROM oc_time_period  WHERE period_name = 'JUL-2026');

PROMPT
PROMPT Zero. The ROLLBACK undid the MERGE and the INSERT whichever way the
PROMPT bisect went, so this can be run again unchanged.
