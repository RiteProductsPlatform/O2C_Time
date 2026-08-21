--==============================================================
-- time/106_bisect_the_payload_select.sql
-- O2C Timesheet Module -- which EXPRESSION in the payload INSERT raises
-- ORA-00979
--
-- db/105 settled the statement and killed the fix in the same run:
--
--   [5a] INSERT as-is       *** ORA-00979
--   [5b] INSERT rewritten   *** ORA-00979   <- the proposed fix, also failing
--   [6a] UPDATE as-is       OK
--   [6b] UPDATE rewritten   OK
--
-- So the INSERT is guilty; the roll-up UPDATE never was; and replacing the
-- correlated MAX(client_role) subquery with a pre-grouped LEFT JOIN -- which
-- was my whole theory of the fault -- changes nothing. Two of the three
-- conclusions I drew from reading the code were wrong.
--
-- This stops theorising about which expression it is. Each section below is
-- the REAL INSERT with exactly ONE expression switched to NULL, generated
-- from the current db/09 text rather than typed, so no variant can drift from
-- the statement it is meant to represent -- the mistake that cost the first
-- run of db/105.
--
-- The first variant that SUCCEEDS names the guilty expression.
--
-- ** NOTHING IS COMMITTED. ** One transaction, ROLLBACK at the end, and every
-- handler swallows its error so all six variants run. Re-runnable unchanged.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/2] What the cross-schema project source actually is
PROMPT ============================================================

-- OC_MAIN_PROJECT_SRC is a synonym for o2c_dev.oc_project (db/81). If that
-- turns out to be a VIEW carrying a GROUP BY, DISTINCT or UNION, then merging
-- it into this INSERT is a candidate all by itself -- and nothing so far has
-- checked.
COLUMN owner FORMAT A14
COLUMN object_name FORMAT A24
COLUMN object_type FORMAT A14
SELECT owner, object_name, object_type, status
  FROM all_objects
 WHERE owner = 'O2C_DEV' AND object_name IN ('OC_PROJECT','OC_RATE_CARD')
 ORDER BY object_name;

PROMPT
PROMPT If OC_PROJECT is a VIEW, this shows whether it aggregates:

DECLARE
  v_txt VARCHAR2(32760);
  v_n   NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM all_views
   WHERE owner = 'O2C_DEV' AND view_name = 'OC_PROJECT';
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  o2c_dev.OC_PROJECT is not a view - it is a table.');
  ELSE
    -- TEXT is a LONG. It may be assigned to a VARCHAR2 in PL/SQL and touched
    -- nowhere else -- not NVL, not INSTR, not in a WHERE. Hence the row-at-a-
    -- time read into a local before anything looks at it.
    SELECT text INTO v_txt FROM all_views
     WHERE owner = 'O2C_DEV' AND view_name = 'OC_PROJECT';
    DBMS_OUTPUT.PUT_LINE('  o2c_dev.OC_PROJECT IS A VIEW.');
    DBMS_OUTPUT.PUT_LINE('    GROUP BY : ' || CASE WHEN INSTR(UPPER(v_txt),'GROUP BY') > 0 THEN 'YES' ELSE 'no' END);
    DBMS_OUTPUT.PUT_LINE('    DISTINCT : ' || CASE WHEN INSTR(UPPER(v_txt),'DISTINCT') > 0 THEN 'YES' ELSE 'no' END);
    DBMS_OUTPUT.PUT_LINE('    UNION    : ' || CASE WHEN INSTR(UPPER(v_txt),'UNION')    > 0 THEN 'YES' ELSE 'no' END);
    DBMS_OUTPUT.PUT_LINE('    OVER(    : ' || CASE WHEN INSTR(UPPER(v_txt),'OVER (')   > 0
                                              OR INSTR(UPPER(v_txt),'OVER(')   > 0 THEN 'YES' ELSE 'no' END);
  END IF;
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('  could not read the definition: ' || SUBSTR(SQLERRM,1,150));
END;
/

PROMPT ============================================================
PROMPT [2/2] One expression switched off at a time
PROMPT ============================================================

DECLARE
  v_project NUMBER;
  v_period  NUMBER;
  v_year    NUMBER;
  v_month   NUMBER;
  v_pname   VARCHAR2(30);
  v_confirm NUMBER;
  v_rows    NUMBER;
  v_batch   VARCHAR2(64) := 'BISECT-106';
  v_trace   VARCHAR2(64) := 'BISECT-106';
  v_type    VARCHAR2(30) := 'Normal';
  v_first   VARCHAR2(60) := 'none';
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
        VALUES (v_project, v_period, v_year, v_month,
                v_type, 'BISECT', v_trace);
  SELECT confirm_id INTO v_confirm FROM oc_ts_month_confirm
   WHERE project_id = v_project AND period_id = v_period;
  DBMS_OUTPUT.PUT_LINE('confirm_id ' || v_confirm);
  DBMS_OUTPUT.PUT_LINE(' ');

  ----------------------------------------------------------------
  -- A  as-is (control) expect FAIL
  ----------------------------------------------------------------
  SAVEPOINT sp_A;
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
           alr.client_role,
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
      -- CLIENT_ROLE comes from a PRE-GROUPED inline view, not a correlated scalar
      -- subquery. It used to read
      --
      --   (SELECT MAX(al.client_role) FROM oc_time_allocation al
      --     WHERE al.employee_id = w.employee_id AND al.project_id = e.project_id)
      --
      -- and a correlated scalar subquery containing an aggregate is a known way to
      -- reach ORA-00979: the optimiser unnests it into a grouped view, and the
      -- correlation columns have to survive into that GROUP BY. Confirming a month
      -- failed on exactly that error.
      --
      -- Equivalent, including the null case: no matching allocation gave NULL from
      -- the scalar subquery and gives NULL from the outer join. The GROUP BY
      -- guarantees one row per employee+project, which is the only thing the MAX()
      -- was ever there to ensure -- one person can hold several allocation rows on
      -- a project and the annexure wants a single role.
      LEFT JOIN (SELECT employee_id, project_id,
                        MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
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
    DBMS_OUTPUT.PUT_LINE('[A] as-is (control)                      OK   rows=' || v_rows);
    IF v_first = 'none' AND 'A' <> 'A' THEN v_first := 'as-is (control)'; END IF;
    ROLLBACK TO sp_A;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[A] as-is (control)                      *** ' || SUBSTR(SQLERRM,1,90));
    ROLLBACK TO sp_A;
  END;

  ----------------------------------------------------------------
  -- B  main_project_number subquery -> NULL 
  ----------------------------------------------------------------
  SAVEPOINT sp_B;
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
           CAST(NULL AS VARCHAR2(40)),
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
           alr.client_role,
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
      -- CLIENT_ROLE comes from a PRE-GROUPED inline view, not a correlated scalar
      -- subquery. It used to read
      --
      --   (SELECT MAX(al.client_role) FROM oc_time_allocation al
      --     WHERE al.employee_id = w.employee_id AND al.project_id = e.project_id)
      --
      -- and a correlated scalar subquery containing an aggregate is a known way to
      -- reach ORA-00979: the optimiser unnests it into a grouped view, and the
      -- correlation columns have to survive into that GROUP BY. Confirming a month
      -- failed on exactly that error.
      --
      -- Equivalent, including the null case: no matching allocation gave NULL from
      -- the scalar subquery and gives NULL from the outer join. The GROUP BY
      -- guarantees one row per employee+project, which is the only thing the MAX()
      -- was ever there to ensure -- one person can hold several allocation rows on
      -- a project and the annexure wants a single role.
      LEFT JOIN (SELECT employee_id, project_id,
                        MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
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
    DBMS_OUTPUT.PUT_LINE('[B] main_project_number subquery -> NULL  OK   rows=' || v_rows);
    IF v_first = 'none' AND 'B' <> 'A' THEN v_first := 'main_project_number subquery -> NULL'; END IF;
    ROLLBACK TO sp_B;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[B] main_project_number subquery -> NULL  *** ' || SUBSTR(SQLERRM,1,90));
    ROLLBACK TO sp_B;
  END;

  ----------------------------------------------------------------
  -- C  client_role -> NULL 
  ----------------------------------------------------------------
  SAVEPOINT sp_C;
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
      -- CLIENT_ROLE comes from a PRE-GROUPED inline view, not a correlated scalar
      -- subquery. It used to read
      --
      --   (SELECT MAX(al.client_role) FROM oc_time_allocation al
      --     WHERE al.employee_id = w.employee_id AND al.project_id = e.project_id)
      --
      -- and a correlated scalar subquery containing an aggregate is a known way to
      -- reach ORA-00979: the optimiser unnests it into a grouped view, and the
      -- correlation columns have to survive into that GROUP BY. Confirming a month
      -- failed on exactly that error.
      --
      -- Equivalent, including the null case: no matching allocation gave NULL from
      -- the scalar subquery and gives NULL from the outer join. The GROUP BY
      -- guarantees one row per employee+project, which is the only thing the MAX()
      -- was ever there to ensure -- one person can hold several allocation rows on
      -- a project and the annexure wants a single role.
      LEFT JOIN (SELECT employee_id, project_id,
                        MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
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
    DBMS_OUTPUT.PUT_LINE('[C] client_role -> NULL                  OK   rows=' || v_rows);
    IF v_first = 'none' AND 'C' <> 'A' THEN v_first := 'client_role -> NULL'; END IF;
    ROLLBACK TO sp_C;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[C] client_role -> NULL                  *** ' || SUBSTR(SQLERRM,1,90));
    ROLLBACK TO sp_C;
  END;

  ----------------------------------------------------------------
  -- D  flag CASE -> NULL 
  ----------------------------------------------------------------
  SAVEPOINT sp_D;
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
           alr.client_role,
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
           CAST(NULL AS VARCHAR2(40)),
           NVL(TRUNC(CAST(w.approved_on AS DATE)), TRUNC(SYSDATE)),
           e.ts_entry_id, e.adjustment_id, v_batch, v_trace
      FROM oc_ts_week      w
      JOIN oc_ts_entry     e  ON e.ts_week_id  = w.ts_week_id
      JOIN oc_time_project p  ON p.project_id  = e.project_id
      JOIN oc_time_task    t  ON t.task_id     = e.task_id
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
      -- CLIENT_ROLE comes from a PRE-GROUPED inline view, not a correlated scalar
      -- subquery. It used to read
      --
      --   (SELECT MAX(al.client_role) FROM oc_time_allocation al
      --     WHERE al.employee_id = w.employee_id AND al.project_id = e.project_id)
      --
      -- and a correlated scalar subquery containing an aggregate is a known way to
      -- reach ORA-00979: the optimiser unnests it into a grouped view, and the
      -- correlation columns have to survive into that GROUP BY. Confirming a month
      -- failed on exactly that error.
      --
      -- Equivalent, including the null case: no matching allocation gave NULL from
      -- the scalar subquery and gives NULL from the outer join. The GROUP BY
      -- guarantees one row per employee+project, which is the only thing the MAX()
      -- was ever there to ensure -- one person can hold several allocation rows on
      -- a project and the annexure wants a single role.
      LEFT JOIN (SELECT employee_id, project_id,
                        MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
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
    DBMS_OUTPUT.PUT_LINE('[D] flag CASE -> NULL                    OK   rows=' || v_rows);
    IF v_first = 'none' AND 'D' <> 'A' THEN v_first := 'flag CASE -> NULL'; END IF;
    ROLLBACK TO sp_D;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[D] flag CASE -> NULL                    *** ' || SUBSTR(SQLERRM,1,90));
    ROLLBACK TO sp_D;
  END;

  ----------------------------------------------------------------
  -- E  NOT EXISTS removed 
  ----------------------------------------------------------------
  SAVEPOINT sp_E;
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
           alr.client_role,
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
      -- CLIENT_ROLE comes from a PRE-GROUPED inline view, not a correlated scalar
      -- subquery. It used to read
      --
      --   (SELECT MAX(al.client_role) FROM oc_time_allocation al
      --     WHERE al.employee_id = w.employee_id AND al.project_id = e.project_id)
      --
      -- and a correlated scalar subquery containing an aggregate is a known way to
      -- reach ORA-00979: the optimiser unnests it into a grouped view, and the
      -- correlation columns have to survive into that GROUP BY. Confirming a month
      -- failed on exactly that error.
      --
      -- Equivalent, including the null case: no matching allocation gave NULL from
      -- the scalar subquery and gives NULL from the outer join. The GROUP BY
      -- guarantees one row per employee+project, which is the only thing the MAX()
      -- was ever there to ensure -- one person can hold several allocation rows on
      -- a project and the annexure wants a single role.
      LEFT JOIN (SELECT employee_id, project_id,
                        MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
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
                AND e.day_status = 'Pending'));
    v_rows := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('[E] NOT EXISTS removed                   OK   rows=' || v_rows);
    IF v_first = 'none' AND 'E' <> 'A' THEN v_first := 'NOT EXISTS removed'; END IF;
    ROLLBACK TO sp_E;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[E] NOT EXISTS removed                   *** ' || SUBSTR(SQLERRM,1,90));
    ROLLBACK TO sp_E;
  END;

  ----------------------------------------------------------------
  -- F  all four switched off expect OK
  ----------------------------------------------------------------
  SAVEPOINT sp_F;
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
           CAST(NULL AS VARCHAR2(40)),
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
           CAST(NULL AS VARCHAR2(40)),
           NVL(TRUNC(CAST(w.approved_on AS DATE)), TRUNC(SYSDATE)),
           e.ts_entry_id, e.adjustment_id, v_batch, v_trace
      FROM oc_ts_week      w
      JOIN oc_ts_entry     e  ON e.ts_week_id  = w.ts_week_id
      JOIN oc_time_project p  ON p.project_id  = e.project_id
      JOIN oc_time_task    t  ON t.task_id     = e.task_id
      JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
      -- CLIENT_ROLE comes from a PRE-GROUPED inline view, not a correlated scalar
      -- subquery. It used to read
      --
      --   (SELECT MAX(al.client_role) FROM oc_time_allocation al
      --     WHERE al.employee_id = w.employee_id AND al.project_id = e.project_id)
      --
      -- and a correlated scalar subquery containing an aggregate is a known way to
      -- reach ORA-00979: the optimiser unnests it into a grouped view, and the
      -- correlation columns have to survive into that GROUP BY. Confirming a month
      -- failed on exactly that error.
      --
      -- Equivalent, including the null case: no matching allocation gave NULL from
      -- the scalar subquery and gives NULL from the outer join. The GROUP BY
      -- guarantees one row per employee+project, which is the only thing the MAX()
      -- was ever there to ensure -- one person can hold several allocation rows on
      -- a project and the annexure wants a single role.
      LEFT JOIN (SELECT employee_id, project_id,
                        MAX(client_role) AS client_role
                   FROM oc_time_allocation
                  GROUP BY employee_id, project_id) alr
             ON alr.employee_id = w.employee_id
            AND alr.project_id  = e.project_id
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
                AND e.day_status = 'Pending'));
    v_rows := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('[F] all four switched off                OK   rows=' || v_rows);
    IF v_first = 'none' AND 'F' <> 'A' THEN v_first := 'all four switched off'; END IF;
    ROLLBACK TO sp_F;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('[F] all four switched off                *** ' || SUBSTR(SQLERRM,1,90));
    ROLLBACK TO sp_F;
  END;

  DBMS_OUTPUT.PUT_LINE(' ');
  IF v_first = 'none' THEN
    DBMS_OUTPUT.PUT_LINE('>>> Every variant failed, including F with all four')
    ;DBMS_OUTPUT.PUT_LINE('>>> expressions switched off. Then it is not the select')
    ;DBMS_OUTPUT.PUT_LINE('>>> list at all - look at the joins or the target table.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('>>> FIRST VARIANT THAT SUCCEEDED: ' || v_first);
    DBMS_OUTPUT.PUT_LINE('>>> That is the expression to rewrite in db/09.');
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
