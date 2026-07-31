--==============================================================
-- install_time.sql
-- O2C Timesheet Module — full install, in dependency order
--
-- Run from THIS directory as the O2C Time schema owner:
--     sqlplus o2c_time/<pwd>@<tns> @install_time.sql
--
-- Every script is idempotent, so re-running the installer is safe and is the
-- normal way to apply changes. Nothing is dropped.
--
-- ── Prerequisites, all run as ADMIN (not as O2C_TIME) ────────
--
-- 1. Privileges. RESOURCE does NOT include CREATE VIEW, and this module builds
--    24 of them — without the explicit grant the install dies at 01 step [7/8]
--    with ORA-01031 after the tables have already succeeded.
--
--    DBMS_CRYPTO is separate again: EXECUTE on it is not implied by anything,
--    and without it 11_auth.sql stops on its own pre-flight because the
--    password hash function cannot compile and nobody could sign in.
--
--     GRANT CONNECT, RESOURCE TO O2C_TIME;
--     GRANT CREATE VIEW       TO O2C_TIME;
--     GRANT EXECUTE ON DBMS_CRYPTO TO O2C_TIME;
--     ALTER USER O2C_TIME QUOTA UNLIMITED ON DATA;   -- ADB tablespace is DATA
--
-- 2. REST-enable the schema, or the ORDS modules in 12..15 cannot publish and
--    every endpoint 404s. On Autonomous Database use ORDS_ADMIN as ADMIN —
--    the classic ORDS.ENABLE_SCHEMA cannot enable a schema other than the
--    caller's own unless the caller holds ORDS_ADMINISTRATOR_ROLE, which is
--    why it raises ORA-01031 there.
--
--     BEGIN
--       ORDS_ADMIN.ENABLE_SCHEMA(p_enabled => TRUE,
--                                p_schema  => 'O2C_TIME',
--                                p_url_mapping_type    => 'BASE_PATH',
--                                p_url_mapping_pattern => 'o2c_time',
--                                p_auto_rest_auth      => FALSE);
--       COMMIT;
--     END;
--     /
--
--    On a non-Autonomous ORDS install the equivalent is ORDS.ENABLE_SCHEMA,
--    run either as the schema owner or by a caller with ORDS_ADMINISTRATOR_ROLE.
--
-- RA-002: p_auto_rest_auth FALSE plus anonymous access is acceptable in lower
-- environments only. Harden to https + API key / OAuth2 before PROD.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET FEEDBACK ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT
PROMPT ##############################################################
PROMPT #  O2C TIMESHEET MODULE - INSTALL
PROMPT ##############################################################
PROMPT

-- ── Pre-flight: privileges ───────────────────────────────────
-- Checked up front because the failure is otherwise misleading: RESOURCE grants
-- CREATE TABLE but not CREATE VIEW, so scripts 01 and 02 build their tables,
-- then 01 step [7/8] dies on the first view with a bare ORA-01031 — by which
-- point it looks like the DDL is at fault rather than the grant.
DECLARE
  v_missing VARCHAR2(400);
  v_n       PLS_INTEGER;
  PROCEDURE need(p_priv IN VARCHAR2) IS
    v_cnt PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO v_cnt FROM session_privs WHERE privilege = p_priv;
    IF v_cnt = 0 THEN v_missing := v_missing || p_priv || ', '; END IF;
  END;
BEGIN
  need('CREATE TABLE');
  need('CREATE VIEW');
  need('CREATE SEQUENCE');
  need('CREATE TRIGGER');
  need('CREATE PROCEDURE');

  -- Object grant, not a system privilege, so it is checked differently: if the
  -- package is not visible at all then EXECUTE has not been granted. Checked
  -- here rather than only in 11_auth.sql so a missing grant costs one second
  -- instead of failing eleven scripts into the install.
  SELECT COUNT(*) INTO v_n FROM all_objects
   WHERE owner = 'SYS' AND object_name = 'DBMS_CRYPTO';
  IF v_n = 0 THEN v_missing := v_missing || 'EXECUTE ON DBMS_CRYPTO, '; END IF;

  IF v_missing IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20900,
      CHR(10) || 'Install stopped: ' || USER || ' is missing ' ||
      RTRIM(v_missing, ', ') || CHR(10) ||
      'Run as ADMIN, then re-run this installer:' || CHR(10) ||
      '  GRANT CONNECT, RESOURCE TO ' || USER || ';' || CHR(10) ||
      '  GRANT CREATE VIEW       TO ' || USER || ';' || CHR(10) ||
      '  GRANT EXECUTE ON DBMS_CRYPTO TO ' || USER || ';' || CHR(10) ||
      '  ALTER USER ' || USER || ' QUOTA UNLIMITED ON DATA;');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Privileges OK for ' || USER || '.');
END;
/

-- ── Pre-flight: REST enablement ──────────────────────────────
-- A warning, not a failure. The schema objects install perfectly well without
-- ORDS; only the modules in 11..13 need it, and they are the last thing to run.
DECLARE
  v_n PLS_INTEGER := 0;
BEGIN
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_ords_schemas' INTO v_n;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'WARNING: ' || USER || ' is not REST-enabled, so the ORDS modules will '
      || 'not publish and every endpoint will return 404.');
    DBMS_OUTPUT.PUT_LINE(
      '         As ADMIN: ORDS_ADMIN.ENABLE_SCHEMA(p_schema => ''' || USER
      || ''', ...) — see the header.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Schema is REST-enabled.');
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- USER_ORDS_SCHEMAS is absent when ORDS is not installed at all. Not fatal.
  DBMS_OUTPUT.PUT_LINE(
    'NOTE: could not read USER_ORDS_SCHEMAS — REST enablement unverified.');
END;
/

-- ── Schema objects ───────────────────────────────────────────
PROMPT >>> 01 reference (lookup, period, calendar, config)
@@01_time_reference.sql

PROMPT >>> 02 master (worker, project, task, allocation, absence)
@@02_time_master.sql

PROMPT >>> 03 timesheet (week, entry, grid views)
@@03_timesheet.sql

PROMPT >>> 04 approval & audit (approval log, audit, month confirm)
@@04_approval_audit.sql

PROMPT >>> 05 adjustments, leave-loss coverage, salary hold
@@05_adjustment_llc_salary.sql

PROMPT >>> 06 client documents & sync telemetry
@@06_client_docs_sync.sql

PROMPT >>> 07 accrual interface (XX_O2C_TIMESHEET_ACCRUAL_IF)
@@07_accrual_interface.sql

PROMPT >>> 08 page views
@@08_views.sql

-- ── Business logic ───────────────────────────────────────────
PROMPT >>> 09 OC_TIME_PKG
@@09_pkg_oc_time.sql

-- ── Reference seed ───────────────────────────────────────────
PROMPT >>> 10 seed (dictionaries, common tasks, PRJ-ORG, config, periods)
@@10_seed.sql

-- ── Sign-in ──────────────────────────────────────────────────
-- After 09/10 because V_OC_TIME_SIGNIN reads OC_TIME_WORKER, OC_TIME_ALLOCATION
-- and OC_TIME_PERIOD; before the ORDS surface, which calls its hash function.
PROMPT >>> 11 auth (OC_TIME_USER, OC_TIME_SESSION, hash, sign-in view)
@@11_auth.sql

-- ── REST surface ─────────────────────────────────────────────
PROMPT >>> 12 ORDS oc.time            (employee)
@@ords/11_ords_time.sql

PROMPT >>> 13 ORDS oc.time.approval   (manager)
@@ords/12_ords_time_approval.sql

PROMPT >>> 14 ORDS oc.time.admin      (admin + accrual pull)
@@ords/13_ords_time_admin.sql

PROMPT >>> 15 ORDS oc.time.auth       (login, logout, session, set-password)
@@ords/14_ords_time_auth.sql

-- ── Post-install verification ────────────────────────────────
PROMPT
PROMPT ##############################################################
PROMPT #  VERIFICATION
PROMPT ##############################################################
PROMPT

SET FEEDBACK OFF
COLUMN object_name FORMAT A34
COLUMN object_type FORMAT A14
COLUMN status      FORMAT A8

PROMPT --- Invalid objects (expect none) ---------------------------
SELECT object_type, object_name, status
  FROM user_objects
 WHERE status <> 'VALID'
 ORDER BY object_type, object_name;

PROMPT --- Tables --------------------------------------------------
SELECT table_name AS object_name
  FROM user_tables
 WHERE table_name LIKE 'OC_T%' OR table_name LIKE 'XX_O2C%'
 ORDER BY table_name;

PROMPT --- Views ---------------------------------------------------
SELECT view_name AS object_name FROM user_views
 WHERE view_name LIKE 'V_OC_T%'
 ORDER BY view_name;

PROMPT --- ORDS modules --------------------------------------------
COLUMN name      FORMAT A22
COLUMN uri_prefix FORMAT A26
SELECT m.name, m.uri_prefix, m.status,
       (SELECT COUNT(*) FROM user_ords_templates t
         WHERE t.module_id = m.id) AS templates,
       (SELECT COUNT(*) FROM user_ords_handlers h
         JOIN user_ords_templates t2 ON t2.id = h.template_id
        WHERE t2.module_id = m.id)  AS handlers
  FROM user_ords_modules m
 WHERE m.name IN ('oc.time','oc.time.approval','oc.time.admin','oc.time.auth')
 ORDER BY m.name;

PROMPT --- Seed counts ---------------------------------------------
SELECT 'lookup rows'   AS item, COUNT(*) AS cnt FROM oc_time_lookup
UNION ALL
SELECT 'common tasks',  COUNT(*) FROM oc_time_task WHERE task_type = 'COMMON'
UNION ALL
SELECT 'periods',       COUNT(*) FROM oc_time_period
UNION ALL
SELECT 'open periods',  COUNT(*) FROM oc_time_period WHERE status = 'Open'
UNION ALL
SELECT 'config items',  COUNT(*) FROM oc_time_config
UNION ALL
SELECT 'calendar days', COUNT(*) FROM oc_time_calendar;

SET FEEDBACK ON

PROMPT
PROMPT ##############################################################
PROMPT #  INSTALL COMPLETE
PROMPT #
PROMPT #  Next steps
PROMPT #   1. ORDS.ENABLE_SCHEMA (see the header) if not already done.
PROMPT #   2. Load Fusion master data: OC_TIME_WORKER, OC_TIME_PROJECT,
PROMPT #      OC_TIME_TASK, OC_TIME_ALLOCATION, OC_TIME_ABSENCE via OIC
PROMPT #      (INT-001 .. INT-006).
PROMPT #   3. Sync the calendar layers:
PROMPT #      POST /oc/time/admin/calendar/sync/{CORPORATE|PROJECT|CLIENT|SHIFT}
PROMPT #   4. Run population for the open period:
PROMPT #      POST /oc/time/admin/jobs/populate/{periodId}
PROMPT #   5. Point the VBCS service connection at this schema's ORDS base URL
PROMPT #      (services/catalog.json -> backends.oc_time.servers[0].url).
PROMPT #   6. Create sign-in accounts. OC_TIME_USER is empty after this install,
PROMPT #      so nobody can log in yet. Either run 90_test_seed.sql for the demo
PROMPT #      logins, or insert real ones:
PROMPT #        INSERT INTO oc_time_user (employee_id, email, full_name, status)
PROMPT #        VALUES ('RI2824','someone@rite.digital','Their Name','Invited');
PROMPT #      An Invited user sets their own password at first sign-in via
PROMPT #        POST /oc/time/auth/set-password  {email, newPassword}
PROMPT ##############################################################
PROMPT
