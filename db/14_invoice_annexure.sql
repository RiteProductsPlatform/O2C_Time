--==============================================================
-- time/14_invoice_annexure.sql
-- O2C Timesheet Module — invoice annexure over the accrual hand-off
--
-- What goes out WITH the invoice: a project-level summary and the per-person
-- timesheet summary behind it, so the customer can see how the billed hours
-- were arrived at.
--
-- SOURCED FROM XX_O2C_TIMESHEET_ACCRUAL_IF, NOT FROM OC_TS_ENTRY, and that is
-- the whole design. An annexure is attached to an invoice and then never
-- changes. Reading live entries would mean a correction made next month
-- silently rewrites the annexure of an invoice already sent, so the document in
-- the customer's hand and the document the system reprints would disagree with
-- no record of why. The interface rows are written once by confirm_month,
-- carry their CONFIRM_ID, and are exactly what accrual was given — so
-- reprinting an old annexure reproduces it, and the annexure can never claim
-- hours the invoice did not bill. Same reasoning as V_OC_TS_ACCRUAL_EXTRACT:
-- "from the same rows, so the screen can never disagree with the hand-off".
--
-- CONSEQUENCE, and it is intended: a month that has not been confirmed has no
-- annexure. There is nothing to annexe to an invoice for hours nobody has
-- handed over yet.
--
-- Idempotent. Depends on: time/04, time/07
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/2] V_OC_TS_INVOICE_ANNEXURE — per person, per confirmed month
PROMPT ============================================================

-- One row per employee per project per confirmed month: the individual's
-- timesheet reduced to the numbers an invoice needs.
--
-- ACTUALS AND ADJUSTMENTS ARE SEPARATE COLUMNS, not just a net. A reversal
-- carries negative hours (CHK_XX_TSIF_SIGN), so SUM() alone gives the right
-- net and hides the fact that anything was corrected. An annexure has to show
-- the correction: a customer questioning a line needs to see 160 actual less 8
-- reversed, not a bare 152 that matches nothing they were told last month.
CREATE OR REPLACE VIEW v_oc_ts_invoice_annexure AS
SELECT i.confirm_id,
       i.period,
       i.period_year,
       i.period_month,
       i.project_number,
       i.project_name,
       i.customer_name,
       i.revenue_model,
       i.employee_id,
       i.employee_name,
       i.worker_type,
       -- The role TODAY, not the role as billed. The interface does not carry
       -- it, so this is a live join and it will change if the allocation
       -- changes. Named so nobody reads it as historical fact.
       (SELECT MIN(al.client_role)
          FROM oc_time_allocation al
          JOIN oc_time_project pr ON pr.project_id = al.project_id
         WHERE al.employee_id = i.employee_id
           AND pr.project_number = i.project_number) AS current_client_role,
       -- ── as worked ────────────────────────────────────────
       NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                    THEN i.billable_hours END),0)     AS actual_billable_hours,
       NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                    THEN i.non_billable_hours END),0) AS actual_non_billable_hours,
       NVL(SUM(CASE WHEN i.entry_type IN ('Actual','Default')
                    THEN i.leave_hours END),0)        AS actual_leave_hours,
       -- ── corrections, shown not hidden ────────────────────
       NVL(SUM(CASE WHEN i.entry_type = 'Reversal'
                    THEN i.billable_hours END),0)     AS reversal_billable_hours,
       NVL(SUM(CASE WHEN i.entry_type = 'Adjustment'
                    THEN i.billable_hours END),0)     AS adjustment_billable_hours,
       -- ── what is actually billed ──────────────────────────
       NVL(SUM(i.billable_hours),0)                   AS net_billable_hours,
       NVL(SUM(i.non_billable_hours),0)               AS net_non_billable_hours,
       NVL(SUM(i.leave_hours),0)                      AS net_leave_hours,
       NVL(SUM(i.billable_hours + i.non_billable_hours + i.leave_hours),0)
                                                      AS net_total_hours,
       -- Days with billable time. COUNT(DISTINCT) because a day can carry
       -- several task lines and must still count once.
       COUNT(DISTINCT CASE WHEN i.billable_hours > 0 THEN i.work_date END)
                                                      AS billable_days,
       COUNT(DISTINCT i.work_date)                    AS days_on_sheet,
       MIN(TO_CHAR(i.work_date,'YYYY-MM-DD'))         AS first_work_date,
       MAX(TO_CHAR(i.work_date,'YYYY-MM-DD'))         AS last_work_date,
       CASE WHEN SUM(CASE WHEN i.entry_type IN ('Reversal','Adjustment')
                          THEN 1 ELSE 0 END) > 0 THEN 'Y' ELSE 'N' END
                                                      AS has_correction_flag,
       c.confirm_type,
       TO_CHAR(c.confirmed_on,'YYYY-MM-DD')           AS confirmed_on,
       c.accrual_status
  FROM xx_o2c_timesheet_accrual_if i
  JOIN oc_ts_month_confirm c ON c.confirm_id = i.confirm_id
 GROUP BY i.confirm_id, i.period, i.period_year, i.period_month,
          i.project_number, i.project_name, i.customer_name, i.revenue_model,
          i.employee_id, i.employee_name, i.worker_type,
          c.confirm_type, c.confirmed_on, c.accrual_status;

PROMPT ============================================================
PROMPT [2/2] V_OC_TS_INVOICE_ANNEXURE_HDR — the project-level summary
PROMPT ============================================================

-- One row per confirmed project-month: the cover sheet the per-person lines
-- add up to.
--
-- Totals are re-aggregated from the interface rather than read from
-- OC_TS_MONTH_CONFIRM's stored columns, deliberately. Those are a snapshot
-- taken by confirm_month, and run_accrual_top_up can add interface rows
-- afterwards for a retro adjustment approved once the month had closed. Reading
-- the rows means the cover sheet always equals the sum of the lines beneath it,
-- which is the one property an annexure cannot be wrong about.
CREATE OR REPLACE VIEW v_oc_ts_invoice_annexure_hdr AS
SELECT c.confirm_id,
       c.project_id,
       a.project_number,
       a.project_name,
       a.customer_name,
       a.revenue_model,
       a.period,
       c.period_year,
       c.period_month,
       COUNT(DISTINCT a.employee_id)                  AS people,
       NVL(SUM(a.actual_billable_hours),0)            AS actual_billable_hours,
       NVL(SUM(a.actual_non_billable_hours),0)        AS actual_non_billable_hours,
       NVL(SUM(a.actual_leave_hours),0)               AS actual_leave_hours,
       NVL(SUM(a.reversal_billable_hours),0)          AS reversal_billable_hours,
       NVL(SUM(a.adjustment_billable_hours),0)        AS adjustment_billable_hours,
       NVL(SUM(a.net_billable_hours),0)               AS net_billable_hours,
       NVL(SUM(a.net_non_billable_hours),0)           AS net_non_billable_hours,
       NVL(SUM(a.net_leave_hours),0)                  AS net_leave_hours,
       NVL(SUM(a.net_total_hours),0)                  AS net_total_hours,
       SUM(CASE WHEN a.has_correction_flag = 'Y' THEN 1 ELSE 0 END)
                                                      AS people_with_corrections,
       -- Leave-loss coverage travels with the same invoice (PROC-006), and
       -- surfacing it here is right: the cover sheet should reconcile against
       -- V_OC_TS_LLC_ANNEXURE rather than the two being totalled by hand and
       -- quietly disagreeing.
       --
       -- A COUNT, NOT HOURS. This was SUM(covered_billed_hours) until
       -- 20-Aug-2026, when the functional owner retracted the idea that
       -- coverage bills anything: the covering colleague's time stays unbilled
       -- and the absentee's leave stays in the leave column. So every hour on
       -- this cover sheet is ALREADY inside the four SUMs above, and a coverage
       -- hours figure would count the same day twice into the same total.
       -- "3 absences covered" is true; "6 hours billed" is not.
       NVL((SELECT COUNT(*)
              FROM v_oc_ts_llc_annexure l
             WHERE l.project_id = c.project_id
               AND l.period_id  = c.period_id),0)     AS llc_covered_days,
       c.confirm_type,
       c.confirmed_by,
       TO_CHAR(c.confirmed_on,'YYYY-MM-DD HH24:MI')   AS confirmed_on,
       c.accrual_status,
       c.otl_status,
       c.partner_status
  FROM oc_ts_month_confirm c
  JOIN v_oc_ts_invoice_annexure a ON a.confirm_id = c.confirm_id
 GROUP BY c.confirm_id, c.project_id, a.project_number, a.project_name,
          a.customer_name, a.revenue_model, a.period, c.period_year,
          c.period_month, c.period_id, c.confirm_type, c.confirmed_by,
          c.confirmed_on, c.accrual_status, c.otl_status, c.partner_status;

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN object_name FORMAT A34
COLUMN status      FORMAT A10

SELECT object_name, status
  FROM user_objects
 WHERE object_type = 'VIEW'
   AND object_name IN ('V_OC_TS_INVOICE_ANNEXURE','V_OC_TS_INVOICE_ANNEXURE_HDR')
 ORDER BY object_name;

-- The property that matters: the cover sheet equals the sum of its lines.
-- Any row returned here is a defect.
COLUMN check_name FORMAT A40
SELECT 'header <> sum of lines' AS check_name, h.confirm_id,
       h.net_total_hours AS header_total,
       (SELECT SUM(a.net_total_hours) FROM v_oc_ts_invoice_annexure a
         WHERE a.confirm_id = h.confirm_id) AS lines_total
  FROM v_oc_ts_invoice_annexure_hdr h
 WHERE h.net_total_hours <> NVL((SELECT SUM(a.net_total_hours)
                                   FROM v_oc_ts_invoice_annexure a
                                  WHERE a.confirm_id = h.confirm_id),0);

PROMPT Done. Two views: _HDR is the cover sheet, the other is one row per person.
