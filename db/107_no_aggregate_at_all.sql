--==============================================================
-- time/107_no_aggregate_at_all.sql
-- O2C Timesheet Module -- run the payload INSERT with NO AGGREGATE in it
--
-- db/106 reported every variant failing, including F with 'all four switched
-- off', and concluded it was not the select list. That conclusion was wrong,
-- and the fault was in the generator that wrote db/106, not in the database.
--
-- Its 'client_role -> NULL' variant replaced the select ITEM and left
--
--   LEFT JOIN (SELECT employee_id, project_id, MAX(client_role) AS client_role
--                FROM oc_time_allocation
--               GROUP BY employee_id, project_id) alr
--
-- sitting in the FROM clause. So C and F still aggregated. So did db/105 [5a],
-- which carried the original correlated MAX subquery, and [5b], which carried
-- this same inline view.
--
-- EVERY FAILING TEST HAS CONTAINED AN AGGREGATE. The one test that passed --
-- db/103 section 4 -- wrapped the query in SELECT COUNT(*) FROM ( ... ), which
-- is precisely the shape where Oracle is free to eliminate it. The aggregate
-- has never been removed, so it has never been ruled out.
--
-- Three variants, and between them a diagnosis and a fix:
--
--   G  client_role gone entirely -- select item NULL AND the LEFT JOIN
--      deleted. If G succeeds, the aggregate is the cause, full stop.
--   H  client_role from a NON-AGGREGATE scalar subquery (ROWNUM = 1). A
--      one-statement fix if it works.
--   I  the two-step fix: INSERT without client_role, then a separate UPDATE
--      that fills it. db/105 [6a] already showed an aggregate-bearing UPDATE
--      runs fine here, so this is the fallback that cannot fail for this
--      reason.
--
-- ** NOTHING IS COMMITTED. ** Savepoints between variants, ROLLBACK at the end.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

DECLARE
  v_project NUMBER;  v_period NUMBER;  v_year NUMBER;  v_month NUMBER;
  v_pname VARCHAR2(30);  v_confirm NUMBER;  v_rows NUMBER;
  v_batch VARCHAR2(64) := 'BISECT-107';
  v_trace VARCHAR2(64) := 'BISECT-107';
  v_type  VARCHAR2(30) := 'Normal';
  v_win   VARCHAR2(40) := 'none';
BEGIN
  SELECT project_id INTO v_project FROM oc_time_project WHERE project_number = '555';
  SELECT period_id, period_year, period_month, period_name
    INTO v_period, v_year, v_month, v_pname
    FROM oc_time_period WHERE period_name = 'JUL-2026';

  MERGE INTO oc_ts_month_confirm c
  USING (SELECT v_project AS project_id, v_period AS period_id FROM dual) s
     ON (c.project_id = s.project_id AND c.period_id = s.period_id)
   WHEN MATCHED THEN UPDATE SET c.trace_id = v_trace
   WHEN NOT MATCHED THEN
        INSERT (project_id, period_id, period_year, period_month,
                confirm_type, confirmed_by, trace_id)
        VALUES (v_project, v_period, v_year, v_month, v_type, 'BISECT', v_trace);
  SELECT confirm_id INTO v_confirm FROM oc_ts_month_confirm
   WHERE project_id = v_project AND period_id = v_period;
  DBMS_OUTPUT.PUT_LINE('confirm_id ' || v_confirm);
  DBMS_OUTPUT.PUT_LINE(' ');

  SAVEPOINT sp_G;
  BEGIN
    INSERT INTO xx_o2c_timesheet_accrual_if (
      period, period_year, period_month, confirm_id,
      employee_id, employee_name, worker_type,
      project_number, project_name, customer_name, revenue_model,
      -- THEIR project code as well as Fusion's. Accrual keys on
      -- OC_PROJECT.PROJECT_NUMBER in the main application; PROJECT_NUMBER here is
      -- Fusion's ('555'), and handing them only that makes them name-match back to
      -- their own project list. Copied at confirmation like every other name on
      -- this table, so a later re-link cannot restate a closed month.
      main_project_id, main_project_number,
      client_role,
      wbs_task, wbs_task_name, work_date,
      billable_hours, non_billable_hours, leave_hours, unbilled_reason,
      entry_type, flag, action_date,
      source_ts_id, source_adj_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           p.main_project_id,
           (SELECT m.project_number FROM oc_main_project_src m
             WHERE m.project_id = p.main_project_id),
           -- The person's role on this project, copied at confirmation.
           --
           -- THE MULTIPLICATION HAZARD THIS USED TO WARN ABOUT IS REAL AND IS
           -- STILL HANDLED. OC_TIME_ALLOCATION can hold more than one row per
           -- person per project across date ranges, so joining it RAW would
           -- multiply every timesheet entry into the interface. That is why
           -- this was a scalar subquery.
           --
           -- It is now a join onto a view that is GROUPED BY employee_id,
           -- project_id -- exactly one row per pair, so at most one match and
           -- nothing multiplies. Do not "simplify" alr back to a bare join on
           -- OC_TIME_ALLOCATION; the GROUP BY is what makes it safe.
           CAST(NULL AS VARCHAR2(120)),
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           -- The workflow flag that explains this row to the accrual reader.
           -- Ordered most-specific first: the row's own entry type wins, then the
           -- week-level flags. Correction and Contractor Unbilled hours were
           -- dropped on 30-Jul-2026 and no longer appear here.
           CASE
             WHEN e.entry_type = 'Reversal'              THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'            THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y'           THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y'           THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y'           THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y'           THEN 'Late submission'
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
       -- Only manager-approved data posts (INT-014) -- AND, ON ADVANCE CLOSURE,
       -- the days the gate above has just accepted without approval.
       --
       -- This read day_status = 'Approved' alone, so the two halves of one
       -- decision disagreed: the RULE-020 gate accepts a Pending month when the
       -- confirm type is 'Advance closure', and then the payload refused every
       -- day in it. The month confirmed, ACCRUAL_ROWS came out 0, and accrual
       -- received an empty batch -- which reads as "this project had no time in
       -- July" rather than "nobody approved it".
       --
       -- Advance closure exists precisely because the hours ARE real:
       -- prepopulated, defaulted by a job when a cut-off passed, missing only
       -- somebody's agreement. Confirming the month while withholding them says
       -- the opposite.
       --
       -- Mirrors the gate exactly so the two cannot drift again: Approved
       -- always, Pending only on advance closure, Rejected never -- a rejection
       -- is a manager actively saying no, which is the opposite of the silence
       -- advance closure overrides.
       AND (e.day_status = 'Approved'
            OR (v_type = 'Advance closure'
                AND e.day_status = 'Pending'))
       AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                        WHERE i.confirm_id   = v_confirm
                          AND i.source_ts_id = e.ts_entry_id
                          AND i.entry_type   = e.entry_type);
    v_rows := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('[G] no client_role at all        OK   rows=' || v_rows);
    IF v_win = 'none' THEN v_win := 'no client_role at all'; END IF;
    ROLLBACK TO sp_G;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[G] no client_role at all        *** ' || SUBSTR(SQLERRM,1,110));
    ROLLBACK TO sp_G;
  END;

  SAVEPOINT sp_H;
  BEGIN
    INSERT INTO xx_o2c_timesheet_accrual_if (
      period, period_year, period_month, confirm_id,
      employee_id, employee_name, worker_type,
      project_number, project_name, customer_name, revenue_model,
      -- THEIR project code as well as Fusion's. Accrual keys on
      -- OC_PROJECT.PROJECT_NUMBER in the main application; PROJECT_NUMBER here is
      -- Fusion's ('555'), and handing them only that makes them name-match back to
      -- their own project list. Copied at confirmation like every other name on
      -- this table, so a later re-link cannot restate a closed month.
      main_project_id, main_project_number,
      client_role,
      wbs_task, wbs_task_name, work_date,
      billable_hours, non_billable_hours, leave_hours, unbilled_reason,
      entry_type, flag, action_date,
      source_ts_id, source_adj_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           p.main_project_id,
           (SELECT m.project_number FROM oc_main_project_src m
             WHERE m.project_id = p.main_project_id),
           -- The person's role on this project, copied at confirmation.
           --
           -- THE MULTIPLICATION HAZARD THIS USED TO WARN ABOUT IS REAL AND IS
           -- STILL HANDLED. OC_TIME_ALLOCATION can hold more than one row per
           -- person per project across date ranges, so joining it RAW would
           -- multiply every timesheet entry into the interface. That is why
           -- this was a scalar subquery.
           --
           -- It is now a join onto a view that is GROUPED BY employee_id,
           -- project_id -- exactly one row per pair, so at most one match and
           -- nothing multiplies. Do not "simplify" alr back to a bare join on
           -- OC_TIME_ALLOCATION; the GROUP BY is what makes it safe.
           -- NON-AGGREGATE. ROWNUM = 1 instead of MAX(): picks one row
           -- rather than reducing many, so there is no aggregation to unnest.
           (SELECT al.client_role FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id
               AND al.project_id  = e.project_id
               AND ROWNUM = 1),
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           -- The workflow flag that explains this row to the accrual reader.
           -- Ordered most-specific first: the row's own entry type wins, then the
           -- week-level flags. Correction and Contractor Unbilled hours were
           -- dropped on 30-Jul-2026 and no longer appear here.
           CASE
             WHEN e.entry_type = 'Reversal'              THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'            THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y'           THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y'           THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y'           THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y'           THEN 'Late submission'
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
       -- Only manager-approved data posts (INT-014) -- AND, ON ADVANCE CLOSURE,
       -- the days the gate above has just accepted without approval.
       --
       -- This read day_status = 'Approved' alone, so the two halves of one
       -- decision disagreed: the RULE-020 gate accepts a Pending month when the
       -- confirm type is 'Advance closure', and then the payload refused every
       -- day in it. The month confirmed, ACCRUAL_ROWS came out 0, and accrual
       -- received an empty batch -- which reads as "this project had no time in
       -- July" rather than "nobody approved it".
       --
       -- Advance closure exists precisely because the hours ARE real:
       -- prepopulated, defaulted by a job when a cut-off passed, missing only
       -- somebody's agreement. Confirming the month while withholding them says
       -- the opposite.
       --
       -- Mirrors the gate exactly so the two cannot drift again: Approved
       -- always, Pending only on advance closure, Rejected never -- a rejection
       -- is a manager actively saying no, which is the opposite of the silence
       -- advance closure overrides.
       AND (e.day_status = 'Approved'
            OR (v_type = 'Advance closure'
                AND e.day_status = 'Pending'))
       AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                        WHERE i.confirm_id   = v_confirm
                          AND i.source_ts_id = e.ts_entry_id
                          AND i.entry_type   = e.entry_type);
    v_rows := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('[H] client_role via ROWNUM = 1   OK   rows=' || v_rows);
    IF v_win = 'none' THEN v_win := 'client_role via ROWNUM = 1'; END IF;
    ROLLBACK TO sp_H;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[H] client_role via ROWNUM = 1   *** ' || SUBSTR(SQLERRM,1,110));
    ROLLBACK TO sp_H;
  END;

  SAVEPOINT sp_I;
  BEGIN
    INSERT INTO xx_o2c_timesheet_accrual_if (
      period, period_year, period_month, confirm_id,
      employee_id, employee_name, worker_type,
      project_number, project_name, customer_name, revenue_model,
      -- THEIR project code as well as Fusion's. Accrual keys on
      -- OC_PROJECT.PROJECT_NUMBER in the main application; PROJECT_NUMBER here is
      -- Fusion's ('555'), and handing them only that makes them name-match back to
      -- their own project list. Copied at confirmation like every other name on
      -- this table, so a later re-link cannot restate a closed month.
      main_project_id, main_project_number,
      client_role,
      wbs_task, wbs_task_name, work_date,
      billable_hours, non_billable_hours, leave_hours, unbilled_reason,
      entry_type, flag, action_date,
      source_ts_id, source_adj_id, batch_id, trace_id)
    SELECT v_pname, v_year, v_month, v_confirm,
           w.employee_id, wk.employee_name, wk.worker_type,
           p.project_number, p.project_name, p.customer_name, p.revenue_model,
           p.main_project_id,
           (SELECT m.project_number FROM oc_main_project_src m
             WHERE m.project_id = p.main_project_id),
           -- The person's role on this project, copied at confirmation.
           --
           -- THE MULTIPLICATION HAZARD THIS USED TO WARN ABOUT IS REAL AND IS
           -- STILL HANDLED. OC_TIME_ALLOCATION can hold more than one row per
           -- person per project across date ranges, so joining it RAW would
           -- multiply every timesheet entry into the interface. That is why
           -- this was a scalar subquery.
           --
           -- It is now a join onto a view that is GROUPED BY employee_id,
           -- project_id -- exactly one row per pair, so at most one match and
           -- nothing multiplies. Do not "simplify" alr back to a bare join on
           -- OC_TIME_ALLOCATION; the GROUP BY is what makes it safe.
           CAST(NULL AS VARCHAR2(120)),
           t.task_code, t.task_name, e.entry_date,
           CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END,
           CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END,
           e.unbilled_reason,
           e.entry_type,
           -- The workflow flag that explains this row to the accrual reader.
           -- Ordered most-specific first: the row's own entry type wins, then the
           -- week-level flags. Correction and Contractor Unbilled hours were
           -- dropped on 30-Jul-2026 and no longer appear here.
           CASE
             WHEN e.entry_type = 'Reversal'              THEN 'Reversal'
             WHEN e.entry_type = 'Adjustment'            THEN 'Adjustment'
             WHEN w.advance_closure_flag = 'Y'           THEN 'Advance closure'
             WHEN w.overridden_flag      = 'Y'           THEN 'Overridden & approved'
             WHEN w.defaulted_flag       = 'Y'           THEN 'Defaulted'
             WHEN w.late_submission_flag = 'Y'           THEN 'Late submission'
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
       -- Only manager-approved data posts (INT-014) -- AND, ON ADVANCE CLOSURE,
       -- the days the gate above has just accepted without approval.
       --
       -- This read day_status = 'Approved' alone, so the two halves of one
       -- decision disagreed: the RULE-020 gate accepts a Pending month when the
       -- confirm type is 'Advance closure', and then the payload refused every
       -- day in it. The month confirmed, ACCRUAL_ROWS came out 0, and accrual
       -- received an empty batch -- which reads as "this project had no time in
       -- July" rather than "nobody approved it".
       --
       -- Advance closure exists precisely because the hours ARE real:
       -- prepopulated, defaulted by a job when a cut-off passed, missing only
       -- somebody's agreement. Confirming the month while withholding them says
       -- the opposite.
       --
       -- Mirrors the gate exactly so the two cannot drift again: Approved
       -- always, Pending only on advance closure, Rejected never -- a rejection
       -- is a manager actively saying no, which is the opposite of the silence
       -- advance closure overrides.
       AND (e.day_status = 'Approved'
            OR (v_type = 'Advance closure'
                AND e.day_status = 'Pending'))
       AND NOT EXISTS (SELECT 1 FROM xx_o2c_timesheet_accrual_if i
                        WHERE i.confirm_id   = v_confirm
                          AND i.source_ts_id = e.ts_entry_id
                          AND i.entry_type   = e.entry_type);
    v_rows := SQL%ROWCOUNT;
      -- Fill CLIENT_ROLE in a SECOND statement. The aggregate lives here, in an
      -- UPDATE -- and db/105 [6a] already proved an aggregate-bearing UPDATE runs
      -- fine against this schema, so the thing that breaks the INSERT does not
      -- break this.
      UPDATE xx_o2c_timesheet_accrual_if i
         SET i.client_role =
             (SELECT MAX(al.client_role)
                FROM oc_time_allocation al
               WHERE al.employee_id = i.employee_id
                 AND al.project_id  = (SELECT p.project_id
                                         FROM oc_time_project p
                                        WHERE p.project_number = i.project_number))
       WHERE i.confirm_id = v_confirm;

    DBMS_OUTPUT.PUT_LINE('[I] two-step: INSERT then UPDATE  OK   rows=' || v_rows);
    IF v_win = 'none' THEN v_win := 'two-step: INSERT then UPDATE'; END IF;
    ROLLBACK TO sp_I;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[I] two-step: INSERT then UPDATE  *** ' || SUBSTR(SQLERRM,1,110));
    ROLLBACK TO sp_I;
  END;

  DBMS_OUTPUT.PUT_LINE(' ');
  IF v_win = 'none' THEN
    DBMS_OUTPUT.PUT_LINE('>>> Even with no aggregate the INSERT fails. Then the');
    DBMS_OUTPUT.PUT_LINE('>>> aggregate is innocent and the cause is structural -');
    DBMS_OUTPUT.PUT_LINE('>>> the joins, or something about the target table.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('>>> AGGREGATE CONFIRMED AS THE CAUSE.');
    DBMS_OUTPUT.PUT_LINE('>>> First variant that worked: ' || v_win);
    DBMS_OUTPUT.PUT_LINE('>>> That is the shape to put into db/09.');
  END IF;
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('Rolled back - nothing was confirmed.');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('>>> block failed: ' || SUBSTR(SQLERRM,1,300));
END;
/

PROMPT
PROMPT Nothing was committed:
SELECT COUNT(*) AS confirm_rows_for_jul_555
  FROM oc_ts_month_confirm
 WHERE project_id = (SELECT project_id FROM oc_time_project WHERE project_number = '555')
   AND period_id  = (SELECT period_id  FROM oc_time_period  WHERE period_name = 'JUL-2026');
