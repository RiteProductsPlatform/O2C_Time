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
--   2. db/14  V_OC_TS_INVOICE_ANNEXURE_HDR.LLC_BILLED_HOURS sums the column.
--             NOT invalid, as this note first said -- db/14 has never been run
--             on this schema, so the view is ABSENT. It is in install_time.sql
--             though, so the fix belongs in db/14 itself; [2/4] only patches a
--             schema where it is already built.
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

-- CORRECTED AT SOURCE IN db/14, AND ONLY PATCHED HERE IF IT IS INSTALLED.
--
-- The first version of this section rebuilt V_OC_TS_INVOICE_ANNEXURE_HDR
-- unconditionally and failed with ORA-00942, because V_OC_TS_INVOICE_ANNEXURE
-- does not exist on this schema: db/14 has never been run here. The header view
-- was not INVALID, as the note at the top of this file first claimed -- it was
-- ABSENT, which is exactly why [3/4] could report every object valid. Those two
-- states look the same from a distance and are not the same thing.
--
-- db/14 IS in install_time.sql, so it will run one day, and an unconditional
-- fix here would have left the wrong column to be recreated the moment it did.
-- The LLC_BILLED_HOURS -> LLC_COVERED_DAYS change therefore lives in db/14
-- itself. This section only re-applies it where the view is already built.
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views
   WHERE view_name = 'V_OC_TS_INVOICE_ANNEXURE';

  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  db/14 is not installed here, so there is no cover '
      || 'sheet to correct. Its source already says LLC_COVERED_DAYS.');
    RETURN;
  END IF;

  EXECUTE IMMEDIATE q'~
    CREATE OR REPLACE VIEW v_oc_ts_invoice_annexure_hdr AS
    SELECT c.confirm_id, c.project_id, a.project_number, a.project_name,
           a.customer_name, a.revenue_model, a.period,
           c.period_year, c.period_month,
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
           NVL((SELECT COUNT(*) FROM v_oc_ts_llc_annexure l
                 WHERE l.project_id = c.project_id
                   AND l.period_id  = c.period_id),0)     AS llc_covered_days,
           c.confirm_type, c.confirmed_by,
           TO_CHAR(c.confirmed_on,'YYYY-MM-DD HH24:MI')   AS confirmed_on,
           c.accrual_status, c.otl_status, c.partner_status
      FROM oc_ts_month_confirm c
      JOIN v_oc_ts_invoice_annexure a ON a.confirm_id = c.confirm_id
     GROUP BY c.confirm_id, c.project_id, a.project_number, a.project_name,
              a.customer_name, a.revenue_model, a.period, c.period_year,
              c.period_month, c.period_id, c.confirm_type, c.confirmed_by,
              c.confirmed_on, c.accrual_status, c.otl_status, c.partner_status
  ~';
  DBMS_OUTPUT.PUT_LINE('  V_OC_TS_INVOICE_ANNEXURE_HDR now counts covered days.');
END;
/

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
PROMPT And the cover sheet's coverage figure, if db/14 is installed here.
PROMPT No rows at all means it is not, which is expected on this schema.

COLUMN column_name FORMAT A24
SELECT column_name, data_type
  FROM user_tab_columns
 WHERE table_name = 'V_OC_TS_INVOICE_ANNEXURE_HDR'
   AND column_name IN ('LLC_COVERED_DAYS','LLC_BILLED_HOURS')
 ORDER BY column_name;

PROMPT
PROMPT If a row appears it must be LLC_COVERED_DAYS. Every hour on that cover
PROMPT sheet is already in its four SUMs, so a coverage hours figure would
PROMPT count the same day twice.

PROMPT
PROMPT NEXT: run db/ords/13_ords_time_admin.sql. Its accrual/annexure handler
PROMPT still selects COVERED_BILLED_HOURS and answers 403 until it is redefined.
