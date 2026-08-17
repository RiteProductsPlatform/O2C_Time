--==============================================================
-- time/56_invite_logins.sql
-- O2C Timesheet Module — real sign-in accounts for the test cohort
--
-- 55 removed the twelve seeded logins, which shared one password across twelve
-- real identities. That was right, and it also left nobody but the
-- administrator able to sign in -- and the administrator sees Setup and
-- Operations only (PER-004), so no timesheet screen is reachable at all.
--
-- This creates the same people as REAL accounts through the documented
-- lifecycle instead: status 'Invited', NO password, nothing shared. Each person
-- sets their own at first sign-in:
--
--   POST /oc/time/auth/set-password
--   {"email":"their.address@rite.digital","newPassword":"<at least 8 chars>"}
--
-- An Invited account needs no currentPassword -- that is what invite means --
-- and the call flips it to Active. See ords/14.
--
-- NOT SEED DATA, and the distinction is the point: these are real people from
-- OC_TIME_WORKER, with their own Fusion email and their own password, stamped
-- ADMIN_INVITE so 55 will never treat them as fabricated.
--
-- EMAIL AND NAME ARE READ FROM THE WORKER ROW, never typed here, so the two can
-- never disagree and a typo cannot create an account nobody can reach.
--
-- Idempotent: an existing account is left exactly as it is, Active or Invited.
-- Re-running never resets somebody's password.
--
-- Depends on: time/11 (OC_TIME_USER), a completed WORKERS sync.
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
PROMPT [1/3] The cohort, and whether each one can be invited
PROMPT ============================================================

-- Edit this list to change who gets an account. It is deliberately explicit:
-- inviting every synced worker would create 5,976 accounts.
COLUMN employee_id FORMAT A12
COLUMN employee_name FORMAT A30
COLUMN email FORMAT A34
COLUMN state FORMAT A22
SELECT w.employee_id,
       w.employee_name,
       NVL(w.email,'(none - cannot invite)') AS email,
       CASE WHEN u.user_id IS NOT NULL THEN 'already has an account'
            WHEN w.email IS NULL       THEN 'SKIPPED - no email'
            ELSE 'will be invited' END AS state
  FROM oc_time_worker w
  LEFT JOIN oc_time_user u ON u.employee_id = w.employee_id
 WHERE w.employee_id IN ('RI9001','RI2894','RI2824','RI2900','RI2963','RI2935',
                         'RI3004','RI2914','CRI0406','CRI0398','RI2985','RI2249')
 ORDER BY w.employee_id;

PROMPT ============================================================
PROMPT [2/3] Invite
PROMPT ============================================================

DECLARE
  v_new  NUMBER := 0;
  v_had  NUMBER := 0;
  v_skip NUMBER := 0;
BEGIN
  FOR w IN (SELECT w.employee_id, w.employee_name, LOWER(w.email) AS email
              FROM oc_time_worker w
             WHERE w.employee_id IN ('RI9001','RI2894','RI2824','RI2900',
                                     'RI2963','RI2935','RI3004','RI2914',
                                     'CRI0406','CRI0398','RI2985','RI2249'))
  LOOP
    IF w.email IS NULL THEN
      v_skip := v_skip + 1;
      DBMS_OUTPUT.PUT_LINE('skipped ' || w.employee_id || ' - no email on the worker row');
    ELSE
      BEGIN
        -- No MERGE, and no UPDATE branch at all. An account that already exists
        -- is somebody's live credential; silently rewriting it would log them
        -- out and blank a password they had set.
        INSERT INTO oc_time_user (employee_id, email, full_name, app_role,
                                  password_hash, status, created_by)
        -- APP_ROLE null on purpose: the role comes from OC_TIME_WORKER
        -- (CLAUDE.md section 4). The override column exists for the common
        -- administrator and for nobody else.
        SELECT w.employee_id, w.email, w.employee_name, NULL,
               NULL, 'Invited', 'ADMIN_INVITE'
          FROM dual
         WHERE NOT EXISTS (SELECT 1 FROM oc_time_user u
                            WHERE u.employee_id = w.employee_id
                               OR LOWER(u.email) = w.email);
        IF SQL%ROWCOUNT = 1 THEN
          v_new := v_new + 1;
          DBMS_OUTPUT.PUT_LINE('invited ' || RPAD(w.employee_id,9) || ' ' || w.email);
        ELSE
          v_had := v_had + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED  ' || w.employee_id || ' - '
                             || SUBSTR(SQLERRM,1,120));
      END;
    END IF;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('invited ' || v_new || ', already had an account ' || v_had
                       || ', skipped ' || v_skip);
END;
/

PROMPT ============================================================
PROMPT [3/3] Who can sign in now
PROMPT ============================================================

COLUMN app_role FORMAT A22
COLUMN status FORMAT A10
SELECT u.employee_id, u.email, u.status,
       NVL(u.app_role, NVL(w.app_role,'ROLE_TIME_NONE')) AS app_role,
       u.created_by
  FROM oc_time_user u
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 ORDER BY CASE WHEN u.employee_id IS NULL THEN 0 ELSE 1 END, u.employee_id;

PROMPT
PROMPT Status 'Invited' means the account exists with NO password. Set one:
PROMPT
PROMPT   POST /oc/time/auth/set-password
PROMPT   {"email":"<their email>","newPassword":"<8+ characters>"}
PROMPT
PROMPT That call flips the account to Active and signs them in from then on.
PROMPT APP_ROLE above is the RESOLVED role -- the worker's, unless the user row
PROMPT overrides it, which only the administrator does.
