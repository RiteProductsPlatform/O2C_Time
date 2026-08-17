--==============================================================
-- time/59_derive_roles.sql
-- O2C Timesheet Module — APP_ROLE comes from HCM and PPM, not from a person
--
-- OC_TIME_WORKER.APP_ROLE has never had a source. The column carries
-- DEFAULT 'ROLE_TIME_EMPLOYEE' NOT NULL, so every synced worker landed as an
-- employee by DDL, and the only rows that said anything else were the four
-- 90_test_seed typed by hand. Measured after the purge: 5,622 employee,
-- 2 manager, 1 contractor, 1 none -- an approval hierarchy for five and a half
-- thousand people resting on two hand-written rows nothing maintains.
--
-- Both facts are already in the cache, synced from the systems that own them:
--
--   contractor   OC_TIME_WORKER.WORKER_TYPE, from HCM's
--                PAAM.SYSTEM_PERSON_TYPE = 'CWK'
--   manager      OC_TIME_PROJECT.PROJECT_MANAGER_ID, from the PPM project
--                party whose PJT_PROJECT_ROLES_VL.NAME = 'Project Manager'
--
-- So nothing new has to be extracted. The role just has to be COMPUTED from
-- what is already there instead of typed.
--
-- WHY A PROJECT MANAGER AND NOT A LINE MANAGER
--   OC_TIME_WORKER.MANAGER_EMP_ID is HCM's line manager and is NOT used here.
--   The Team screens select on V_OC_TS_MGR_PROJECTS.PROJECT_MANAGER_ID, so a
--   line manager who runs no project would get the Team menu and find it
--   empty. RULE-015 still uses the line manager for the separate question of
--   who approves a manager's OWN week; that is unaffected.
--
-- WHY MANAGER OUTRANKS CONTRACTOR
--   A contingent worker can run a project. APP_ROLE decides the MENU, and such
--   a person needs the Team screens. Nothing is lost by ranking it that way:
--   the employee/contractor distinction that RULE-021 and RA-012 turn on lives
--   in WORKER_TYPE, which this never touches, and those rules should read it
--   there rather than through APP_ROLE.
--
-- ROLE_TIME_NONE IS NOW EARNED, NOT ASSIGNED
--   A worker with no active allocation to any time-tracking project has
--   nothing to record, and giving them 'My Work' shows an empty grid. They get
--   ROLE_TIME_NONE. This is most of the pod and that is correct -- 5,976
--   people are synced and a few dozen are on our projects. It also means
--   SC-23's empty-menu case no longer needs a specially flagged person.
--
-- OC_TIME_USER.APP_ROLE IS NEVER TOUCHED. That column is the administrator
-- override and exists for the one login with no worker behind it (CLAUDE.md
-- section 4). Only the worker's role is derived here.
--
-- Idempotent, and safe to re-run after every master sync -- which is the
-- intention: see [4].
--
-- Depends on: time/02, a completed WORKERS and PROJECTS sync.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] The rule, as a view, so it can be read before it is applied
PROMPT ============================================================

-- A view rather than logic buried in the procedure: the answer can be queried,
-- diffed against what is stored, and explained to somebody, without running
-- anything. V_OC_TIME_WORKER_ROLE is the definition; the procedure below only
-- copies it onto the column.
CREATE OR REPLACE VIEW v_oc_time_worker_role AS
SELECT w.employee_id,
       w.employee_name,
       w.worker_type,
       w.app_role AS current_role,
       CASE
         -- 1. Runs a project -> Team screens. Highest, and deliberately ahead
         --    of contractor; see the header.
         WHEN EXISTS (SELECT 1 FROM oc_time_project p
                       WHERE p.project_manager_id = w.employee_id
                         AND p.status = 'Active')
           THEN 'ROLE_TIME_MANAGER'
         -- 2. HCM says contingent worker.
         WHEN w.worker_type = 'Contractor'
           THEN 'ROLE_TIME_CONTRACTOR'
         -- 3. Allocated to something that tracks time -> can record.
         WHEN EXISTS (SELECT 1 FROM oc_time_allocation a
                       JOIN oc_time_project p2 ON p2.project_id = a.project_id
                      WHERE a.employee_id = w.employee_id
                        AND a.status = 'Active'
                        AND p2.status = 'Active'
                        AND p2.time_entry_enabled = 'Y')
           THEN 'ROLE_TIME_EMPLOYEE'
         -- 4. In HCM, not on any of our projects. No menu.
         ELSE 'ROLE_TIME_NONE'
       END AS derived_role
  FROM oc_time_worker w
 WHERE w.status = 'Active';

PROMPT ============================================================
PROMPT [2/5] What would change
PROMPT ============================================================

COLUMN current_role FORMAT A24
COLUMN derived_role FORMAT A24
SELECT NVL(current_role,'(null)') AS current_role,
       derived_role,
       COUNT(*) AS workers
  FROM v_oc_time_worker_role
 GROUP BY current_role, derived_role
 ORDER BY 3 DESC;

PROMPT
PROMPT --- the named cohort, before and after
COLUMN employee_id FORMAT A11
COLUMN employee_name FORMAT A30
COLUMN worker_type FORMAT A12
SELECT employee_id, employee_name, worker_type, current_role, derived_role
  FROM v_oc_time_worker_role
 WHERE employee_id IN ('RI9001','RI2894','RI2824','RI2900','RI2963','RI2935',
                       'RI3004','RI2914','CRI0406','CRI0398','RI2985','RI2249')
 ORDER BY employee_id;

PROMPT ============================================================
PROMPT [3/5] OC_TIME_DERIVE_ROLES
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_derive_roles(
  p_actor    IN  VARCHAR2 DEFAULT 'DERIVE_ROLES',
  o_changed  OUT NUMBER)
IS
BEGIN
  -- One statement, driven by the view, so the stored value and the documented
  -- rule cannot drift apart. Only rows that actually differ are written --
  -- otherwise every worker's UPDATED_ON moves on every sync and the column
  -- stops meaning "when did this person last change".
  UPDATE oc_time_worker w
     SET w.app_role   = (SELECT r.derived_role FROM v_oc_time_worker_role r
                          WHERE r.employee_id = w.employee_id),
         w.updated_by = p_actor,
         w.updated_on = SYSTIMESTAMP
   WHERE EXISTS (SELECT 1 FROM v_oc_time_worker_role r
                  WHERE r.employee_id = w.employee_id
                    AND NVL(r.current_role,'~') <> r.derived_role);
  o_changed := SQL%ROWCOUNT;
  COMMIT;
END oc_time_derive_roles;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/5] Apply
PROMPT ============================================================

DECLARE
  v_changed NUMBER;
BEGIN
  oc_time_derive_roles('DERIVE_ROLES', v_changed);
  DBMS_OUTPUT.PUT_LINE('roles rewritten: ' || v_changed);
END;
/

COLUMN app_role FORMAT A24
SELECT NVL(app_role,'(null)') AS app_role, COUNT(*) AS workers
  FROM oc_time_worker WHERE status = 'Active'
 GROUP BY app_role ORDER BY 2 DESC;

PROMPT ============================================================
PROMPT [5/5] Keeping it true
PROMPT ============================================================
PROMPT
PROMPT This is a snapshot until something calls it. A project changing hands in
PROMPT PPM, or a contractor converting to permanent in HCM, moves the answer,
PROMPT and nothing here notices on its own.
PROMPT
PROMPT Call it after every master sync, once PROJECTS and WORKERS have both
PROMPT landed:
PROMPT
PROMPT   DECLARE n NUMBER; BEGIN oc_time_derive_roles('MASTER_SYNC', n); END;
PROMPT
PROMPT The natural home is oc_time_daily_post_load (db/46), which POST
PROMPT jobs/daily already runs. Not wired in here on purpose: that procedure
PROMPT runs the populate chain, and a role change is a different kind of event
PROMPT worth seeing separately the first few times.
PROMPT
PROMPT WORKER_TYPE is untouched and stays HCM's answer. Any rule about
PROMPT contractors -- RULE-021, RA-012's salary-hold exclusion -- should read
PROMPT WORKER_TYPE, not APP_ROLE, because a contractor who runs a project is
PROMPT now correctly ROLE_TIME_MANAGER and would be missed.
