--==============================================================
-- time/ords/14_ords_time_auth.sql
-- O2C Timesheet Module — ORDS module oc.time.auth  (SIGN-IN surface)
--
-- Base path: /oc/time/auth/
-- Mirrors the O2C main application's oc_auth contract so the two apps behave
-- the same way and a user meets one login model, not two.
--
-- Endpoints
--   POST login          email + password        -> token, role, employee
--   POST logout         token                   -> ends the session
--   GET  session/:token validate + who am I     -> the resolved identity
--   POST set-password   first-time / reset      -> Invited becomes Active
--
-- Three access levels come out of EFFECTIVE_ROLE in V_OC_TIME_SIGNIN:
--   resource  ROLE_TIME_EMPLOYEE | ROLE_TIME_CONTRACTOR
--   manager   ROLE_TIME_MANAGER
--   admin     ROLE_TIME_ADMIN
--
-- Responses are emitted with HTP.P, never APEX_JSON - APEX is not installed on
-- every target schema and referencing it makes ORDS reject the handler with 403.
--
-- Depends on: time/11_auth.sql
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

BEGIN ORDS.DELETE_MODULE(p_module_name => 'oc.time.auth'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time.auth',
    p_base_path      => '/oc/time/auth/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'O2C Timesheet - sign-in (login, logout, session, set-password).');
  COMMIT;
END;
/

-- ── POST login ───────────────────────────────────────────────
-- Deliberately returns the SAME message for an unknown email and a wrong
-- password. Distinguishing them tells an attacker which addresses are real.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'login');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'login', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        v_email VARCHAR2(255) := LOWER(:email);
        v_uid   NUMBER;
        v_hash  VARCHAR2(128);
        v_stat  VARCHAR2(20);
        v_fail  NUMBER;
        v_tok   VARCHAR2(64);
        v_role  VARCHAR2(30);
        v_emp   VARCHAR2(50);
        v_name  VARCHAR2(200);
      BEGIN
        -- application/json, or callRest leaves the body a STRING. HTP.P
        -- sets no content type; without this every count read off this
        -- response is undefined and every message built from one is wrong.
        OWA_UTIL.mime_header('application/json', TRUE);
        IF v_email IS NULL OR :password IS NULL THEN
          :status_code := 400;
          HTP.P('{"error":"Email and password are required."}');
          RETURN;
        END IF;

        BEGIN
          SELECT user_id, password_hash, status, failed_count
            INTO v_uid, v_hash, v_stat, v_fail
            FROM oc_time_user WHERE LOWER(email) = v_email;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          :status_code := 401;
          HTP.P('{"error":"Invalid email or password."}');
          RETURN;
        END;

        IF v_stat = 'Invited' THEN
          :status_code := 403;
          HTP.P('{"error":"Set your password before signing in.","status":"Invited"}');
          RETURN;
        ELSIF v_stat <> 'Active' THEN
          :status_code := 403;
          HTP.P('{"error":"This account is inactive. Contact your administrator."}');
          RETURN;
        END IF;

        -- Ten consecutive failures locks the account. Deliberately a hard lock
        -- needing an administrator, not a timed one: this is an internal tool
        -- with a known user list, so a lockout is a signal worth looking at.
        IF v_fail >= 10 THEN
          :status_code := 403;
          HTP.P('{"error":"Account locked after repeated failed sign-ins. Contact your administrator."}');
          RETURN;
        END IF;

        IF v_hash IS NULL OR v_hash <> oc_time_hash_password(v_email, :password) THEN
          UPDATE oc_time_user
             SET failed_count = failed_count + 1, updated_on = SYSTIMESTAMP
           WHERE user_id = v_uid;
          COMMIT;
          :status_code := 401;
          HTP.P('{"error":"Invalid email or password."}');
          RETURN;
        END IF;

        -- Via the function, not inline, so the token recipe lives in exactly
        -- one place — and so restoring DBMS_CRYPTO.RANDOMBYTES later is a
        -- one-line change there rather than a hunt through the handlers.
        -- See the security note on oc_time_new_token in 11_auth.sql.
        v_tok := oc_time_new_token;

        -- Clear this user's expired rows on the way through, so the table is
        -- self-maintaining without a scheduled job.
        DELETE FROM oc_time_session
         WHERE user_id = v_uid AND expires_on < SYSTIMESTAMP;

        INSERT INTO oc_time_session (user_id, token, expires_on, last_seen_on, client_info)
        VALUES (v_uid, v_tok, SYSTIMESTAMP + INTERVAL '24' HOUR, SYSTIMESTAMP,
                SUBSTR(:client_info,1,400));

        UPDATE oc_time_user
           SET failed_count = 0, last_login_on = SYSTIMESTAMP, updated_on = SYSTIMESTAMP
         WHERE user_id = v_uid;
        COMMIT;

        SELECT effective_role, employee_id, employee_name
          INTO v_role, v_emp, v_name
          FROM v_oc_time_signin WHERE token = v_tok;

        :status_code := 200;
        HTP.P('{"token":"'        || v_tok  ||
              '","userId":'       || v_uid  ||
              ',"employeeId":"'   || NVL(v_emp,'')  ||
              '","employeeName":"'|| REPLACE(NVL(v_name,''),'"','\"') ||
              '","role":"'        || v_role ||
              '","expiresInHours":24}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── GET session/:token ───────────────────────────────────────
-- Who am I. The shell calls this on every load so a refresh does not require
-- re-entering credentials, and so a revoked or expired token stops working
-- immediately rather than at the next write.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'session/:token');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'session/:token',
    p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'~
      SELECT user_id, employee_id, employee_name, email, effective_role AS app_role,
             worker_type, manager_emp_id, base_country, deputed_country,
             std_hours_per_day, total_alloc_pct, open_period_id,
             TO_CHAR(expires_on,'YYYY-MM-DD HH24:MI:SS') AS expires_on
        FROM v_oc_time_signin
       WHERE token = :token
    ~');
  COMMIT;
END;
/

-- ── POST logout ──────────────────────────────────────────────
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'logout');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'logout', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      BEGIN
        -- application/json, or callRest leaves the body a STRING. HTP.P
        -- sets no content type; without this every count read off this
        -- response is undefined and every message built from one is wrong.
        OWA_UTIL.mime_header('application/json', TRUE);
        DELETE FROM oc_time_session WHERE token = :token;
        COMMIT;
        -- 200 whether or not the token existed: an already-dead session is a
        -- successful logout from the caller's point of view.
        :status_code := 200;
        HTP.P('{"loggedOut":true}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
END;
/

-- ── POST set-password ────────────────────────────────────────
-- First-time setup and self-service change. An Invited user supplies no current
-- password; an Active one must.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.auth', p_pattern => 'set-password');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.auth', p_pattern => 'set-password', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source => q'~
      DECLARE
        v_email VARCHAR2(255) := LOWER(:email);
        v_uid   NUMBER;
        v_hash  VARCHAR2(128);
        v_stat  VARCHAR2(20);
      BEGIN
        -- application/json, or callRest leaves the body a STRING. HTP.P
        -- sets no content type; without this every count read off this
        -- response is undefined and every message built from one is wrong.
        OWA_UTIL.mime_header('application/json', TRUE);
        IF :newPassword IS NULL OR LENGTH(:newPassword) < 8 THEN
          :status_code := 400;
          HTP.P('{"error":"The new password must be at least 8 characters."}');
          RETURN;
        END IF;

        BEGIN
          SELECT user_id, password_hash, status INTO v_uid, v_hash, v_stat
            FROM oc_time_user WHERE LOWER(email) = v_email;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          :status_code := 404;
          HTP.P('{"error":"No account for that email."}');
          RETURN;
        END;

        IF v_stat = 'Inactive' THEN
          :status_code := 403;
          HTP.P('{"error":"This account is inactive. Contact your administrator."}');
          RETURN;
        END IF;

        -- Changing a live password requires proving you know the current one.
        -- An Invited account has none yet, which is the whole point of invite.
        IF v_stat = 'Active' THEN
          IF :currentPassword IS NULL
             OR v_hash <> oc_time_hash_password(v_email, :currentPassword) THEN
            :status_code := 401;
            HTP.P('{"error":"The current password is not correct."}');
            RETURN;
          END IF;
        END IF;

        UPDATE oc_time_user
           SET password_hash = oc_time_hash_password(v_email, :newPassword),
               status        = 'Active',
               failed_count  = 0,
               updated_by    = NVL(:actor, v_email),
               updated_on    = SYSTIMESTAMP
         WHERE user_id = v_uid;

        -- Every existing session dies on a password change, so a stolen token
        -- cannot outlive the credential it came from.
        DELETE FROM oc_time_session WHERE user_id = v_uid;
        COMMIT;

        :status_code := 200;
        HTP.P('{"userId":' || v_uid || ',"status":"Active"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK; :status_code := 500;
        HTP.P('{"error":"' ||
              REPLACE(REPLACE(SQLERRM,'ORA-'||LTRIM(TO_CHAR(ABS(SQLCODE)))||': ',''),'"','\"')
              || '"}');
      END;
    ~');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT ORDS module oc.time.auth defined.
PROMPT ============================================================
