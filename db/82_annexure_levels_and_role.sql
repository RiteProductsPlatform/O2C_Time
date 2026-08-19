--==============================================================
-- time/82_annexure_levels_and_role.sql
-- O2C Timesheet Module — the role on the hand-off, and four ways to read it
--
-- Two asks from 19-Aug, and they are the same ask at two ends of one pipe.
--
--   "when we are storing the summary which this O2C main application accrual
--    screen will take, we need to have the roles against the person"
--
--   "we will be giving monthly summary, weekly summary, daily summary and
--    daily taskwise, for each project, as this time data will be attached as
--    an annexure to the AR invoice"
--
-- CLIENT_ROLE ON THE INTERFACE. XX_O2C_TIMESHEET_ACCRUAL_IF already carries
-- employee, project, task, date, hours and revenue model -- everything except
-- who the person was on that project. An accrual reader deciding what a line
-- is worth needs the role, and an invoice annexure that lists eight people
-- without saying whether they are an architect or a trainee is not evidence a
-- customer can check.
--
-- WHY IT IS COPIED, NOT JOINED. Every other descriptive column here is
-- denormalised for the same stated reason: "the consumer is a different
-- application that cannot join to our master cache, so names travel with ids".
-- A role read live would also answer today's question about last March --
-- people change role, and an annexure attached to a sent invoice must not.
--
-- FOUR LEVELS, ONE GRAIN. The interface is already day x employee x project x
-- task, which is the finest of the four; the other three are that, grouped.
-- No new storage and no second source, so a total can never disagree with the
-- detail under it -- which is the only property that matters when a customer
-- adds the daily lines up and checks them against the monthly figure.
--
--   V_OC_TS_ANX_DAY_TASK   day x task     the raw grain
--   V_OC_TS_ANX_DAY        day            tasks collapsed
--   V_OC_TS_ANX_WEEK       week           weeks clipped to the month
--   V_OC_TS_ANX_MONTH      month          per employee per project
--
-- ALL FOUR READ THE INTERFACE, NOT OC_TS_ENTRY, and that is db/14's rule
-- rather than a new one: an annexure is attached to an invoice and then never
-- changes. Reading live entries would let a correction made next month rewrite
-- the annexure of an invoice already sent.
--
-- WEEKS ARE CLIPPED TO THE MONTH, matching OC_TS_WEEK. A week straddling a
-- month boundary belongs to two invoices, and the annexure has to add up to the
-- invoice it is attached to -- so the week is cut at the month end exactly as
-- the timesheet cuts it.
--
-- Idempotent. Depends on: time/07, time/09, time/14.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables
   WHERE table_name = 'XX_O2C_TIMESHEET_ACCRUAL_IF';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] CLIENT_ROLE on the accrual interface
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE
    'ALTER TABLE xx_o2c_timesheet_accrual_if ADD (CLIENT_ROLE VARCHAR2(120 CHAR))';
  DBMS_OUTPUT.PUT_LINE('CLIENT_ROLE added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN
    DBMS_OUTPUT.PUT_LINE('CLIENT_ROLE already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

COMMENT ON COLUMN xx_o2c_timesheet_accrual_if.client_role IS
  'The person''s role on this project when the month was confirmed, copied from OC_TIME_ALLOCATION.CLIENT_ROLE. Denormalised like every other name here: the consumer cannot join to our cache, and an annexure must not change when somebody changes role.';

PROMPT ============================================================
PROMPT [2/4] Backfill what is already confirmed
PROMPT ============================================================

-- Rows written before the column existed. Taken from the allocation as it
-- stands, which is the best available answer and is stated as such: for a
-- month confirmed before the role was ever synced there is no historical role
-- to recover. Only rows still NULL are touched, so a later correct value is
-- never overwritten by a current one.
DECLARE
  v_n NUMBER;
BEGIN
  UPDATE xx_o2c_timesheet_accrual_if i
     SET i.client_role =
           (SELECT MAX(al.client_role)
              FROM oc_time_allocation al
              JOIN oc_time_project p ON p.project_id = al.project_id
             WHERE al.employee_id   = i.employee_id
               AND p.project_number = i.project_number)
   WHERE i.client_role IS NULL
     AND EXISTS (SELECT 1
                   FROM oc_time_allocation al
                   JOIN oc_time_project p ON p.project_id = al.project_id
                  WHERE al.employee_id   = i.employee_id
                    AND p.project_number = i.project_number
                    AND al.client_role IS NOT NULL);
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' interface row(s) back-filled with a role.');
  DBMS_OUTPUT.PUT_LINE('  Zero is expected until the ALLOCATIONS feed carries '
                    || 'CLIENT_ROLE - deploy and re-run that extract first.');
END;
/

PROMPT ============================================================
PROMPT [3/4] The four annexure levels
PROMPT ============================================================

-- ── FINEST: day x task ──────────────────────────────────────
-- The interface itself, named and shaped for the annexure. Entry type and flag
-- are kept because a Reversal or Adjustment line is the thing a customer
-- queries, and a net figure with no sign of the correction invites exactly the
-- question the annexure exists to pre-empt.
CREATE OR REPLACE VIEW v_oc_ts_anx_day_task AS
SELECT i.confirm_id, i.period, i.period_year, i.period_month,
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

-- ── DAY: tasks collapsed ────────────────────────────────────
CREATE OR REPLACE VIEW v_oc_ts_anx_day AS
SELECT confirm_id, period, period_year, period_month,
       project_number, project_name, customer_name, revenue_model,
       employee_id, employee_name, worker_type, client_role,
       work_date,
       TO_CHAR(work_date,'DY') AS day_name,
       COUNT(DISTINCT wbs_task)          AS task_count,
       SUM(billable_hours)               AS billable_hours,
       SUM(non_billable_hours)           AS non_billable_hours,
       SUM(leave_hours)                  AS leave_hours,
       SUM(billable_hours + non_billable_hours + leave_hours) AS total_hours
  FROM xx_o2c_timesheet_accrual_if
 GROUP BY confirm_id, period, period_year, period_month,
          project_number, project_name, customer_name, revenue_model,
          employee_id, employee_name, worker_type, client_role, work_date;

-- ── WEEK: clipped to the month ──────────────────────────────
-- GREATEST(week start, 1st) and LEAST(week end, month end) -- the same clipping
-- OC_TS_WEEK applies, and for the same reason: a week straddling month end
-- belongs to two invoices, and each annexure must add up to its own.
--
-- The week number is derived from the clipped start rather than stored, so it
-- cannot drift from the dates beside it.
CREATE OR REPLACE VIEW v_oc_ts_anx_week AS
SELECT confirm_id, period, period_year, period_month,
       project_number, project_name, customer_name, revenue_model,
       employee_id, employee_name, worker_type, client_role,
       week_start, week_end,
       TO_CHAR(week_start,'DD-Mon') || ' to '
         || TO_CHAR(week_end,'DD-Mon')                        AS week_range,
       TO_NUMBER(TO_CHAR(week_start,'W'))                     AS week_index,
       COUNT(DISTINCT work_date)                              AS days_worked,
       SUM(billable_hours)                                    AS billable_hours,
       SUM(non_billable_hours)                                AS non_billable_hours,
       SUM(leave_hours)                                       AS leave_hours,
       SUM(billable_hours + non_billable_hours + leave_hours) AS total_hours
  FROM (SELECT i.*,
               GREATEST(TRUNC(i.work_date,'IW'),
                        TRUNC(i.work_date,'MM'))              AS week_start,
               LEAST(TRUNC(i.work_date,'IW') + 6,
                     LAST_DAY(TRUNC(i.work_date,'MM')))       AS week_end
          FROM xx_o2c_timesheet_accrual_if i)
 GROUP BY confirm_id, period, period_year, period_month,
          project_number, project_name, customer_name, revenue_model,
          employee_id, employee_name, worker_type, client_role,
          week_start, week_end;

-- ── MONTH: per employee per project ─────────────────────────
-- Deliberately NOT replacing V_OC_TS_INVOICE_ANNEXURE, which separates actuals
-- from adjustments for the same month and answers a different question. This is
-- the top of one consistent ladder; that one is the commercial view.
CREATE OR REPLACE VIEW v_oc_ts_anx_month AS
SELECT confirm_id, period, period_year, period_month,
       project_number, project_name, customer_name, revenue_model,
       employee_id, employee_name, worker_type, client_role,
       MIN(work_date)                                         AS first_day,
       MAX(work_date)                                         AS last_day,
       COUNT(DISTINCT work_date)                              AS days_worked,
       SUM(billable_hours)                                    AS billable_hours,
       SUM(non_billable_hours)                                AS non_billable_hours,
       SUM(leave_hours)                                       AS leave_hours,
       SUM(billable_hours + non_billable_hours + leave_hours) AS total_hours
  FROM xx_o2c_timesheet_accrual_if
 GROUP BY confirm_id, period, period_year, period_month,
          project_number, project_name, customer_name, revenue_model,
          employee_id, employee_name, worker_type, client_role;

PROMPT ============================================================
PROMPT [4/4] Verification — the four levels must agree
PROMPT ============================================================

COLUMN level_name FORMAT A16
SELECT 'day x task' AS level_name, COUNT(*) AS rows_,
       NVL(SUM(total_hours),0) AS hours FROM v_oc_ts_anx_day_task
UNION ALL
SELECT 'day',   COUNT(*), NVL(SUM(total_hours),0) FROM v_oc_ts_anx_day
UNION ALL
SELECT 'week',  COUNT(*), NVL(SUM(total_hours),0) FROM v_oc_ts_anx_week
UNION ALL
SELECT 'month', COUNT(*), NVL(SUM(total_hours),0) FROM v_oc_ts_anx_month;

PROMPT
PROMPT ROW COUNTS FALL, HOURS MUST NOT MOVE. All four are the same rows grouped
PROMPT differently, so any difference in the hours column is a grouping key that
PROMPT does not hold - which is exactly what a customer adding up the daily
PROMPT lines against the monthly total would find.

SELECT COUNT(*) AS rows_missing_a_role
  FROM xx_o2c_timesheet_accrual_if WHERE client_role IS NULL;

PROMPT
PROMPT Non-zero until the ALLOCATIONS extract is redeployed with CLIENT_ROLE and
PROMPT a month is confirmed after it. Existing rows are back-filled in [2/4]
PROMPT where an allocation can answer for them.
