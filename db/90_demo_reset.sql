--==============================================================
-- time/90_demo_reset.sql
-- O2C Timesheet Module — clear ONE period's transactions for a walkthrough
--
-- DESTRUCTIVE, and scoped to a single period. Read [0] before running it.
--
-- WHY PERIOD-SCOPED
--   July is approved and confirmed and stays exactly as it is. Only the month
--   being demonstrated is cleared, so the walkthrough can go through
--   prepopulate -> enter -> submit -> approve from the start while the closed
--   book behind it is untouched. A global wipe would take the approved history
--   with it and there is no getting that back.
--
-- WHAT IT REMOVES, for the target period only
--   weeks, entries, approvals, the audit trail, month confirmations, the
--   accrual interface rows, salary holds, client documents, leave-loss cover,
--   and any adjustment that POSTS into it
--
-- WHAT IT KEEPS
--   every other period, all master data (worker, project, task, allocation,
--   absence, calendar), all reference data (periods, cut-offs, lookups,
--   PRJ-ORG, the COMMON tasks), and the sync logs -- OC_TIME_SYNC_CHANGE,
--   _FAILED and _JOB are operational history, not timesheet transactions, and
--   clearing them would lose the record of how the data arrived.
--
--   Demo logins are NOT touched here. That is a separate concern from a
--   period reset and lives at the end, commented out, so it is a deliberate
--   act rather than a side effect.
--
-- Idempotent. Safe to run twice. Depends on: time/03..07, time/15, time/19
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT ============================================================
PROMPT [0/5] Which period will be cleared, and what is in each
PROMPT ============================================================

-- READ THIS BEFORE GOING ON. The target is the OPEN period containing today.
-- With JUL-2026 and AUG-2026 both open (section 7a), get_open_period_id
-- returns the one containing today -- August. Confirm that is what the
-- breakdown below says before running [2].
--
-- To clear a different period instead, replace get_open_period_id in [2] with
-- its PERIOD_ID from this list.
COLUMN period_name FORMAT A14
COLUMN status      FORMAT A8

SELECT p.period_id, p.period_name, p.status,
       (SELECT COUNT(*) FROM oc_ts_week w  WHERE w.period_id = p.period_id) AS weeks,
       (SELECT COUNT(*) FROM oc_ts_entry e
          JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
         WHERE w2.period_id = p.period_id)                                  AS entries,
       (SELECT COUNT(*) FROM oc_ts_approval a
          JOIN oc_ts_week w3 ON w3.ts_week_id = a.ts_week_id
         WHERE w3.period_id = p.period_id)                                  AS approvals,
       (SELECT COUNT(*) FROM oc_ts_month_confirm mc
         WHERE mc.period_id = p.period_id)                                  AS confirms
  FROM oc_time_period p
 WHERE EXISTS (SELECT 1 FROM oc_ts_week w4 WHERE w4.period_id = p.period_id)
 ORDER BY p.period_id;

PROMPT
PROMPT The row this script will empty is the OPEN period containing today.
PROMPT Every other row above is untouched.

PROMPT
PROMPT ============================================================
PROMPT [1/5] Lift the append-only guards
PROMPT ============================================================

-- 19_sync_change_capture.sql made OC_TS_AUDIT and OC_TS_APPROVAL append-only,
-- refusing UPDATE and DELETE with -20026, because an audit trail that can be
-- rewritten is not one. Right for the running system, and it also means a
-- reset cannot clear them without lifting the guard on purpose.
--
-- Put back in [4]. If this script stops part way, check [4] ran.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_audit_append_only DISABLE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only DISABLE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

PROMPT
PROMPT ============================================================
PROMPT [2/5] Clear the target period
PROMPT ============================================================

DECLARE
  v_period NUMBER := oc_time_pkg.get_open_period_id;   -- <- change to clear another
  v_name   VARCHAR2(30);
  v_year   NUMBER;
  v_month  NUMBER;

  PROCEDURE gone(p_what VARCHAR2, p_n NUMBER) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 36) || p_n || ' deleted');
  END;
BEGIN
  SELECT period_name, period_year, period_month
    INTO v_name, v_year, v_month
    FROM oc_time_period WHERE period_id = v_period;

  DBMS_OUTPUT.PUT_LINE('Target period: ' || v_name
                    || '  (period_id ' || v_period || ')');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 52, '-'));

  -- Children of the week, by join. Entries, approvals and audit have no
  -- period of their own -- the week owns it.
  DELETE FROM oc_ts_entry e
   WHERE EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id AND w.period_id = v_period);
  gone('OC_TS_ENTRY', SQL%ROWCOUNT);

  DELETE FROM oc_ts_approval a
   WHERE EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = a.ts_week_id AND w.period_id = v_period);
  gone('OC_TS_APPROVAL', SQL%ROWCOUNT);

  DELETE FROM oc_ts_audit ad
   WHERE EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = ad.ts_week_id AND w.period_id = v_period);
  gone('OC_TS_AUDIT', SQL%ROWCOUNT);

  -- Salary holds: the day rows hang off the hold, so they go first.
  BEGIN
    DELETE FROM oc_ts_salary_hold_day d
     WHERE EXISTS (SELECT 1 FROM oc_ts_salary_hold h
                    WHERE h.salary_hold_id = d.salary_hold_id
                      AND h.period_id = v_period);
    gone('OC_TS_SALARY_HOLD_DAY', SQL%ROWCOUNT);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_SALARY_HOLD_DAY               skipped - '
                      || SUBSTR(SQLERRM, 1, 60));
  END;

  DELETE FROM oc_ts_salary_hold WHERE period_id = v_period;
  gone('OC_TS_SALARY_HOLD', SQL%ROWCOUNT);

  DELETE FROM oc_ts_leave_loss_cover WHERE period_id = v_period;
  gone('OC_TS_LEAVE_LOSS_COVER', SQL%ROWCOUNT);

  DELETE FROM oc_ts_client_doc WHERE period_id = v_period;
  gone('OC_TS_CLIENT_DOC', SQL%ROWCOUNT);

  -- An adjustment is removed by where it POSTS, not where the work happened.
  -- A July correction posting into August materialises its Reversal(-) and
  -- Adjustment(+) in August, so clearing August must take it -- otherwise the
  -- entries are gone and the adjustment still claims to have produced them.
  -- July's own approved rows are untouched: their source period is July and
  -- they posted there.
  DELETE FROM oc_ts_adjustment WHERE post_period_id = v_period;
  gone('OC_TS_ADJUSTMENT (posting here)', SQL%ROWCOUNT);

  -- The interface is keyed on year+month, not period_id -- deliberately, so
  -- the consumer's retention is not hostage to ours.
  DELETE FROM xx_o2c_timesheet_accrual_if
   WHERE period_year = v_year AND period_month = v_month;
  gone('XX_O2C_TIMESHEET_ACCRUAL_IF', SQL%ROWCOUNT);

  DELETE FROM oc_ts_month_confirm WHERE period_id = v_period;
  gone('OC_TS_MONTH_CONFIRM', SQL%ROWCOUNT);

  -- Last: the parent.
  DELETE FROM oc_ts_week WHERE period_id = v_period;
  gone('OC_TS_WEEK', SQL%ROWCOUNT);

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE(v_name || ' is now empty. Every other period is as it was.');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('No open period containing today. Nothing deleted.');
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('ROLLED BACK: ' || SUBSTR(SQLERRM, 1, 200));
END;
/

PROMPT
PROMPT ============================================================
PROMPT [3/5] Put the append-only guards back
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_audit_append_only ENABLE';
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('COULD NOT RE-ENABLE trg_oc_ts_audit_append_only');
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('COULD NOT RE-ENABLE trg_oc_ts_approval_append_only');
END;
/

COLUMN trigger_name FORMAT A34
COLUMN status       FORMAT A10
SELECT trigger_name, status FROM user_triggers
 WHERE trigger_name IN ('TRG_OC_TS_AUDIT_APPEND_ONLY',
                        'TRG_OC_TS_APPROVAL_APPEND_ONLY')
 ORDER BY trigger_name;

PROMPT Both must read ENABLED. DISABLED means the audit trail is editable
PROMPT until you enable it by hand.

PROMPT
PROMPT ============================================================
PROMPT [4/5] Rebuild the month from current Fusion master data
PROMPT ============================================================

DECLARE
  v_job NUMBER;
BEGIN
  v_job := oc_time_pkg.populate_month(
             oc_time_pkg.get_open_period_id, NULL, 'DEMO_RESET');
  DBMS_OUTPUT.PUT_LINE('populate_month job ' || v_job);
END;
/

PROMPT
PROMPT ============================================================
PROMPT [5/5] What the demo will show
PROMPT ============================================================

COLUMN period_name FORMAT A14
SELECT p.period_name, p.status,
       (SELECT COUNT(*) FROM oc_ts_week w WHERE w.period_id = p.period_id) AS weeks,
       (SELECT COUNT(*) FROM oc_ts_entry e
          JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
         WHERE w2.period_id = p.period_id)                                 AS entries,
       (SELECT COUNT(*) FROM oc_ts_approval a
          JOIN oc_ts_week w3 ON w3.ts_week_id = a.ts_week_id
         WHERE w3.period_id = p.period_id)                                 AS approvals
  FROM oc_time_period p
 WHERE EXISTS (SELECT 1 FROM oc_ts_week w4 WHERE w4.period_id = p.period_id)
 ORDER BY p.period_id;

PROMPT
PROMPT July keeps its weeks, entries and approvals. The target month has fresh
PROMPT prepopulated entries and ZERO approvals, ready to walk through
PROMPT submit -> approve.
PROMPT
PROMPT Leave lines now appear only where HCM has an approved absence, carrying
PROMPT IS_LEAVE='Y' and the From HR chip (RULE-008). The '444 / Leave' work row
PROMPT does not return: the default-task rule orders by TASK_CODE, so it picks
PROMPT the first task in the BREAKDOWN rather than whichever row the sync
PROMPT inserted first.

--==============================================================
-- Demo logins — NOT run by default.
--
-- Separate from a period reset, so uncomment deliberately. Removes any user
-- whose password is still Rite@123, which is what 90_test_seed set. Anyone who
-- has since chosen their own password has a different hash and survives, which
-- a hard-coded email list could not guarantee.
--==============================================================
-- DELETE FROM oc_time_session;
-- DELETE FROM oc_time_user u
--  WHERE u.password_hash =
--        (SELECT RAWTOHEX(STANDARD_HASH(LOWER(u.email) || ':Rite@123','SHA256'))
--           FROM dual);
-- COMMIT;
