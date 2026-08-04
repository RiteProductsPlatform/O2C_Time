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
-- NO GRANTS BEYOND THE ORDINARY ONES. Nothing here needs DBMS_CRYPTO — see the
-- note on oc_time_hash_password and oc_time_new_token below, and §  SECURITY
-- DEBT at the foot of this file. That was a deliberate decision on
-- 01-Aug-2026 to avoid a DBA round trip; the hash side costs nothing, the token
-- side is weaker and is written down as debt rather than hidden.
--
-- Requirement refs: PER-001..005, RULE-022, NFR-005, Security sheet (JWT/RBAC)
-- Idempotent. Depends on: time/02_time_master.sql
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/5] OC_TIME_USER — one login per person
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
PROMPT [2/5] OC_TIME_SESSION — bearer tokens
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
PROMPT [3/5] OC_TIME_HASH_PASSWORD
PROMPT ============================================================

-- Deliberately identical to the main application's oc_hash_password: SHA-256
-- over LOWER(email) || ':' || password. The email is the salt, so two people
-- with the same password do not share a hash, and a hash lifted from one row is
-- useless against another.
--
-- Same algorithm as the main app on purpose - if the two user stores are ever
-- merged, the hashes are directly comparable and nobody has to reset a password.
--
-- STANDARD_HASH, not DBMS_CRYPTO.HASH. This is a pure substitution, not a
-- compromise: both hash the same bytes with the same algorithm and return the
-- same 64 hex characters, so a hash written by either function verifies against
-- the other and the main app's stored hashes still compare directly. The only
-- difference is that STANDARD_HASH is a SQL built-in needing no grant, while
-- DBMS_CRYPTO is a SYS package that is not granted to PUBLIC.
--
--   RAWTOHEX(DBMS_CRYPTO.HASH(UTL_RAW.CAST_TO_RAW(s), DBMS_CRYPTO.HASH_SH256))
--   = RAWTOHEX(STANDARD_HASH(s, 'SHA256'))
--
-- Deterministic, so it is fine in the SQL of a MERGE (90_test_seed.sql does
-- exactly that) without a DETERMINISTIC hint being load-bearing.
--
-- STANDARD_HASH is a SQL function, NOT a PL/SQL one, so it cannot appear in a
-- PL/SQL expression — `RETURN RAWTOHEX(STANDARD_HASH(...))` fails to compile
-- with PLS-00201 "identifier must be declared". It has to be reached through a
-- SQL statement, hence SELECT ... INTO ... FROM dual. Same family as SQLERRM
-- (SQL-only in reverse) and EXISTS.
CREATE OR REPLACE FUNCTION oc_time_hash_password(
  p_email    VARCHAR2,
  p_password VARCHAR2
) RETURN VARCHAR2 DETERMINISTIC
IS
  v_hash VARCHAR2(128 CHAR);
BEGIN
  SELECT RAWTOHEX(
           STANDARD_HASH(LOWER(p_email) || ':' || p_password, 'SHA256'))
    INTO v_hash
    FROM dual;
  RETURN v_hash;
END oc_time_hash_password;
/

PROMPT ============================================================
PROMPT [4/5] OC_TIME_NEW_TOKEN — session token generator
PROMPT ============================================================

-- Returns a 64-character hex session token, the same shape the main
-- application's oc_auth issues, so nothing downstream changes.
--
-- ─────────────────────────────────────────────────────────────
-- THIS IS THE WEAK PART. Read before changing anything here.
-- ─────────────────────────────────────────────────────────────
--
-- The right way to make a bearer token is DBMS_CRYPTO.RANDOMBYTES(32) — a
-- cryptographically secure generator, 256 bits of real entropy. It is not used
-- because DBMS_CRYPTO needs a grant we chose not to ask for (01-Aug-2026).
--
-- What is here instead mixes the unpredictability that IS available without a
-- grant, then hashes it so the output is uniform and the inputs cannot be read
-- back off the token:
--
--   SYS_GUID()        unique, but on many platforms partly derived from host,
--                     process and time — so not unpredictable on its own
--   DBMS_RANDOM       a PRNG, not a CSPRNG; seeded from time and session
--   SYSTIMESTAMP      nanosecond precision, but an attacker can guess the
--                     rough window a session was created in
--
-- Hashing does NOT add entropy. It only spreads what the inputs have across all
-- 256 bits and hides their structure. So a determined attacker who knows
-- roughly when a session began has a smaller search space than 2^256. In
-- practice guessing a live token is still very hard; cryptographically, it is
-- not a guarantee.
--
-- What limits the damage meanwhile: tokens expire in 24 hours, are deleted on
-- logout and on any password change, and every session row is per-user, so a
-- guessed token buys one person's timesheet for less than a day.
--
-- TO PUT THIS RIGHT — one line, once the grant exists:
--
--   GRANT EXECUTE ON DBMS_CRYPTO TO O2C_TIME;
--
--   RETURN RAWTOHEX(DBMS_CRYPTO.RANDOMBYTES(32));
--
-- Existing sessions keep working; the column and the length do not change.
-- Do this before PROD (NFR-005, Security sheet).
-- As with oc_time_hash_password: STANDARD_HASH is SQL-only, so it is reached
-- through SELECT ... FROM dual rather than called directly.
CREATE OR REPLACE FUNCTION oc_time_new_token RETURN VARCHAR2
IS
  v_seed  VARCHAR2(400 CHAR);
  v_token VARCHAR2(64 CHAR);
BEGIN
  v_seed := RAWTOHEX(SYS_GUID())
         || RAWTOHEX(SYS_GUID())
         || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF9')
         || DBMS_RANDOM.STRING('X', 32);

  SELECT RAWTOHEX(STANDARD_HASH(v_seed, 'SHA256'))
    INTO v_token
    FROM dual;
  RETURN v_token;
END oc_time_new_token;
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
       (SELECT period_id FROM (
         SELECT p.period_id
           FROM oc_time_period p
          WHERE p.status = 'Open'
          ORDER BY CASE WHEN TRUNC(SYSDATE)
             BETWEEN p.start_date AND p.end_date
                THEN 0 ELSE 1 END, p.start_date)
        WHERE ROWNUM = 1) AS open_period_id
  FROM oc_time_session s
  JOIN oc_time_user    u ON u.user_id = s.user_id
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 WHERE s.expires_on > SYSTIMESTAMP
   AND u.status = 'Active';

PROMPT
PROMPT ============================================================
PROMPT time/11_auth complete.
PROMPT ============================================================
