--==============================================================
-- time/55_purge_test_seed.sql
-- O2C Timesheet Module — remove the fabricated seed data
--
-- 90_test_seed.sql populated the module before Fusion was wired up. Master
-- data now arrives from the pod (WORKERS 5976, PROJECTS 423, TASKS 10534,
-- ALLOCATIONS 1595, ABSENCES, CALENDAR), so everything the seed invented is
-- both unnecessary and actively misleading: three projects nobody works on sit
-- on the manager landing page as "No employees", and a hand-written Mon-Fri
-- calendar would mask a broken calendar sync with plausible-looking days.
--
-- Every seed row is stamped CREATED_BY = 'TEST_SEED' (the DEV calendar block
-- uses SOURCE_SYSTEM = 'SEED'), so the predicate is exact and this cannot
-- reach a Fusion-synced row.
--
-- WHAT THIS DELIBERATELY DOES NOT TOUCH, AND WHY
--
--   OC_TIME_WORKER   The twelve "seeded" workers are REAL PEOPLE in HCM --
--                    RI9001, RI2894 and the rest. The seed merely inserted
--                    them before the sync existed; the sync has owned them
--                    since. Deleting them would delete live master data and
--                    cascade into every timesheet. See [6] for the one field
--                    on these rows that genuinely has no upstream.
--
--   ABSENCE_CLASS    Seeded into OC_TIME_LOOKUP with CREATED_BY='TEST_SEED',
--   lookups          but it is functional reference data, not fiction: it maps
--                    a Fusion absence type onto IS_LOP / IS_MATERNITY. Delete
--                    it and every absence classifies as NORMAL, so maternity
--                    and loss-of-pay handling silently stops. Kept, and
--                    restamped in [6] so it stops looking like test data.
--
--   admin@rite.digital  The common administrator (CLAUDE.md §4) -- a real
--                    login who need not exist as a worker in HCM. Explicitly
--                    preserved in [5].
--
-- Idempotent: re-running finds nothing left and reports zero. Nothing is
-- dropped, only rows deleted.
--
-- Depends on: time/01..15. Run AFTER a successful master sync, never before --
-- this removes the only data some screens have.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_PROJECT';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/7] What is seeded right now
PROMPT ============================================================

COLUMN entity FORMAT A34
COLUMN detail FORMAT A46
SELECT 'OC_TIME_PROJECT'    AS entity, COUNT(*) AS rows_seeded,
       LISTAGG(project_number, ', ') WITHIN GROUP (ORDER BY project_number) AS detail
  FROM oc_time_project WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'OC_TIME_TASK', COUNT(*), NULL
  FROM oc_time_task WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'OC_TIME_ALLOCATION', COUNT(*), NULL
  FROM oc_time_allocation WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'OC_TIME_ABSENCE', COUNT(*), NULL
  FROM oc_time_absence WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'OC_TIME_CALENDAR', COUNT(*),
       LISTAGG(DISTINCT layer, ', ') WITHIN GROUP (ORDER BY layer)
  FROM oc_time_calendar WHERE source_system IN ('TEST_SEED','SEED')
UNION ALL
SELECT 'OC_TIME_USER (not admin)', COUNT(*), NULL
  FROM oc_time_user
 WHERE (created_by = 'TEST_SEED' OR updated_by = 'TEST_SEED')
   AND LOWER(email) <> 'admin@rite.digital'
UNION ALL
SELECT 'OC_TIME_LOOKUP (kept)', COUNT(*), 'ABSENCE_CLASS -- functional, retained'
  FROM oc_time_lookup WHERE created_by = 'TEST_SEED';

PROMPT ============================================================
PROMPT [2/7] Timesheet rows that reference the seeded projects
PROMPT ============================================================

-- These must go first or the FKs below refuse. Counted separately because a
-- non-zero here means somebody actually booked time against a fictional
-- project, which is worth seeing rather than silently cascading away.
DECLARE
  v_tot NUMBER := 0;

  PROCEDURE show(p_label VARCHAR2, p_n NUMBER) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_label, 30, '.') || ' ' || p_n);
  END;
BEGIN
  FOR c IN (
    SELECT 'OC_TS_ENTRY' AS label, COUNT(*) AS n FROM oc_ts_entry e
      WHERE e.project_id IN (SELECT project_id FROM oc_time_project
                              WHERE created_by = 'TEST_SEED')
    UNION ALL
    SELECT 'OC_TS_ADJUSTMENT', COUNT(*) FROM oc_ts_adjustment a
      WHERE a.old_project_id IN (SELECT project_id FROM oc_time_project
                                  WHERE created_by = 'TEST_SEED')
         OR a.new_project_id IN (SELECT project_id FROM oc_time_project
                                  WHERE created_by = 'TEST_SEED')
    UNION ALL
    SELECT 'OC_TS_LEAVE_LOSS_COVER', COUNT(*) FROM oc_ts_leave_loss_cover l
      WHERE l.project_id IN (SELECT project_id FROM oc_time_project
                              WHERE created_by = 'TEST_SEED')
    UNION ALL
    SELECT 'OC_TS_MONTH_CONFIRM', COUNT(*) FROM oc_ts_month_confirm m
      WHERE m.project_id IN (SELECT project_id FROM oc_time_project
                              WHERE created_by = 'TEST_SEED')
    UNION ALL
    SELECT 'OC_TS_CLIENT_DOC', COUNT(*) FROM oc_ts_client_doc d
      WHERE d.project_id IN (SELECT project_id FROM oc_time_project
                              WHERE created_by = 'TEST_SEED'))
  LOOP
    show(c.label, c.n);
    v_tot := v_tot + c.n;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('---');
  IF v_tot = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No timesheet data references the seeded projects.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(v_tot || ' dependent rows will be removed with them.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [3/7] Delete the fabricated projects, tasks and allocations
PROMPT ============================================================

-- PROJECT_TYPE 'Organization' is the PRJ-ORG project implicitly assigned to
-- every employee (FLD-006). It is module-owned, not Fusion-synced, so it can
-- carry a TEST_SEED stamp while being real. Excluded from every statement here
-- by the DOOMED subquery, which is repeated rather than held in a cursor -- a
-- cursor is not a rowsource and cannot appear in a DELETE.
BEGIN
  DELETE FROM oc_ts_entry
   WHERE project_id IN (SELECT project_id FROM oc_time_project
                         WHERE created_by = 'TEST_SEED'
                           AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TS_ENTRY            ' || SQL%ROWCOUNT);

  DELETE FROM oc_ts_adjustment
   WHERE old_project_id IN (SELECT project_id FROM oc_time_project
                             WHERE created_by = 'TEST_SEED'
                               AND project_type <> 'Organization')
      OR new_project_id IN (SELECT project_id FROM oc_time_project
                             WHERE created_by = 'TEST_SEED'
                               AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TS_ADJUSTMENT       ' || SQL%ROWCOUNT);

  DELETE FROM oc_ts_leave_loss_cover
   WHERE project_id IN (SELECT project_id FROM oc_time_project
                         WHERE created_by = 'TEST_SEED'
                           AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TS_LEAVE_LOSS_COVER ' || SQL%ROWCOUNT);

  DELETE FROM oc_ts_month_confirm
   WHERE project_id IN (SELECT project_id FROM oc_time_project
                         WHERE created_by = 'TEST_SEED'
                           AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TS_MONTH_CONFIRM    ' || SQL%ROWCOUNT);

  DELETE FROM oc_ts_client_doc
   WHERE project_id IN (SELECT project_id FROM oc_time_project
                         WHERE created_by = 'TEST_SEED'
                           AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TS_CLIENT_DOC       ' || SQL%ROWCOUNT);

  DELETE FROM oc_time_allocation
   WHERE project_id IN (SELECT project_id FROM oc_time_project
                         WHERE created_by = 'TEST_SEED'
                           AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TIME_ALLOCATION     ' || SQL%ROWCOUNT);

  DELETE FROM oc_time_task
   WHERE project_id IN (SELECT project_id FROM oc_time_project
                         WHERE created_by = 'TEST_SEED'
                           AND project_type <> 'Organization');
  DBMS_OUTPUT.PUT_LINE('OC_TIME_TASK           ' || SQL%ROWCOUNT);

  DELETE FROM oc_time_project
   WHERE created_by = 'TEST_SEED' AND project_type <> 'Organization';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_PROJECT        ' || SQL%ROWCOUNT);

  -- Any allocation the seed wrote onto a REAL project. The Fusion allocation
  -- sync has already set these to 'Ended' rather than removing them, so they
  -- linger as history nobody wants.
  DELETE FROM oc_time_allocation WHERE created_by = 'TEST_SEED';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_ALLOCATION (on real projects) ' || SQL%ROWCOUNT);

  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/7] Delete seeded absences
PROMPT ============================================================

-- Absence Management is the source of record and already feeds this table.
-- A fabricated maternity or LOP row here changes leave-loss and salary-hold
-- behaviour, so it must not survive into UAT.
DECLARE v_n NUMBER; BEGIN
  DELETE FROM oc_time_absence WHERE created_by = 'TEST_SEED';
  v_n := SQL%ROWCOUNT; COMMIT;
  DBMS_OUTPUT.PUT_LINE('OC_TIME_ABSENCE removed: ' || v_n);
END;
/

PROMPT ============================================================
PROMPT [5/7] Seeded calendar layers, and what covers the open period after
PROMPT ============================================================

-- CLAUDE.md §6: a Mon-Fri calendar seed and a hand-written shift dictionary
-- were both written and then removed once already, because they mask a broken
-- sync with plausible-looking data. The DEV block in 90_test_seed put one
-- back. This removes it again.
--
-- THE RISK IS REAL AND IS MEASURED BELOW. resolve_day reads OC_TIME_CALENDAR
-- by layer; if CORPORATE coverage for the open period goes to zero, every day
-- resolves non-working and prepopulation produces an empty month. The report
-- after the delete shows exactly what is left, per layer, for the open period.
DECLARE
  v_n NUMBER;
  v_period_id NUMBER;
  v_from DATE;
  v_to   DATE;
  v_left NUMBER;
BEGIN
  DELETE FROM oc_time_calendar WHERE source_system IN ('TEST_SEED','SEED');
  v_n := SQL%ROWCOUNT;
  DBMS_OUTPUT.PUT_LINE('OC_TIME_CALENDAR removed: ' || v_n);

  BEGIN
    SELECT period_id, start_date, end_date INTO v_period_id, v_from, v_to
      FROM (SELECT period_id, start_date, end_date FROM oc_time_period
             WHERE status = 'Open' ORDER BY start_date)
     WHERE ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('No open period; coverage check skipped.');
    COMMIT; RETURN;
  END;

  -- CORPORATE IS AN EXCEPTION TABLE, NOT A DAY-BY-DAY CALENDAR, and this check
  -- was written twice on the opposite assumption before that was verified.
  --
  -- The CALENDAR extract selects PER_CALENDAR_EVENTS WHERE category = 'PH' and
  -- emits IS_WORKING_DAY = 'N'. So the layer holds PUBLIC HOLIDAYS ONLY, and a
  -- month with two rows has two public holidays -- it is not "missing" 29 days.
  -- resolve_day's NO_DATA_FOUND branch is the working-day rule: no row on any
  -- layer means Mon-Fri at the worker's own standard hours.
  --
  -- Which is exactly why the seeded Mon-Fri calendar had to go. It filled the
  -- layer with 'Y' rows the real feed never produces, so a broken calendar sync
  -- and a healthy one looked identical.
  --
  -- The meaningful check is therefore NOT coverage but PURITY: every CORPORATE
  -- row left standing should be a non-working holiday. A 'Y' row here means
  -- fabricated data survived.
  SELECT COUNT(*) INTO v_left FROM oc_time_calendar
   WHERE layer = 'CORPORATE' AND cal_date BETWEEN v_from AND v_to
     AND is_working_day = 'Y';

  FOR h IN (SELECT COUNT(*) AS n FROM oc_time_calendar
             WHERE layer = 'CORPORATE' AND cal_date BETWEEN v_from AND v_to)
  LOOP
    DBMS_OUTPUT.PUT_LINE('CORPORATE rows in the open period: ' || h.n
      || ' (public holidays; a full month is NOT expected here)');
  END LOOP;

  IF v_left > 0 THEN
    DBMS_OUTPUT.PUT_LINE('*** WARNING: ' || v_left || ' CORPORATE row(s) say '
      || 'IS_WORKING_DAY = Y.');
    DBMS_OUTPUT.PUT_LINE('*** The Fusion feed only ever emits N. These are '
      || 'fabricated rows that survived.');
  END IF;
  COMMIT;
END;
/

PROMPT
PROMPT --- calendar coverage by layer and source, open period only
COLUMN layer FORMAT A14
COLUMN source_system FORMAT A14
SELECT c.layer, c.source_system, COUNT(*) AS days,
       TO_CHAR(MIN(c.cal_date),'DD-Mon-YY') AS first_day,
       TO_CHAR(MAX(c.cal_date),'DD-Mon-YY') AS last_day
  FROM oc_time_calendar c
  JOIN oc_time_period p ON p.status = 'Open'
                       AND c.cal_date BETWEEN p.start_date AND p.end_date
 GROUP BY c.layer, c.source_system
 ORDER BY c.layer, c.source_system;

PROMPT ============================================================
PROMPT [6/7] Logins: keep the administrator, remove the rest
PROMPT ============================================================

-- OC_TIME_SESSION is ON DELETE CASCADE, so open sessions go with the user.
--
-- After this the twelve test logins are gone and those people sign in only
-- once invited through the normal Invited -> Active lifecycle. That is the
-- point: a shared password across twelve real identities is not something to
-- carry into UAT.
DECLARE
  v_n NUMBER;
  v_admin NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_admin FROM oc_time_user
   WHERE LOWER(email) = 'admin@rite.digital';

  IF v_admin = 0 THEN
    -- Refuse rather than leave the module with no way in at all.
    RAISE_APPLICATION_ERROR(-20098,
      'admin@rite.digital does not exist. Refusing to delete the other '
      || 'logins -- that would leave no way to sign in.');
  END IF;

  DELETE FROM oc_time_user
   WHERE (created_by = 'TEST_SEED' OR updated_by = 'TEST_SEED')
     AND LOWER(email) <> 'admin@rite.digital';
  v_n := SQL%ROWCOUNT;

  -- The administrator row itself was written by the seed. It stays, but it
  -- stops claiming to be test data so a later purge does not take it.
  UPDATE oc_time_user
     SET created_by = 'SYSTEM',
         updated_by = 'PURGE_SEED',
         updated_on = SYSTIMESTAMP
   WHERE LOWER(email) = 'admin@rite.digital'
     AND (created_by = 'TEST_SEED' OR updated_by = 'TEST_SEED');

  -- Same for the absence-class lookups: functional data, wrongly stamped.
  UPDATE oc_time_lookup
     SET created_by = 'SYSTEM'
   WHERE created_by = 'TEST_SEED' AND lookup_type = 'ABSENCE_CLASS';

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('logins removed: ' || v_n);
  DBMS_OUTPUT.PUT_LINE('admin@rite.digital retained and restamped.');
END;
/

PROMPT ============================================================
PROMPT [7/7] Verification
PROMPT ============================================================

COLUMN check_name FORMAT A44
COLUMN result FORMAT A38
SELECT 'seeded projects remaining' AS check_name,
       CASE WHEN COUNT(*) = 0 THEN 'clean'
            ELSE COUNT(*) || ' LEFT' END AS result
  FROM oc_time_project WHERE created_by = 'TEST_SEED' AND project_type <> 'Organization'
UNION ALL
SELECT 'seeded tasks remaining',
       CASE WHEN COUNT(*) = 0 THEN 'clean' ELSE COUNT(*) || ' LEFT' END
  FROM oc_time_task WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'seeded allocations remaining',
       CASE WHEN COUNT(*) = 0 THEN 'clean' ELSE COUNT(*) || ' LEFT' END
  FROM oc_time_allocation WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'seeded absences remaining',
       CASE WHEN COUNT(*) = 0 THEN 'clean' ELSE COUNT(*) || ' LEFT' END
  FROM oc_time_absence WHERE created_by = 'TEST_SEED'
UNION ALL
SELECT 'seeded calendar rows remaining',
       CASE WHEN COUNT(*) = 0 THEN 'clean' ELSE COUNT(*) || ' LEFT' END
  FROM oc_time_calendar WHERE source_system IN ('TEST_SEED','SEED')
UNION ALL
SELECT 'logins remaining (any source)',
       COUNT(*) || ' total, ' ||
       SUM(CASE WHEN LOWER(email) = 'admin@rite.digital' THEN 1 ELSE 0 END)
         || ' admin'
  FROM oc_time_user
UNION ALL
-- Both figures come from ONE aggregate. Written as COUNT(*) beside a scalar
-- subquery it raised ORA-00937: a scalar subquery is not a group function, so
-- Oracle sees an ungrouped expression next to an aggregate.
SELECT 'projects with no approver (RULE-015)',
       SUM(CASE WHEN project_manager_id IS NULL THEN 1 ELSE 0 END)
         || ' of ' || COUNT(*)
  FROM oc_time_project
 WHERE status = 'Active' AND time_entry_enabled = 'Y';

PROMPT
PROMPT ============================================================
PROMPT ONE THING THIS SCRIPT CANNOT FIX
PROMPT ============================================================
PROMPT
PROMPT OC_TIME_WORKER.APP_ROLE has no upstream source. The WORKERS sync
PROMPT (sync/worker in ords/13) never sets it, so every role in the module
PROMPT (ROLE_TIME_EMPLOYEE, ROLE_TIME_CONTRACTOR, ROLE_TIME_MANAGER) was
PROMPT written by 90_test_seed and by nothing else since.
PROMPT
PROMPT Those values are therefore left ALONE by this purge: clearing them
PROMPT would strip every manager and lock the approval screens for everyone.
PROMPT
PROMPT Before UAT it needs a real source. The obvious candidate is Fusion's
PROMPT own answer -- a person who is the Project Manager party on any project
PROMPT is a manager -- which is already what the PROJECTS extract resolves
PROMPT into PROJECT_MANAGER_ID. Settle it rather than inheriting the seed.

COLUMN app_role FORMAT A26
SELECT NVL(app_role,'(null)') AS app_role, COUNT(*) AS workers
  FROM oc_time_worker WHERE status = 'Active'
 GROUP BY app_role ORDER BY 2 DESC;
