--==============================================================
-- time/118_full_rebuild_for_testing.sql
-- O2C Timesheet Module -- clear EVERY period's transactions so the module can
-- be rebuilt and tested from a known-empty state
--
-- DEVELOPMENT AND SIT ONLY. NOT FOR UAT OR PRODUCTION.
--
-- Asked 22-Aug: "I want to clear all data and redo it for testing so i want to
-- clear the data, resync, and then apply all the cutoff."
--
-- -- HOW THIS DIFFERS FROM db/90 --------------------------------
--
-- db/90 clears ONE period and REFUSES a period confirmed to accrual, because a
-- confirmed month is a number somebody downstream has been given. That guard is
-- right and it is why this is a separate script rather than a loop around that
-- one: the instruction here is explicitly to take July too.
--
-- JUL-2026 IS CONFIRMED -- confirm_id 429, 116 rows, 600.00 hours, sent this
-- week. Removing it removes the only standing evidence that the accrual
-- hand-off has ever run end to end. That evidence is reproducible -- confirm
-- July again after the rebuild and it comes back -- but until somebody does,
-- nothing in the schema shows it has worked. Confirmed as intended before this
-- script was written; recorded here so nobody later reads it as an accident.
--
-- The accrual consumer is NOT told. PARTNER_STATUS is Pending and the push is
-- dormant (section 1), and the pull is theirs to call -- so the interface rows
-- disappearing is invisible to them rather than a retraction. In an
-- environment where the pull was live this script would be wrong.
--
-- -- WHAT IS REMOVED, ACROSS ALL PERIODS -------------------------
--
--   weeks, entries, week flags and versions, approvals, the audit trail,
--   month confirmations, accrual interface rows, salary holds and their days,
--   adjustments, leave-loss cover, client documents
--
-- -- WHAT IS KEPT ------------------------------------------------
--
--   MASTER DATA -- worker, project, task, allocation, absence, calendar. The
--   resync in step 2 of the runbook refreshes it; wiping it first would mean a
--   full extract rather than a delta and buys nothing.
--
--   REFERENCE DATA -- periods, cut-offs, lookups, flag definitions, the
--   transition table, PRJ-ORG, the COMMON tasks.
--
--   LOGINS -- OC_TIME_USER and its sessions. Clearing them locks everyone out
--   including the common administrator, and none of it is timesheet data.
--
--   SYNC LOGS -- OC_TIME_SYNC_JOB, _FAILED and _CHANGE. They record how data
--   arrived, which is exactly what you want to read when the rebuild behaves
--   oddly. db/90 keeps them for the same reason.
--
-- -- PERIODS ARE LEFT ALONE ---------------------------------------
--
-- Asked for explicitly. Only AUG-2026 is Open; JUL, SEP and OCT stay Closed.
-- Consequence, stated once and then not laboured: the 30-Aug population will
-- build SEP-2026 and nobody will be able to type into it until finance opens
-- the month. Section [5] prints the state so it stays visible.
--
-- DESTRUCTIVE AND NOT REVERSIBLE. Idempotent -- running it twice clears
-- nothing the second time. Depends on: time/03..07, 15, 19.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [0/6] What is about to be removed
PROMPT ============================================================

-- READ THIS BEFORE GOING ON. Everything listed here goes.
COLUMN period_name FORMAT A12
SELECT p.period_name, p.status,
       COUNT(DISTINCT w.ts_week_id)   AS weeks,
       COUNT(DISTINCT w.employee_id)  AS people,
       COUNT(e.ts_entry_id)           AS entries,
       TRIM(TO_CHAR(NVL(SUM(e.hours),0),'FM999990.00')) AS hours
  FROM oc_time_period p
  LEFT JOIN oc_ts_week  w ON w.period_id  = p.period_id
  LEFT JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
 GROUP BY p.period_name, p.status, p.period_year, p.period_month
 ORDER BY p.period_year, p.period_month;

PROMPT
PROMPT --- and the things that outlive a single period
SELECT 'month confirmations' AS what, COUNT(*) AS rows_ FROM oc_ts_month_confirm
UNION ALL SELECT 'accrual interface rows', COUNT(*) FROM xx_o2c_timesheet_accrual_if
UNION ALL SELECT 'salary holds',           COUNT(*) FROM oc_ts_salary_hold
UNION ALL SELECT 'adjustments',            COUNT(*) FROM oc_ts_adjustment
UNION ALL SELECT 'leave-loss cover',       COUNT(*) FROM oc_ts_leave_loss_cover
UNION ALL SELECT 'client documents',       COUNT(*) FROM oc_ts_client_doc
UNION ALL SELECT 'audit rows',             COUNT(*) FROM oc_ts_audit;

PROMPT ============================================================
PROMPT [1/6] Lift the append-only guards
PROMPT ============================================================

-- db/19 made OC_TS_AUDIT and OC_TS_APPROVAL append-only, refusing UPDATE and
-- DELETE with -20026, because a trail that can be rewritten is not one. The
-- triggers are STATEMENT level, so they fire even when the WHERE matches
-- nothing -- a reset cannot touch these tables without lifting the guard
-- deliberately, which is the intended friction.
--
-- Put back in [3]. IF THIS SCRIPT STOPS PART WAY, CHECK [3] RAN -- a schema
-- left with the guards disabled has an audit trail anything can edit.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_audit_append_only DISABLE';
  DBMS_OUTPUT.PUT_LINE('  audit guard disabled');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('  audit guard: ' || SQLERRM);
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only DISABLE';
  DBMS_OUTPUT.PUT_LINE('  approval guard disabled');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('  approval guard: ' || SQLERRM);
END;
/

PROMPT ============================================================
PROMPT [2/6] Clear every period
PROMPT ============================================================

-- Children before parents. The order mirrors db/90 so the two cannot drift on
-- which table references which; the difference is only that nothing here is
-- filtered by period.
DECLARE
  TYPE t_counts IS TABLE OF NUMBER INDEX BY VARCHAR2(40);
  v t_counts;
  PROCEDURE wipe(p_label VARCHAR2, p_sql VARCHAR2) IS
    v_n NUMBER;
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    v_n := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_label, 26) || TO_CHAR(v_n, '999999'));
  EXCEPTION WHEN OTHERS THEN
    -- Reported, not raised: a table this schema does not have (a rollback
    -- level, a feature not installed) must not stop the rest of the wipe.
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_label, 26) || ' SKIPPED - ' || SQLERRM);
  END wipe;
BEGIN
  wipe('audit trail',        'DELETE FROM oc_ts_audit');
  wipe('entries',            'DELETE FROM oc_ts_entry');
  wipe('week flags',         'DELETE FROM oc_ts_week_flag');
  wipe('week versions',      'DELETE FROM oc_ts_week_version');
  wipe('approvals',          'DELETE FROM oc_ts_approval');
  wipe('salary hold days',   'DELETE FROM oc_ts_salary_hold_day');
  wipe('salary holds',       'DELETE FROM oc_ts_salary_hold');
  wipe('leave-loss cover',   'DELETE FROM oc_ts_leave_loss_cover');
  wipe('client documents',   'DELETE FROM oc_ts_client_doc');
  wipe('adjustments',        'DELETE FROM oc_ts_adjustment');
  wipe('accrual interface',  'DELETE FROM xx_o2c_timesheet_accrual_if');
  wipe('month confirmations','DELETE FROM oc_ts_month_confirm');
  wipe('weeks',              'DELETE FROM oc_ts_week');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [3/6] Put the append-only guards back
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_audit_append_only ENABLE';
  DBMS_OUTPUT.PUT_LINE('  audit guard re-enabled');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('  *** COULD NOT RE-ENABLE trg_oc_ts_audit_append_only');
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
  DBMS_OUTPUT.PUT_LINE('  approval guard re-enabled');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('  *** COULD NOT RE-ENABLE trg_oc_ts_approval_append_only');
END;
/

COLUMN trigger_name FORMAT A36
SELECT trigger_name, status
  FROM user_triggers
 WHERE trigger_name IN ('TRG_OC_TS_AUDIT_APPEND_ONLY',
                        'TRG_OC_TS_APPROVAL_APPEND_ONLY')
 ORDER BY trigger_name;

PROMPT
PROMPT BOTH MUST READ ENABLED. A DISABLED row here means the audit trail is
PROMPT editable and this script must not be considered finished.

PROMPT ============================================================
PROMPT [4/6] The allocation PPM does not have
PROMPT ============================================================

-- CRI0398 carries 100% on project 666 from 18-Aug. Manage Project Resources
-- for 666 lists two people and he is not one of them, so the row is a ghost:
-- sync/allocation is a bare MERGE over a DELTA feed, so a row removed in PPM
-- stops appearing rather than arriving marked as gone, and nothing infers the
-- deletion. Once an allocation lands it is permanent.
--
-- Cleared here because the wipe above does not touch master data, so it would
-- otherwise survive the rebuild and give him 200% and sixteen-hour days again.
--
-- THIS DOES NOT CLOSE THE HOLE. The fix is a full-set claim on the allocation
-- sync -- 1,595 rows, so cheap -- in the same shape as the windowed claim that
-- fixed cancelled absences. Narrow on purpose: a blanket "deactivate anything
-- the last delta did not mention" here would deactivate almost everything.
-- 'Ended', NOT 'Inactive'. CHK_OC_TAL_STATUS admits ('Active','Ended') only,
-- and the first version of this script guessed 'Inactive' and failed with
-- ORA-02290. db/44 and db/69 both already record the allowed pair; the mistake
-- was not reading them.
DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_allocation
     SET status     = 'Ended',
         end_date   = NVL(end_date, TRUNC(SYSDATE)),
         updated_by = 'DB_118_NOT_IN_PPM',
         updated_on = SYSTIMESTAMP
   WHERE employee_id = 'CRI0398'
     AND status      = 'Active'
     AND project_id IN (SELECT project_id FROM oc_time_project
                         WHERE project_number = '666');
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ghost allocations ended: ' || v_n);
END;
/

COLUMN nm FORMAT A24
SELECT al.employee_id, w.employee_name AS nm, p.project_number,
       al.alloc_pct, al.status, TO_CHAR(al.end_date,'DD-Mon-YY') AS ends
  FROM oc_time_allocation al
  JOIN oc_time_worker  w ON w.employee_id = al.employee_id
  JOIN oc_time_project p ON p.project_id  = al.project_id
 WHERE al.employee_id = 'CRI0398'
 ORDER BY al.status, p.project_number;

PROMPT ============================================================
PROMPT [5/6] Re-derive roles from the corrected allocations
PROMPT ============================================================

-- APP_ROLE is computed from HCM and PPM and is a snapshot until something
-- calls this. Allocations changed today -- RI2894 and RI2249 to 100%, RI2985
-- newly onto Business World RODS Upgrade, CRI0398 off 666 -- so the stored
-- roles are stale until it runs.
--
-- RI2985 in particular cannot sign in until this has run: with no allocation
-- he derived ROLE_TIME_NONE, and the sign-in refusal names the administrator,
-- who has no screen for it because the column must never be typed.
--
-- RUN THIS AGAIN AFTER THE RESYNC in step 2 of the runbook. It reads what is
-- in OC_TIME_ALLOCATION now, which is not yet what Fusion says.
DECLARE
  v_changed NUMBER;
BEGIN
  oc_time_derive_roles('DB_118', v_changed);
  DBMS_OUTPUT.PUT_LINE('  ' || v_changed || ' worker role(s) corrected.');
END;
/

COLUMN nm FORMAT A26
SELECT w.employee_id, w.employee_name AS nm, w.app_role,
       NVL((SELECT SUM(al.alloc_pct) FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id AND al.status = 'Active'),0)
         AS alloc_pct
  FROM oc_time_worker w
 WHERE w.employee_id IN ('RI9001','RI2894','RI2824','RI2249','RI2900','RI2963',
                         'RI2935','RI2985','RI3004','RI2914','CRI0406','CRI0398')
 ORDER BY w.employee_name;

PROMPT ============================================================
PROMPT [6/6] The state you are starting from
PROMPT ============================================================

SELECT 'weeks' AS what, COUNT(*) AS rows_ FROM oc_ts_week
UNION ALL SELECT 'entries',       COUNT(*) FROM oc_ts_entry
UNION ALL SELECT 'approvals',     COUNT(*) FROM oc_ts_approval
UNION ALL SELECT 'audit rows',    COUNT(*) FROM oc_ts_audit
UNION ALL SELECT 'confirmations', COUNT(*) FROM oc_ts_month_confirm
UNION ALL SELECT 'accrual rows',  COUNT(*) FROM xx_o2c_timesheet_accrual_if
UNION ALL SELECT 'salary holds',  COUNT(*) FROM oc_ts_salary_hold;

PROMPT
PROMPT --- master data survived, and is what the rebuild will use
SELECT 'workers' AS what, COUNT(*) AS rows_ FROM oc_time_worker
UNION ALL SELECT 'projects',            COUNT(*) FROM oc_time_project
UNION ALL SELECT 'tasks',               COUNT(*) FROM oc_time_task
UNION ALL SELECT 'active allocations',  COUNT(*) FROM oc_time_allocation
                                         WHERE status = 'Active'
UNION ALL SELECT 'absences',            COUNT(*) FROM oc_time_absence
UNION ALL SELECT 'logins',              COUNT(*) FROM oc_time_user;

PROMPT
PROMPT --- periods, left exactly as they were, by instruction
-- EDITABLE_FLAG is NOT on v_oc_time_cutoffs -- that view is period reference
-- data. The derived flag lives on v_oc_ts_my_periods, which is what
-- GET /oc/time/periods reads.
COLUMN period_name FORMAT A12
SELECT period_name, status, period_state, editable_flag, adjustment_allowed
  FROM v_oc_ts_my_periods
 ORDER BY period_id;

PROMPT
PROMPT NEXT, in this order. Populating before the resync rebuilds the same
PROMPT wrong numbers, because populate_month is insert-if-missing and will not
PROMPT revisit a day once it has a row.
PROMPT
PROMPT   2. resync master data from Fusion, then re-run [5/6] of this script
PROMPT   3. POST jobs/populate/46            AUG-2026
PROMPT   4. POST jobs/defaulting/46          weekly cut-off, employee
PROMPT   5. POST jobs/delivery-defaulting/46 delivery cut-off, manager
PROMPT
PROMPT Weekly before delivery: delivery defaulting writes DEFAULTED_BY=MANAGER,
PROMPT which is the value salary stopping must NOT hold pay on (RULE-016).
