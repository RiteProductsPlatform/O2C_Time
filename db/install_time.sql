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
--     GRANT CONNECT, RESOURCE TO O2C_TIME;
--     GRANT CREATE VIEW       TO O2C_TIME;
--     ALTER USER O2C_TIME QUOTA UNLIMITED ON DATA;   -- ADB tablespace is DATA
--
--    No DBMS_CRYPTO grant is needed. Sign-in hashes with STANDARD_HASH, a SQL
--    built-in that produces byte-identical SHA-256, and mints session tokens
--    with oc_time_new_token. The token generator is weaker than
--    DBMS_CRYPTO.RANDOMBYTES and says so in 11_auth.sql — restore it before
--    PROD (one line, plus the grant).
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
--==============================================================
-- RUNNING THIS IN SQL DEVELOPER — use install_time_ALL.sql instead
--==============================================================
-- The @@ includes below are resolved by SQL*Plus relative to this file. SQL
-- Developer only does the same when the script has been OPENED FROM A FILE and
-- run with F5 (Run Script) — and it does not quote the path it builds, so a
-- directory containing a space breaks the include. This repository lives under
-- "OneDrive - RITE/O2C/Time Module/...", which has two. The failure is quiet:
-- the includes are skipped, the run reports success, and nothing is created.
--
-- db/install_time_ALL.sql is this file with all 18 scripts expanded inline. It
-- has no includes, so it runs the same opened, pasted, or through SQLcl, on any
-- path. Regenerate it with `python db/build_install_all.py` after changing the
-- install order or any script in it.
--
-- Either way: F5 (Run Script), never Ctrl+Enter — Run Statement executes a
-- single statement and will look like it worked.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET FEEDBACK ON
-- Stops at the first real failure rather than leaving a half-built schema. In
-- SQL Developer this also disconnects the worksheet, which looks alarming and
-- is not damage: reconnect, read the last error, fix it, re-run. Every script
-- is idempotent, so re-running is the intended way to recover.
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT
PROMPT ##############################################################
PROMPT #  O2C TIMESHEET MODULE - INSTALL
PROMPT ##############################################################
PROMPT

-- ── Pre-flight: privileges ───────────────────────────────────
-- Reported up front because the failure is otherwise misleading: RESOURCE
-- grants CREATE TABLE but not CREATE VIEW, so scripts 01 and 02 build their
-- tables, then 01 step [7/8] dies on the first view with a bare ORA-01031 — by
-- which point it looks like the DDL is at fault rather than the grant.
--
-- A WARNING, NOT A GATE — and that is deliberate (01-Aug-2026).
--
-- This block used to RAISE, and it stopped a perfectly good install dead. The
-- tell was that it named CREATE TABLE / SEQUENCE / TRIGGER / PROCEDURE but not
-- CREATE VIEW: the first four come from the RESOURCE role, CREATE VIEW had been
-- granted directly. SESSION_PRIVS shows only what is enabled in the CURRENT
-- session, so wherever roles are not enabled — some tool connections, and any
-- definer's-rights context — every role-derived privilege reads as missing
-- while direct grants read as present.
--
-- So the query below also looks through the roles granted to the user. But a
-- pre-flight that cannot be trusted must not be able to block: if it is wrong
-- again, the real DDL fails immediately afterwards with a specific ORA-01031 on
-- the exact object, which is a better diagnostic than a guess made up front.
DECLARE
  v_missing VARCHAR2(400);

  PROCEDURE need(p_priv IN VARCHAR2) IS
    v_cnt PLS_INTEGER;
  BEGIN
    -- Three sources: the session, privileges granted directly to the user, and
    -- privileges reachable through any role granted to them. The last is what
    -- SESSION_PRIVS alone misses when roles are not enabled.
    SELECT COUNT(*) INTO v_cnt FROM (
      SELECT privilege FROM session_privs
      UNION
      SELECT privilege FROM user_sys_privs
      UNION
      SELECT rsp.privilege
        FROM role_sys_privs  rsp
        JOIN user_role_privs urp ON urp.granted_role = rsp.role
    ) WHERE privilege = p_priv;

    IF v_cnt = 0 THEN v_missing := v_missing || p_priv || ', '; END IF;
  END;
BEGIN
  need('CREATE TABLE');
  need('CREATE VIEW');
  need('CREATE SEQUENCE');
  need('CREATE TRIGGER');
  need('CREATE PROCEDURE');

  -- DBMS_CRYPTO is deliberately NOT required. Sign-in uses STANDARD_HASH for
  -- passwords and oc_time_new_token for session tokens, both of which need no
  -- grant. See the security note in 11_auth.sql: the hash side is an exact
  -- substitution, the token side is weaker and is recorded as debt.

  IF v_missing IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('WARNING: could not confirm ' ||
      RTRIM(v_missing, ', ') || ' for ' || USER || '.');
    DBMS_OUTPUT.PUT_LINE(
      '         The install continues. If a privilege really is missing the');
    DBMS_OUTPUT.PUT_LINE(
      '         next script fails with ORA-01031 naming the object. To grant:');
    DBMS_OUTPUT.PUT_LINE('           GRANT CONNECT, RESOURCE TO ' || USER || ';');
    DBMS_OUTPUT.PUT_LINE('           GRANT CREATE VIEW       TO ' || USER || ';');
    DBMS_OUTPUT.PUT_LINE('           ALTER USER ' || USER ||
                         ' QUOTA UNLIMITED ON DATA;');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Privileges OK for ' || USER || '.');
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Even the check failing must not stop the install.
  DBMS_OUTPUT.PUT_LINE('NOTE: privilege pre-flight could not run - ' ||
                       SUBSTR(SQLERRM, 1, 150));
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

-- ── Tables the package body reads ────────────────────────────
-- 15 runs HERE, ahead of its number, and the number is not the mistake.
--
-- OC_TIME_PKG references OC_TS_SALARY_HOLD_DAY in six procedures. Created after
-- the package, every one of those is ORA-00942 and the body compiles INVALID --
-- nine errors from one missing table. A recompile after step 15 fixed the full
-- installer and fixed nothing else: running 09 on its own, which is the normal
-- thing to do after editing the package, still failed. Ordering the dependency
-- correctly fixes both.
--
-- 15 only needs 01, 03 and 05, all of which are already done by here.
PROMPT >>> 15 salary stopping, day-wise (PROC-007 revised)
@@15_salary_hold_days.sql

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
@@12_revoke.sql

-- ── Post-baseline changes, in the order they were decided ────
-- 13 was missing from this installer until 09-Aug-2026, so a fresh schema came
-- up still enforcing one-open-period while the running environments did not —
-- the two would have diverged silently on the next rebuild.
PROMPT >>> 13 several periods may be Open (RULE-017 relaxed)
@@13_open_periods.sql
PROMPT >>> 14 invoice annexure over the accrual hand-off
@@14_invoice_annexure.sql
-- 17 before 16: the loader's FK lookup reads PROJECT_NUMBER, which 17 adds.
PROMPT >>> 17 columns the extracts send with nowhere to land
@@17_sync_column_gaps.sql
PROMPT >>> 18 OC_TIME_TASK natural key (the loader cannot merge without it)
@@18_task_natural_key.sql
PROMPT >>> 16 OIC sync config + the generic XML loader
PROMPT [n/m] 23_unbilled_reason_per_line.sql - reason per line, PRJ-ORG retired
@@23_unbilled_reason_per_line.sql

@@16_oic_sync_config.sql

PROMPT [n/m] 19_sync_change_capture.sql - before-image capture + append-only
@@19_sync_change_capture.sql

PROMPT [n/m] 20_retro_reallocation.sql - retro allocation change -> Reversal/Adjustment
@@20_retro_reallocation.sql

PROMPT [n/m] 21_adjustment_lifecycle.sql - submit/approve cut-offs for adjustments
@@21_adjustment_lifecycle.sql

PROMPT [n/m] 24_period_rollover.sql - open/close a period from the admin screen
@@24_period_rollover.sql

PROMPT [n/m] 25_absence_source.sql - leave is its own source, not a manager edit
@@25_absence_source.sql

PROMPT [n/m] 26_change_line_task.sql - move a line to a different task (H8)
@@26_change_line_task.sql

PROMPT [n/m] 27_status_model_v4.sql - two status axes, flags as rows, rules as data
@@27_status_model_v4.sql

PROMPT [n/m] 28_transition_timing.sql - lateness is decided by the cut-off
@@28_transition_timing.sql

PROMPT [n/m] 30_mec_period_live.sql - periods read LIVE from the main app
@@30_mec_period_live.sql

PROMPT [n/m] 31_retire_period_writes.sql - nothing here opens or closes a period
@@31_retire_period_writes.sql

PROMPT [n/m] 35_period_direct.sql - OC_TIME_PERIOD is a direct select upstream
@@35_period_direct.sql

PROMPT [n/m] 36_period_direct_fix.sql - finishes 35 (advance_close, PL/SQL, triggers)
@@36_period_direct_fix.sql

PROMPT [n/m] 37_status_engine_v4.sql - the V4 status engine (phase 2)
@@37_status_engine_v4.sql

PROMPT [n/m] 38_week_versioning.sql - every change to a week leaves a version
@@38_week_versioning.sql

PROMPT [n/m] 39_engine_prereqs.sql - axis defaults, the as-of timing, the wrapper
@@39_engine_prereqs.sql

PROMPT [n/m] 40_reclaim_orphan_periods.sql - reattach rows when upstream renumbers
@@40_reclaim_orphan_periods.sql

PROMPT [n/m] 41_remap_fixes.sql - append-only trail, backups excluded, no 'Closed'
@@41_remap_fixes.sql

PROMPT [n/m] 42_phase2b_rules.sql - Revoke / RevokeDecision / AdvanceApprove
@@42_phase2b_rules.sql

PROMPT [n/m] 43_approval_guards.sql - a manager may only decide what reached them
@@43_approval_guards.sql

PROMPT [n/m] 44_leave_and_allocation_retraction.sql - the sync can take things back
@@44_leave_and_allocation_retraction.sql

-- OUT OF NUMERIC ORDER ON PURPOSE. 45's oc_time_daily_post_load calls
-- oc_time_restore_default_hours, which 61 creates, so 61 must exist first or
-- 45 compiles with PLS-00201 against a procedure that appears sixteen files
-- later. Runs its own backfill too, which is harmless on a fresh install.
PROMPT [n/m] 61_restore_default_hours.sql - withdrawing leave gives the day back
@@61_restore_default_hours.sql

-- Immediately after 61, which it replaces the body of. 61 creates the
-- procedure and repairs days stranded at zero; 62 widens the same procedure to
-- any prepopulated row that disagrees with its allocation. Signature unchanged,
-- so ords/13 and 45 below bind to the widened version either way.
PROMPT [n/m] 62_realign_alloc_hours.sql - an allocation change reaches built days
@@62_realign_alloc_hours.sql

-- After 62, and it needs 09 re-run to stay fixed: populate's day loop now
-- honours each allocation's own span, so these dates are not seeded again.
PROMPT [n/m] 63_unallocated_entries.sql - clear rows seeded outside an allocation
@@63_unallocated_entries.sql

-- Last of the four, and it narrows the previous one: 62 realigns any date, 64
-- restricts that to periods still editable, because a change past the delivery
-- cut-off is an adjustment (RULE-007) and belongs to a person.
PROMPT [n/m] 64_realign_editable_only.sql - closed months are adjusted, not rewritten
@@64_realign_editable_only.sql

PROMPT [n/m] 65_shift_name.sql - the shift strip shows a name, not a surrogate id
@@65_shift_name.sql

PROMPT [n/m] 45_daily_post_load.sql - what OIC calls after the feeds land
@@45_daily_post_load.sql

-- 38..43 MUST run in this order and MUST all run. 42 seeds rules the package
-- body calls, and a missing rule is -20034 at RUNTIME, not at compile time --
-- so 09 would compile perfectly and then refuse the first Revoke anybody
-- attempted. 43 then REPLACES the Approve / ApproveOverride / Reject / Revoke
-- rules with guarded versions; stopping at 42 leaves a schema where a manager
-- can approve a week nobody submitted. They were missing from this installer
-- until 15-Aug-2026, which meant a freshly built UAT or PROD would have had
-- exactly that hole while this environment did not.
--
-- 40 and 41 are here despite being written to repair an incident: a fresh
-- schema has no orphans to reclaim, but it still needs
-- oc_time_remap_periods and oc_time_daily_period_health, because PERIOD_ID is
-- the main application's number and they can re-issue it at any time.
--
-- 34_provision_periods.sql is SUPERSEDED by 35. It created a local anchor row
-- per period, which 35 removes the need for entirely -- PERIOD_ID is now the
-- main application's own id, so a period added there is simply here.
-- 32 and 33 are incident scripts from 14-Aug, not part of a clean install:
-- 32 is disabled (it dropped a live view on a wrong diagnosis) and 33 repairs
-- what it removed. A fresh schema needs neither.
-- 29_mec_period_sync.sql is the FALLBACK, not part of the install. It copies
-- periods instead of reading them live, and is only wanted if neither a grant
-- on o2c_dev.oc_mec_period nor a database link can be had. 30 prints the exact
-- statement to ask for if it cannot reach the table.
-- 15 is NOT here: it creates a table the package body reads, so it runs before
-- step 09 above. Moving it back would reintroduce nine ORA-00942s.

-- ── REST surface ─────────────────────────────────────────────
PROMPT >>> 12 ORDS oc.time            (employee)
@@ords/11_ords_time.sql

PROMPT >>> 13 ORDS oc.time.approval   (manager)
@@ords/12_ords_time_approval.sql

PROMPT >>> 14 ORDS oc.time.admin      (admin + accrual pull)
@@ords/13_ords_time_admin.sql

PROMPT >>> 15 ORDS oc.time.auth       (login, logout, session, set-password)
@@ords/14_ords_time_auth.sql

PROMPT [n/m] ords/15_ords_time_sync.sql - the OIC surface (INT 001 / INT 002)
@@ords/15_ords_time_sync.sql

PROMPT [n/m] 46_jobs_daily_post_load.sql - jobs/daily runs the full daily chain
@@46_jobs_daily_post_load.sql

PROMPT [n/m] 47_cutoff_scheduler.sql - the weekly/delivery cut-off job
@@47_cutoff_scheduler.sql

PROMPT [n/m] 48_cutoff_local_time.sql - the cut-off is 17:00 where the person is
@@48_cutoff_local_time.sql

PROMPT [n/m] 49_country_zones.sql - a zone for every country in the data
@@49_country_zones.sql

PROMPT [n/m] 50_work_pattern_local.sql - set a working pattern without OIC
@@50_work_pattern_local.sql

PROMPT [n/m] 51_default_double_count.sql - a defaulted week populated twice
@@51_default_double_count.sql

PROMPT [n/m] 52_roster_realign.sql - a roster change reaches weeks already built
@@52_roster_realign.sql

PROMPT [n/m] 53_payroll_cutoff.sql - the payroll cut-off, per country, read live
@@53_payroll_cutoff.sql

PROMPT [n/m] 54_payroll_country_alias.sql - their country names to ours
@@54_payroll_country_alias.sql

-- A no-op on a fresh install: this installer never runs 90_test_seed.sql, so
-- there is nothing stamped TEST_SEED to remove. It is here so an environment
-- that WAS seeded converges on the same state as one that was not, rather than
-- keeping three fictional projects on the manager landing page forever.
PROMPT [n/m] 55_purge_test_seed.sql - remove fabricated seed data if any exists
@@55_purge_test_seed.sql

-- After 55, because the roles it derives must not be computed from seeded
-- projects. Safe on a fresh install: with no workers synced yet it changes
-- nothing, and the procedure it leaves behind is what keeps roles true.
PROMPT [n/m] 59_derive_roles.sql - APP_ROLE from HCM worker type and PPM manager
@@59_derive_roles.sql
-- 46 MUST come after ords/13. It redefines the jobs/daily handler that 13
-- creates, so running it earlier means 13 quietly puts the populate-only
-- version back and the whole post-load chain is dropped with no error
-- anywhere. Placed after 15 rather than immediately after 13 so it stays at
-- the end of the ORDS section and cannot be reordered into the middle of it.

-- ── Recompile anything the DDL invalidated ───────────────────
--
-- Adding a column to a table marks every dependent view INVALID. Oracle
-- recompiles them lazily on first use, so they are usually harmless — but
-- "usually" is the problem: a genuine error and a not-yet-touched object look
-- identical in USER_OBJECTS, so nobody can tell which they are looking at.
--
-- Compiling them here forces the distinction. Anything still INVALID after this
-- is really broken, and the verification block below will show it.
DECLARE
  v_n    PLS_INTEGER := 0;
  v_left PLS_INTEGER := 0;
BEGIN
  -- Views first, then everything else: a package body that reads an invalid
  -- view cannot compile until the view is sound.
  FOR o IN (SELECT object_type, object_name
              FROM user_objects
             WHERE status <> 'VALID'
               AND object_type IN ('VIEW','TRIGGER','PROCEDURE','FUNCTION',
                                   'PACKAGE','PACKAGE BODY')
             ORDER BY CASE object_type WHEN 'VIEW' THEN 1
                                       WHEN 'TRIGGER' THEN 2
                                       WHEN 'PACKAGE' THEN 3
                                       ELSE 4 END)
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER ' ||
        CASE o.object_type WHEN 'PACKAGE BODY' THEN 'PACKAGE' ELSE o.object_type END
        || ' ' || o.object_name || ' COMPILE' ||
        CASE WHEN o.object_type = 'PACKAGE BODY' THEN ' BODY' ELSE '' END;
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      -- ORA-24344 is "compiled with errors", which is the answer we wanted.
      NULL;
    END;
  END LOOP;

  SELECT COUNT(*) INTO v_left FROM user_objects WHERE status <> 'VALID';
  DBMS_OUTPUT.PUT_LINE('recompiled ' || v_n || ' object(s); ' || v_left ||
                       ' still invalid.');
  IF v_left > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Those are real errors - see the list below, then '
                         || 'SELECT * FROM user_errors.');
  END IF;
END;
/

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

PROMPT --- Invalid objects (expect none)
SELECT object_type, object_name, status
  FROM user_objects
 WHERE status <> 'VALID'
 ORDER BY object_type, object_name;

PROMPT --- Tables
SELECT table_name AS object_name
  FROM user_tables
 WHERE table_name LIKE 'OC_T%' OR table_name LIKE 'XX_O2C%'
 ORDER BY table_name;

PROMPT --- Views
SELECT view_name AS object_name FROM user_views
 WHERE view_name LIKE 'V_OC_T%'
 ORDER BY view_name;

PROMPT --- ORDS modules
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

PROMPT --- Seed counts
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
PROMPT #      so nobody can log in yet. 56_invite_logins.sql invites a named
PROMPT #      cohort from OC_TIME_WORKER (edit the list in it); it is not part
PROMPT #      of this installer because who gets an account is per-environment.
PROMPT #      Or insert them directly:
PROMPT #        INSERT INTO oc_time_user (employee_id, email, full_name, status)
PROMPT #        VALUES ('RI2824','someone@rite.digital','Their Name','Invited');
PROMPT #      An Invited user sets their own password at first sign-in via
PROMPT #        POST /oc/time/auth/set-password  {email, newPassword}
PROMPT ##############################################################
PROMPT
