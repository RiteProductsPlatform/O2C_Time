--==============================================================
-- time/60_reconcile_login_emails.sql
-- O2C Timesheet Module — the login follows the worker record
--
-- The HDL load put work emails into HCM, so OC_TIME_WORKER.EMAIL is now
-- Fusion's answer for all twelve. OC_TIME_USER.EMAIL is a SEPARATE row that
-- nothing syncs, so where the loaded address differs from what db/57 set
-- locally, the two now disagree.
--
-- Measured 17-Aug-2026, one differs:
--   RI2824  worker  sampauljeevan@gmail.com      (loaded into HCM)
--           login   sampaul.jeevan@rite.digital  (db/57's local stand-in)
--
-- Nothing is broken by that -- the old address still signs in, because the
-- login is keyed on OC_TIME_USER.EMAIL and nothing checks it against the
-- worker. It is simply two identities for one person, and the one people will
-- be told is the one in HCM.
--
-- THE PASSWORD HASH DEPENDS ON THE EMAIL, and that is the part worth reading
-- before running this. oc_time_hash_password hashes
--
--     LOWER(email) || ':' || password
--
-- so changing the address invalidates the stored hash. Leaving the hash in
-- place would produce an account that exists, looks Active, and rejects the
-- right password with "incorrect" -- the worst kind of failure to debug.
--
-- So this deliberately sets the affected accounts back to 'Invited' and clears
-- the hash. Re-run 58_demo_passwords.sql afterwards to put the shared demo
-- password back, or have those people set their own via
-- POST /oc/time/auth/set-password. Untouched accounts keep working throughout.
--
-- Idempotent: once the two agree, it finds nothing and changes nothing.
--
-- Depends on: time/11, 56, 57. Run AFTER a WORKERS sync has pulled the new
-- addresses down -- before that, the worker row still holds the local value
-- and there is nothing to reconcile.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_USER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] Where the login and the worker record disagree
PROMPT ============================================================

COLUMN employee_id FORMAT A11
COLUMN login_email FORMAT A34
COLUMN worker_email FORMAT A34
COLUMN verdict FORMAT A24
SELECT u.employee_id,
       LOWER(u.email) AS login_email,
       NVL(LOWER(w.email),'(worker has none)') AS worker_email,
       CASE WHEN w.email IS NULL THEN 'worker blank - skipped'
            WHEN LOWER(u.email) = LOWER(w.email) THEN 'agree'
            ELSE 'WILL BE REPOINTED' END AS verdict
  FROM oc_time_user u
  JOIN oc_time_worker w ON w.employee_id = u.employee_id
 ORDER BY CASE WHEN LOWER(u.email) = LOWER(NVL(w.email,'x')) THEN 1 ELSE 0 END,
          u.employee_id;

PROMPT
PROMPT The administrator has no worker row and never appears here.

PROMPT ============================================================
PROMPT [2/3] Repoint, and invalidate the hash that went with the old address
PROMPT ============================================================

DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR u IN (SELECT u.user_id, u.employee_id,
                   LOWER(u.email) AS old_email,
                   LOWER(w.email) AS new_email
              FROM oc_time_user u
              JOIN oc_time_worker w ON w.employee_id = u.employee_id
             WHERE w.email IS NOT NULL
               AND LOWER(u.email) <> LOWER(w.email))
  LOOP
    BEGIN
      UPDATE oc_time_user
         SET email         = u.new_email,
             -- Cleared, not recomputed. This script does not know anybody's
             -- password and must not invent one; 58 or set-password puts a
             -- working credential back deliberately.
             password_hash = NULL,
             status        = 'Invited',
             failed_count  = 0,
             updated_by    = 'EMAIL_RECONCILE',
             updated_on    = SYSTIMESTAMP
       WHERE user_id = u.user_id;

      -- The old address authenticated these; they cannot outlive it.
      DELETE FROM oc_time_session WHERE user_id = u.user_id;

      v_n := v_n + 1;
      DBMS_OUTPUT.PUT_LINE('repointed ' || RPAD(u.employee_id,9) || ' '
                           || u.old_email || '  ->  ' || u.new_email);
    EXCEPTION WHEN OTHERS THEN
      -- UK_OC_TU_EMAIL is the realistic failure: the address already belongs
      -- to another account. Reported per person rather than rolling back the
      -- whole run, since the others are independent and correct.
      DBMS_OUTPUT.PUT_LINE('FAILED    ' || u.employee_id || ' - '
                           || SUBSTR(SQLERRM,1,120));
    END;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('---');
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Nothing to do - every login already matches its worker.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(v_n || ' account(s) repointed and set back to Invited.');
    DBMS_OUTPUT.PUT_LINE('They have NO password until 58 or set-password runs.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [3/3] Who can sign in, and with what
PROMPT ============================================================

COLUMN email FORMAT A36
COLUMN status FORMAT A9
COLUMN app_role FORMAT A22
SELECT u.email,
       NVL(u.employee_id,'(no worker)') AS employee_id,
       u.status,
       NVL(u.app_role, NVL(w.app_role,'ROLE_TIME_NONE')) AS app_role,
       CASE WHEN u.password_hash IS NULL THEN 'no password yet'
            ELSE 'has a password' END AS credential
  FROM oc_time_user u
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 ORDER BY u.status, u.email;

PROMPT
PROMPT Any row reading 'Invited / no password yet' needs one of:
PROMPT
PROMPT   @@58_demo_passwords.sql              the shared demo password
PROMPT   POST /oc/time/auth/set-password      their own, no current password needed
PROMPT
PROMPT From here the worker record is the single source of the address. A later
PROMPT change in HCM flows to OC_TIME_WORKER on the next sync, and re-running
PROMPT this file carries it to the login.
