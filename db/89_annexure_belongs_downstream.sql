--==============================================================
-- time/89_annexure_belongs_downstream.sql
-- O2C Timesheet Module — we record the cover; somebody else prints the annexure
--
-- Asked 20-Aug, immediately after db/88 landed:
--
--   "we will just assign and approve a person who is going to cover it from
--    time module - annexure will be done by the down stream system, not in
--    time module"
--
-- db/88 went one step too far. It built V_OC_TS_LLC_ANNEXURE_NOTE, which
-- composes the printed English sentence -- "Sam Joshuva S was absent on 07-Aug
-- (covered by Kishore Krovvidi)." That is the downstream system's wording to
-- choose, in its own layout and its own language, and a sentence assembled here
-- is one it would have to either accept or ignore. Dropped.
--
-- WHAT WE OWE THE DOWNSTREAM IS FACTS: absent employee, date, covering
-- colleague, and that a manager approved it. V_OC_TS_LLC_ANNEXURE already
-- carries exactly that and keeps its name -- REP-002 and the ORDS contract
-- accrual/annexure/:periodId both use it, and renaming a hand-off to make a
-- point is not worth breaking a consumer for.
--
-- ── THREE CONSUMERS DB/88 DID NOT REACH, AND ONE IS BROKEN NOW ───────────
--
-- Removing COVERED_BILLED_HOURS from the view left three readers pointing at a
-- column that no longer exists. Measured, not assumed:
--
--   GET /oc/time/admin/accrual/annexure/46
--   403 "a function referenced by the SQL statement being evaluated is not
--        accessible or does not exist"
--
-- That is ORDS's wording for a collection feed whose SELECT will not resolve.
-- Fixed by re-running ords/13 after this.
--
--   1. ords/13 accrual/annexure  selects covered_billed_hours, billed_flag
--   2. db/14  V_OC_TS_INVOICE_ANNEXURE_HDR.LLC_BILLED_HOURS
--             sums covered_billed_hours -- so that view is INVALID as it stands
--   3. VBCS   the Accrual Integration page renders a "Billed hrs" column
--
-- LLC_BILLED_HOURS IS REPLACED, NOT DELETED. The cover sheet was right to want
-- something about coverage on it -- db/14's own comment says the point is that
-- the header reconciles against the lines instead of the two being totalled by
-- hand. But the honest figure is not hours, because coverage bills none. It is
-- LLC_COVERED_DAYS, a count of absences a colleague covered. A cover sheet can
-- say "3 absences covered" truthfully; it cannot say "6 hours billed".
--
-- Idempotent. Supersedes db/88 [4/7] and db/07's annexure section.
-- Depends on: time/07, 08, 14, 88.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views WHERE view_name = 'V_OC_TS_LLC_ANNEXURE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'V_OC_TS_LLC_ANNEXURE' AND column_name = 'COVERED_BILLED_HOURS';
  IF v_n > 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'db/88 has not been run here: '
      || 'V_OC_TS_LLC_ANNEXURE still has COVERED_BILLED_HOURS.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] Drop the composed sentence — that wording is not ours
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'DROP VIEW v_oc_ts_llc_annexure_note';
  DBMS_OUTPUT.PUT_LINE('  V_OC_TS_LLC_ANNEXURE_NOTE dropped.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -942 THEN
    DBMS_OUTPUT.PUT_LINE('  V_OC_TS_LLC_ANNEXURE_NOTE not present - skipped.');
  ELSE RAISE; END IF;
END;
/

COMMENT ON TABLE v_oc_ts_llc_annexure IS
  'REP-002 hand-off. The FACTS behind the leave-loss annexure - absent employee, date, covering colleague, approval - at the grain the requirement metadata states. It carries no hours: coverage moves none, and the invoice figures come from the monthly summary. The downstream system composes and prints the annexure from this; the wording is its choice, not ours.';

PROMPT ============================================================
PROMPT [2/4] The cover sheet counts covered days, not billed hours
PROMPT ============================================================

-- Only the LLC scalar subquery changes; every other column is db/14's.
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
       -- WAS LLC_BILLED_HOURS, summing COVERED_BILLED_HOURS. db/14 was right
       -- that coverage belongs on the cover sheet -- its own note says the
       -- point is that the header reconciles against the lines rather than the
       -- two being totalled by hand and quietly disagreeing.
       --
       -- It is a COUNT now, because there are no hours to total. Coverage moves
       -- none: the covering colleague's time stays unbilled and the absentee's
       -- leave stays in the leave column, so every hour on this cover sheet is
       -- already in the four SUMs above. Adding an hours figure for coverage
       -- would double-count the same day into the same total.
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
PROMPT [3/4] Nothing left INVALID
PROMPT ============================================================

-- A view that selects a dropped column stays INVALID until something
-- recompiles it, and ORDS answers 403 rather than naming the column -- which is
-- how the annexure endpoint failed without saying why.
DECLARE
  v_bad NUMBER := 0;
BEGIN
  FOR r IN (SELECT object_name, object_type FROM user_objects
             WHERE status <> 'VALID'
               AND object_type IN ('VIEW','PROCEDURE','FUNCTION','PACKAGE','PACKAGE BODY','TRIGGER')
             ORDER BY object_type, object_name)
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER ' ||
        CASE r.object_type WHEN 'PACKAGE BODY' THEN 'PACKAGE' ELSE r.object_type END
        || ' ' || r.object_name || ' COMPILE'
        || CASE WHEN r.object_type = 'PACKAGE BODY' THEN ' BODY' ELSE '' END;
    EXCEPTION WHEN OTHERS THEN NULL;   -- reported below if it is still broken
    END;
  END LOOP;

  FOR r IN (SELECT object_name, object_type FROM user_objects
             WHERE status <> 'VALID' ORDER BY object_type, object_name)
  LOOP
    DBMS_OUTPUT.PUT_LINE('  STILL INVALID: ' || r.object_type || ' ' || r.object_name);
    v_bad := v_bad + 1;
  END LOOP;

  IF v_bad = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Every object valid.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN absent FORMAT A24
COLUMN cover  FORMAT A24
COLUMN proj   FORMAT A10

PROMPT
PROMPT What the downstream reads. Facts only, no hours, no sentence.

SELECT project_number AS proj, absence_date, absence_day,
       absent_employee_name AS absent,
       cover_employee_name  AS cover,
       approved_by, approved_on
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;

PROMPT
PROMPT And the cover sheet's coverage figure, which is now a count of days.

COLUMN object_name FORMAT A34
SELECT column_name, data_type
  FROM user_tab_columns
 WHERE table_name = 'V_OC_TS_INVOICE_ANNEXURE_HDR'
   AND column_name IN ('LLC_COVERED_DAYS','LLC_BILLED_HOURS')
 ORDER BY column_name;

PROMPT
PROMPT LLC_COVERED_DAYS should be the only row; LLC_BILLED_HOURS is gone.
PROMPT Every hour on that cover sheet is already in its four SUMs, so a
PROMPT coverage hours figure would count the same day twice.

PROMPT
PROMPT NEXT: run db/ords/13_ords_time_admin.sql. Its accrual/annexure handler
PROMPT still selects COVERED_BILLED_HOURS and answers 403 until it is redefined.
