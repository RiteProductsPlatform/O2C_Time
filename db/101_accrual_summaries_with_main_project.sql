--==============================================================
-- time/101_accrual_summaries_with_main_project.sql
-- O2C Timesheet Module — the three summaries accrual asked for, keyed on their
-- own project code
--
-- Asked 21-Aug: monthly, daily and daily task-wise summaries for the accrual
-- team, carrying the role and the project code from the O2C MAIN application.
--
-- Three of the four levels already exist (db/82) and already carry CLIENT_ROLE.
-- What none of them carried is the main application's project code, and that is
-- the one column that makes them usable by somebody outside this schema: our
-- PROJECT_NUMBER is Fusion's ('555', 'PCS10034'), while accrual keys everything
-- on OC_PROJECT.PROJECT_NUMBER in O2C_DEV. Handing them a summary they have to
-- name-match back to their own project list is handing them the problem db/81
-- already solved.
--
-- THE LINK EXISTS. db/81 stamps OC_TIME_PROJECT.MAIN_PROJECT_ID from
-- o2c_dev.oc_project, resolving the same way the main application does. This
-- carries that id, and their PROJECT_NUMBER beside it, onto the interface.
--
-- ON THE INTERFACE, NOT JOINED IN THE VIEW. The rule for
-- XX_O2C_TIMESHEET_ACCRUAL_IF is that it is denormalised on purpose -- "the
-- consumer is a different application that cannot join to our master cache, so
-- names travel with ids". A view that joined OC_TIME_PROJECT to fetch the code
-- would break the moment a project is re-linked, and would silently restate a
-- confirmed month. Copied at confirmation, like CLIENT_ROLE and every other
-- name there.
--
-- A row whose project has no main-app link gets NULL, not a guess. That is
-- visible in [4/5] and is a link to fix in db/81, not something to paper over
-- here.
--
-- RUN db/09 AFTER THIS. confirm_month is edited there to populate the two new
-- columns; until it is recompiled they stay null on newly confirmed months.
--
-- Idempotent. Depends on: time/07, 09, 81, 82.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TIME_PROJECT' AND column_name = 'MAIN_PROJECT_ID';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/81 has not been run: OC_TIME_PROJECT.MAIN_PROJECT_ID is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] The main-app project on the accrual interface
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE xx_o2c_timesheet_accrual_if ADD ('
    || 'MAIN_PROJECT_ID NUMBER, MAIN_PROJECT_NUMBER VARCHAR2(40 CHAR))';
  DBMS_OUTPUT.PUT_LINE('MAIN_PROJECT_ID and MAIN_PROJECT_NUMBER added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN
    DBMS_OUTPUT.PUT_LINE('Already present - skipped.');
  ELSE RAISE; END IF;
END;
/

COMMENT ON COLUMN xx_o2c_timesheet_accrual_if.main_project_id IS
  'OC_PROJECT.PROJECT_ID in the O2C main application, copied at confirmation from OC_TIME_PROJECT.MAIN_PROJECT_ID. Denormalised like every other value here: the consumer cannot join to our cache, and a confirmed month must not change because a project was re-linked afterwards. NULL means the project has no main-app link yet.';

COMMENT ON COLUMN xx_o2c_timesheet_accrual_if.main_project_number IS
  'OC_PROJECT.PROJECT_NUMBER in the O2C main application - the code accrual keys on. Distinct from PROJECT_NUMBER on this table, which is FUSION''s project number. Both are carried because the two systems name the same project differently and the annexure has to reconcile against either.';

PROMPT ============================================================
PROMPT [2/5] Backfill anything already confirmed
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE xx_o2c_timesheet_accrual_if i
     SET (main_project_id, main_project_number) =
         (SELECT p.main_project_id, m.project_number
            FROM oc_time_project p
            LEFT JOIN oc_main_project_src m ON m.project_id = p.main_project_id
           WHERE p.project_number = i.project_number)
   WHERE i.main_project_id IS NULL
     AND EXISTS (SELECT 1 FROM oc_time_project p
                  WHERE p.project_number   = i.project_number
                    AND p.main_project_id IS NOT NULL);
  v_n := SQL%ROWCOUNT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' already-confirmed row(s) backfilled.');
  COMMIT;
EXCEPTION WHEN OTHERS THEN
  -- The synonym is db/81's. Without it there is nothing to backfill FROM, which
  -- is a reason to say so rather than to fail the install.
  DBMS_OUTPUT.PUT_LINE('  Backfill skipped: ' || SUBSTR(SQLERRM,1,150));
END;
/

PROMPT ============================================================
PROMPT [3/5] The three summaries
PROMPT ============================================================

-- ── DAY x TASK: the finest grain, and the one everything else rolls up from.
-- ENTRY_TYPE and FLAG are kept because a Reversal or Adjustment line is the
-- thing a customer queries, and a net figure with no sign of the correction
-- invites exactly the question the annexure exists to pre-empt.
CREATE OR REPLACE VIEW v_oc_ts_anx_day_task AS
SELECT i.confirm_id, i.period, i.period_year, i.period_month,
       i.main_project_id, i.main_project_number,
       i.project_number, i.project_name, i.customer_name, i.revenue_model,
       i.employee_id, i.employee_name, i.worker_type,
       i.client_role,
       i.work_date,
       TO_CHAR(i.work_date,'DY') AS day_name,
       i.wbs_task, i.wbs_task_name,
       i.entry_type, i.flag, i.unbilled_reason,
       i.billable_hours, i.non_billable_hours, i.leave_hours,
       i.billable_hours + i.non_billable_hours + i.leave_hours AS total_hours
  FROM xx_o2c_timesheet_accrual_if i;

-- ── DAY: tasks collapsed, one row per person per day.
CREATE OR REPLACE VIEW v_oc_ts_anx_day AS
SELECT confirm_id, period, period_year, period_month,
       main_project_id, main_project_number,
       project_number, project_name, customer_name, revenue_model,
       employee_id, employee_name, worker_type, client_role,
       work_date,
       TO_CHAR(work_date,'DY')            AS day_name,
       COUNT(DISTINCT wbs_task)           AS tasks,
       SUM(billable_hours)                AS billable_hours,
       SUM(non_billable_hours)            AS non_billable_hours,
       SUM(leave_hours)                   AS leave_hours,
       SUM(billable_hours + non_billable_hours + leave_hours) AS total_hours
  FROM xx_o2c_timesheet_accrual_if
 GROUP BY confirm_id, period, period_year, period_month,
          main_project_id, main_project_number,
          project_number, project_name, customer_name, revenue_model,
          employee_id, employee_name, worker_type, client_role, work_date;

-- ── MONTH: one row per person per project month. What accrual posts from.
CREATE OR REPLACE VIEW v_oc_ts_anx_month AS
SELECT confirm_id, period, period_year, period_month,
       main_project_id, main_project_number,
       project_number, project_name, customer_name, revenue_model,
       employee_id, employee_name, worker_type, client_role,
       COUNT(DISTINCT work_date)          AS days_worked,
       SUM(billable_hours)                AS billable_hours,
       SUM(non_billable_hours)            AS non_billable_hours,
       SUM(leave_hours)                   AS leave_hours,
       SUM(billable_hours + non_billable_hours + leave_hours) AS total_hours
  FROM xx_o2c_timesheet_accrual_if
 GROUP BY confirm_id, period, period_year, period_month,
          main_project_id, main_project_number,
          project_number, project_name, customer_name, revenue_model,
          employee_id, employee_name, worker_type, client_role;

PROMPT ============================================================
PROMPT [4/5] Let the main application read them
PROMPT ============================================================

-- The three views, not the interface table. A view is a contract: the columns
-- are named and ordered deliberately and PROCESSED_FLAG / PULLED_ON / BATCH_ID
-- stay out of it, because those are the pull protocol's and not the summary's.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(40);
  v t_tab := t_tab('V_OC_TS_ANX_MONTH','V_OC_TS_ANX_DAY','V_OC_TS_ANX_DAY_TASK');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'GRANT SELECT ON ' || v(i) || ' TO o2c_dev';
      DBMS_OUTPUT.PUT_LINE('  granted on ' || v(i));
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  GRANT FAILED on ' || v(i) || ': '
        || SUBSTR(SQLERRM,1,120));
      DBMS_OUTPUT.PUT_LINE('    Run as ADMIN if O2C_TIME cannot grant to o2c_dev.');
    END;
  END LOOP;
END;
/

PROMPT
PROMPT And in the main application, so they need not qualify the schema:
PROMPT   CREATE OR REPLACE SYNONYM oc_ts_anx_month    FOR o2c_time.v_oc_ts_anx_month;
PROMPT   CREATE OR REPLACE SYNONYM oc_ts_anx_day      FOR o2c_time.v_oc_ts_anx_day;
PROMPT   CREATE OR REPLACE SYNONYM oc_ts_anx_day_task FOR o2c_time.v_oc_ts_anx_day_task;

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

PROMPT
PROMPT Projects and whether they resolve to a main-application code.
PROMPT A NULL MAIN_PROJECT_NUMBER is a link db/81 has not made.

COLUMN pname FORMAT A32
SELECT p.project_number AS fusion_number, p.project_name AS pname,
       p.revenue_model,
       NVL(TO_CHAR(p.main_project_id),'-')  AS main_id,
       NVL(m.project_number,'(not linked)') AS main_number
  FROM oc_time_project p
  LEFT JOIN oc_main_project_src m ON m.project_id = p.main_project_id
 WHERE p.status = 'Active'
   AND EXISTS (SELECT 1 FROM oc_time_allocation al
                WHERE al.project_id = p.project_id AND al.status = 'Active')
 ORDER BY p.project_number;

PROMPT
PROMPT Row counts at each level. All zero until a month is confirmed - the
PROMPT interface is written by confirm_month and by nothing else.

SELECT 'month'    AS level_, COUNT(*) AS rows_ FROM v_oc_ts_anx_month
UNION ALL SELECT 'day',      COUNT(*) FROM v_oc_ts_anx_day
UNION ALL SELECT 'day_task', COUNT(*) FROM v_oc_ts_anx_day_task;

PROMPT
PROMPT NEXT: run db/09_pkg_oc_time.sql. confirm_month is edited there to fill
PROMPT the two new columns; until it is recompiled they stay null on newly
PROMPT confirmed months, and [2/5] only backfills what is already there.
