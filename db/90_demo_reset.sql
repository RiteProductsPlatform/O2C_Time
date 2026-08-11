--==============================================================
-- time/90_demo_reset.sql
-- O2C Timesheet Module — clear the transactional data for a walkthrough
--
-- DESTRUCTIVE. Read the scope before running it.
--
-- WHAT IT REMOVES
--   every timesheet transaction: weeks, entries, approvals, the audit trail,
--   adjustments, month confirmations, the accrual interface, salary holds,
--   client documents, leave-loss cover, the sync change queue and job history
--   plus the demo logins -- see [3] for exactly which
--
-- WHAT IT KEEPS
--   ALL master data: OC_TIME_WORKER, OC_TIME_PROJECT, OC_TIME_TASK,
--   OC_TIME_ALLOCATION, OC_TIME_ABSENCE, OC_TIME_CALENDAR. Those come from
--   Fusion and re-syncing them is slower than keeping them.
--
--   ALL reference and seed data: periods, cut-offs, lookups, the sync config,
--   PRJ-ORG and the COMMON tasks (Leave, Training, Travel). These are design,
--   not test data -- FLD-006 makes the Organization project implicitly
--   everyone's, and the COMMON Leave task is where HCM absence lands. Removing
--   them would leave absence prepopulation with no task to write to.
--
-- WHY THE '444 / Leave' ROW EXISTS, since that is what prompted this
--
--   It is NOT absence. Absence rows carry IS_LEAVE='Y' and show the From HR
--   chip; that row has neither. Project 444 has a WBS task named Leave in
--   Fusion, and populate_month's default-task rule used to order by TASK_ID --
--   the identity column -- so "the first chargeable task" meant "whichever row
--   the sync happened to insert first". On 444 that was Leave.
--
--   The rule now orders by TASK_CODE, so a fresh population picks the real
--   first task in the breakdown. The stale rows are what this script removes;
--   re-populating afterwards is what makes the screen correct.
--
-- Idempotent. Safe to run twice. Depends on: time/03..07, time/15, time/19
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT ============================================================
PROMPT [1/5] What is there now
PROMPT ============================================================

DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(40);
  v t_tab := t_tab(
    'OC_TS_ENTRY','OC_TS_WEEK','OC_TS_APPROVAL','OC_TS_AUDIT',
    'OC_TS_ADJUSTMENT','OC_TS_MONTH_CONFIRM','XX_O2C_TIMESHEET_ACCRUAL_IF',
    'OC_TS_SALARY_HOLD','OC_TS_SALARY_HOLD_DAY','OC_TS_CLIENT_DOC',
    'OC_TS_LEAVE_LOSS_COVER','OC_TIME_SYNC_CHANGE','OC_TIME_SYNC_FAILED',
    'OC_TIME_SYNC_JOB','OC_TIME_SESSION','OC_TIME_USER',
    'OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK','OC_TIME_ALLOCATION',
    'OC_TIME_ABSENCE','OC_TIME_CALENDAR');
  v_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('TABLE', 34) || 'ROWS');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 44, '-'));
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v(i) INTO v_n;
      DBMS_OUTPUT.PUT_LINE(RPAD(v(i), 34) || v_n ||
        CASE WHEN i > 16 THEN '   (KEPT)' ELSE '' END);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(v(i), 34) || '(absent)');
    END;
  END LOOP;
END;
/

PROMPT
PROMPT ============================================================
PROMPT [2/5] Transactional data
PROMPT ============================================================

-- THE APPEND-ONLY TRIGGERS HAVE TO COME OFF FIRST.
--
-- 19_sync_change_capture.sql made OC_TS_AUDIT and OC_TS_APPROVAL append-only,
-- refusing UPDATE and DELETE with -20026, because an audit trail that can be
-- rewritten is not one. That is right for the running system and it also means
-- a reset cannot clear them without lifting the guard deliberately.
--
-- Disabled, deleted, RE-ENABLED in [4]. If this script fails part way, check
-- [4] ran -- leaving them disabled silently removes the protection.
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

DECLARE
  -- Child before parent. Most of these cascade from OC_TS_WEEK, but naming
  -- them explicitly means the script says what it removes rather than relying
  -- on a constraint definition to be read.
  TYPE t_tab IS TABLE OF VARCHAR2(40);
  v t_tab := t_tab(
    'OC_TS_ENTRY', 'OC_TS_APPROVAL', 'OC_TS_AUDIT',
    'OC_TS_SALARY_HOLD_DAY', 'OC_TS_SALARY_HOLD',
    'OC_TS_LEAVE_LOSS_COVER', 'OC_TS_CLIENT_DOC',
    'OC_TS_ADJUSTMENT', 'XX_O2C_TIMESHEET_ACCRUAL_IF',
    'OC_TS_MONTH_CONFIRM', 'OC_TS_WEEK',
    'OC_TIME_SYNC_CHANGE', 'OC_TIME_SYNC_FAILED', 'OC_TIME_SYNC_JOB');
  v_n NUMBER;
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DELETE FROM ' || v(i);
      v_n := SQL%ROWCOUNT;
      DBMS_OUTPUT.PUT_LINE(RPAD(v(i), 34) || v_n || ' deleted');
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(RPAD(v(i), 34) || 'SKIPPED - ' ||
                           SUBSTR(SQLERRM, 1, 80));
    END;
  END LOOP;
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT [3/5] Demo logins
PROMPT ============================================================

-- KEYED ON THE PASSWORD, not on a name list.
--
-- A user is a demo user if their password is still Rite@123 -- which is what
-- 90_test_seed.sql set for admin@rite.digital and every seeded worker. Anyone
-- who has since set their own password has a different hash and SURVIVES,
-- which a hard-coded email list could not guarantee.
--
-- The hash is per-user because the salt is the email: SHA-256 over
-- LOWER(email) || ':' || password. STANDARD_HASH is SQL-only (PLS-00201 in a
-- PL/SQL expression), so it is reached through a scalar subquery on dual.
DECLARE
  v_n NUMBER;
BEGIN
  DELETE FROM oc_time_session;
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SESSION                  ' || SQL%ROWCOUNT
                    || ' deleted (all sessions invalid after a reset anyway)');

  DELETE FROM oc_time_user u
   WHERE u.password_hash =
         (SELECT RAWTOHEX(STANDARD_HASH(LOWER(u.email) || ':Rite@123', 'SHA256'))
            FROM dual);
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('OC_TIME_USER                     ' || v_n
                    || ' demo login(s) deleted');
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('Users still on the demo password are gone. Anyone who '
                    || 'set their own password kept it.');
END;
/

PROMPT
PROMPT ============================================================
PROMPT [4/5] Put the append-only guards back
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_audit_append_only ENABLE';
  DBMS_OUTPUT.PUT_LINE('trg_oc_ts_audit_append_only ENABLED');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('COULD NOT RE-ENABLE trg_oc_ts_audit_append_only - '
                    || SUBSTR(SQLERRM, 1, 90));
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
  DBMS_OUTPUT.PUT_LINE('trg_oc_ts_approval_append_only ENABLED');
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('COULD NOT RE-ENABLE trg_oc_ts_approval_append_only - '
                    || SUBSTR(SQLERRM, 1, 90));
END;
/

COLUMN trigger_name FORMAT A34
COLUMN status       FORMAT A10
SELECT trigger_name, status FROM user_triggers
 WHERE trigger_name IN ('TRG_OC_TS_AUDIT_APPEND_ONLY',
                        'TRG_OC_TS_APPROVAL_APPEND_ONLY')
 ORDER BY trigger_name;

PROMPT Both must read ENABLED. If either says DISABLED the audit trail is
PROMPT editable until you enable it by hand.

PROMPT
PROMPT ============================================================
PROMPT [5/5] What is left
PROMPT ============================================================

DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(40);
  v t_tab := t_tab('OC_TS_WEEK','OC_TS_ENTRY','OC_TIME_SYNC_CHANGE',
                   'OC_TIME_USER',
                   'OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                   'OC_TIME_ALLOCATION','OC_TIME_ABSENCE','OC_TIME_CALENDAR');
  v_n NUMBER;
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v(i) INTO v_n;
    DBMS_OUTPUT.PUT_LINE(RPAD(v(i), 34) || v_n);
  END LOOP;
END;
/

PROMPT
PROMPT ============================================================
PROMPT NEXT: rebuild the month from current Fusion master data
PROMPT ============================================================
PROMPT
PROMPT   DECLARE v_job NUMBER;
PROMPT   BEGIN
PROMPT     v_job := oc_time_pkg.populate_month(
PROMPT                oc_time_pkg.get_open_period_id, NULL, 'DEMO_RESET');
PROMPT     DBMS_OUTPUT.PUT_LINE('job ' || v_job);
PROMPT   END;
PROMPT   /
PROMPT
PROMPT Nothing is populated until that runs -- the reset only clears.
PROMPT
PROMPT The Leave line on 444 will not come back: the default-task rule now
PROMPT orders by TASK_CODE, so it picks the first task in the BREAKDOWN rather
PROMPT than whichever row the sync inserted first. Leave rows will appear only
PROMPT where HCM has an approved absence, carrying IS_LEAVE='Y' and the From HR
PROMPT chip -- which is RULE-008.
