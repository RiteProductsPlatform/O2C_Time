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
-- To publish the ORDS modules the schema must already be REST-enabled:
--     BEGIN ORDS.ENABLE_SCHEMA(p_enabled => TRUE,
--                              p_schema  => 'O2C_TIME',
--                              p_url_mapping_type    => 'BASE_PATH',
--                              p_url_mapping_pattern => 'o2c_time',
--                              p_auto_rest_auth      => FALSE); COMMIT; END;
--     /
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

-- ── REST surface ─────────────────────────────────────────────
PROMPT >>> 11 ORDS oc.time            (employee)
@@ords/11_ords_time.sql

PROMPT >>> 12 ORDS oc.time.approval   (manager)
@@ords/12_ords_time_approval.sql

PROMPT >>> 13 ORDS oc.time.admin      (admin + accrual pull)
@@ords/13_ords_time_admin.sql

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
 WHERE m.name IN ('oc.time','oc.time.approval','oc.time.admin')
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
PROMPT ##############################################################
PROMPT
