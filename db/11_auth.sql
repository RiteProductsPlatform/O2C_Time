--==============================================================
-- time/11_auth.sql
-- O2C Timesheet Module — application sign-in
--
-- Matches the O2C main application's auth model so the two behave identically
-- and credentials can be aligned later: same SHA-256 over
-- LOWER(email) || ':' || password, same 64-hex random session token, same
-- Invited / Active / Inactive lifecycle.
--
-- Three access levels, as specified:
--   resource   ROLE_TIME_EMPLOYEE | ROLE_TIME_CONTRACTOR
--   manager    ROLE_TIME_MANAGER
--   admin      ROLE_TIME_ADMIN            (the common admin login)
--
-- The role is NOT duplicated here. It is read from OC_TIME_WORKER.APP_ROLE,
-- which already drives the menu (RULE-022) and carries the manager hierarchy
-- (RULE-015). Two copies of a role would eventually disagree, and the one the
-- approval rules read is the worker's.
--
-- APP_ROLE on OC_TIME_USER is an OVERRIDE, normally null. It exists for the
-- common admin, who is a real login but not necessarily a worker in HCM and so
-- may have no OC_TIME_WORKER row to take a role from.
--
-- PREREQUISITE — as a privileged user, once:
--     GRANT EXECUTE ON DBMS_CRYPTO TO O2C_TIME;
-- Without it oc_time_hash_password will not compile and nobody can sign in.
--
-- Requirement refs: PER-001..005, RULE-022, NFR-005, Security sheet (JWT/RBAC)
-- Idempotent. Depends on: time/02_time_master.sql
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/5] Pre-flight — DBMS_CRYPTO must be executable
PROMPT ============================================================

DECLARE
  v_n PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_n
    FROM all_objects
   WHERE owner = 'SYS' AND object_name = 'DBMS_CRYPTO';

  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20900,
      CHR(10) || 'DBMS_CRYPTO is not visible to ' || USER || '.' || CHR(10) ||
      'Run as a privileged user, then re-run this script:' || CHR(10) ||
      '  GRANT EXECUTE ON DBMS_CRYPTO TO ' || USER || ';');
  END IF;
  DBMS_OUTPUT.PUT_LINE('DBMS_CRYPTO visible.');
END;
/

PROMPT ============================================================
PROMPT [2/5] OC_TIME_USER — one login per person
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_user (
      USER_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      EMPLOYEE_ID    VARCHAR2(50 CHAR),
      EMAIL          VARCHAR2(255 CHAR) NOT NULL,
      PASSWORD_HASH  VARCHAR2(128 CHAR),
      FULL_NAME      VARCHAR2(200 CHAR) NOT NULL,
      APP_ROLE       VARCHAR2(30 CHAR),
      STATUS         VARCHAR2(20 CHAR) DEFAULT 'Invited' NOT NULL,
      LAST_LOGIN_ON  TIMESTAMP,
      FAILED_COUNT   NUMBER(3) DEFAULT 0 NOT NULL,
      CREATED_BY     VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY     VARCHAR2(100),
      UPDATED_ON     TIMESTAMP,
      CONSTRAINT uk_oc_tu_email  UNIQUE (email),
      CONSTRAINT uk_oc_tu_emp    UNIQUE (employee_id),
      CONSTRAINT chk_oc_tu_status CHECK (status IN ('Invited','Active','Inactive')),
      CONSTRAINT chk_oc_tu_role  CHECK (app_role IS NULL OR app_role IN
        ('ROLE_TIME_EMPLOYEE','ROLE_TIME_CONTRACTOR','ROLE_TIME_MANAGER',
         'ROLE_TIME_ADMIN','ROLE_TIME_NONE')),
      -- An Active account with no hash could never authenticate, so the state is
      -- made unrepresentable rather than left to fail at the login attempt.
      CONSTRAINT chk_oc_tu_hash  CHECK (status <> 'Active' OR password_hash IS NOT NULL)
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_USER created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_USER already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tu_status ON oc_time_user(status)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [3/5] OC_TIME_SESSION — bearer tokens
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_session (
      SESSION_ID   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      USER_ID      NUMBER            NOT NULL,
      TOKEN        VARCHAR2(64 CHAR) NOT NULL,
      CREATED_ON   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      EXPIRES_ON   TIMESTAMP         NOT NULL,
      LAST_SEEN_ON TIMESTAMP,
      CLIENT_INFO  VARCHAR2(400 CHAR),
      CONSTRAINT uk_oc_tsess_token UNIQUE (token),
      CONSTRAINT fk_oc_tsess_user  FOREIGN KEY (user_id)
        REFERENCES oc_time_user(user_id) ON DELETE CASCADE
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SESSION created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SESSION already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

BEGIN EXECUTE IMMEDIATE
  'CREATE INDEX ix_oc_tsess_expiry ON oc_time_session(expires_on)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF; END;
/

PROMPT ============================================================
PROMPT [4/5] OC_TIME_HASH_PASSWORD
PROMPT ============================================================

-- Deliberately identical to the main application's oc_hash_password: SHA-256
-- over LOWER(email) || ':' || password. The email is the salt, so two people
-- with the same password do not share a hash, and a hash lifted from one row is
-- useless against another.
--
-- Same algorithm as the main app on purpose - if the two user stores are ever
-- merged, the hashes are directly comparable and nobody has to reset a password.
CREATE OR REPLACE FUNCTION oc_time_hash_password(
  p_email    VARCHAR2,
  p_password VARCHAR2
) RETURN VARCHAR2
IS
BEGIN
  RETURN RAWTOHEX(
    DBMS_CRYPTO.HASH(
      UTL_RAW.CAST_TO_RAW(LOWER(p_email) || ':' || p_password),
      DBMS_CRYPTO.HASH_SH256));
END oc_time_hash_password;
/

PROMPT ============================================================
PROMPT [5/5] V_OC_TIME_SIGNIN — the resolved identity
PROMPT ============================================================

-- What a valid token resolves to. One place decides the effective role, so the
-- login response, the menu and every RBAC check cannot drift apart.
--
-- EFFECTIVE_ROLE: the user override if present (the common admin, who may have
-- no worker row), otherwise the worker's APP_ROLE, otherwise no access. A login
-- that resolves to nothing is ROLE_TIME_NONE rather than an error - the shell
-- already renders an empty menu with an explanation for that.
CREATE OR REPLACE VIEW v_oc_time_signin AS
SELECT s.token,
       s.expires_on,
       u.user_id,
       u.status                            AS user_status,
       NVL(u.employee_id, w.employee_id)   AS employee_id,
       NVL(w.employee_name, u.full_name)   AS employee_name,
       u.email,
       NVL(u.app_role, NVL(w.app_role, 'ROLE_TIME_NONE')) AS effective_role,
       w.worker_type,
       w.manager_emp_id,
       w.base_country,
       w.deputed_country,
       w.std_hours_per_day,
       w.status                            AS worker_status,
       (SELECT NVL(SUM(al.alloc_pct),0)
          FROM oc_time_allocation al
         WHERE al.employee_id = NVL(u.employee_id, w.employee_id)
           AND al.status = 'Active')       AS total_alloc_pct,
       -- NOT oc_time_pkg.get_open_period_id: that raises when nothing is Open,
       -- and sign-in must never depend on a period existing.
       (SELECT p.period_id FROM oc_time_period p
         WHERE p.status = 'Open' AND ROWNUM = 1) AS open_period_id
  FROM oc_time_session s
  JOIN oc_time_user    u ON u.user_id = s.user_id
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 WHERE s.expires_on > SYSTIMESTAMP
   AND u.status = 'Active';

PROMPT
PROMPT ============================================================
PROMPT time/11_auth complete.
PROMPT ============================================================
