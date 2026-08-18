--==============================================================
-- time/75_retire_unsynced.sql
-- O2C Timesheet Module — everything comes from Fusion, including deletion
--
-- The manager screen showed two faults. They look like one bug and are two,
-- and only the first is about master data:
--
--   1. 666 "fire installation work" listed for RI9001, who does not manage it.
--      666 is not in the PROJECTS feed AT ALL, and we still hold it Active with
--      PROJECT_MANAGER_ID RI9001, so V_OC_TS_MGR_PROJECTS offers it every month.
--
--   2. Monthly Summary listing people who are not on the project. 7793 was
--      purged from HCM entirely; 7897 exists but has no allocation; RI2985 and
--      RI2900 were taken off 444.
--
-- THE SYNC HAS NEVER BEEN ABLE TO DELETE. Every loader is a MERGE, so it
-- inserts and updates and nothing else -- and the audit columns hide the
-- omission: NVL(incoming, existing) on PROJECT_MANAGER_ID means a project that
-- stops being sent KEEPS its manager rather than losing one. "Absent from
-- Fusion" was not a state the cache could hold. Now it is: PROJECTS, WORKERS
-- and ALLOCATIONS all stamp FUSION_SYNCED_ON, so a row the last FULL load did
-- not touch is one the feed no longer contains.
--
-- BUT RETIRING THE MASTER DOES NOT FIX FAULT 2, and assuming it would was the
-- first version of this script. V_OC_TS_MONTH_SUMMARY joins the allocation
-- LEFT and uses it only for decoration -- billing_status, client_role, cap:
--
--     JOIN      oc_ts_entry e ON e.ts_week_id = w.ts_week_id
--     LEFT JOIN oc_time_allocation al ON ... AND al.status = 'Active'
--
-- The ROW comes from OC_TS_ENTRY. Ending the allocation blanks four columns and
-- leaves the person on the screen. What puts them there is the prepopulated
-- time written while they were still allocated, so that is what has to go.
--
-- Hence two halves, and section 4 is the one the manager will actually see.
--
-- THE GUARDS ARE THE SUBSTANCE, and one was learned the hard way. db/69's first
-- attempt checked only the PROPORTION -- refuse if more than a fifth look stale
-- -- and retired 15 live allocations on a stamp from 03-Aug that was written
-- before the column was ever sent. A stamp predating the run cannot be evidence
-- about that run, at any fraction. So both tests, every time:
--
--   AGE         the newest stamp must be within 2 days, or nothing runs
--   PROPORTION  more than a fifth stale is a partial load, not a purge
--
-- Nothing is deleted on the master side -- these rows have timesheets,
-- approvals and accrual behind them:
--
--   project     'Closed'    -- V_OC_TS_MGR_PROJECTS filters status = 'Active'
--   worker      'Inactive'
--   allocation  'Ended', end-dated yesterday so it stops counting for today
--
-- Idempotent. Depends on: time/02, 03, 04, 69, 70.
-- RUN A FULL LOAD FIRST (LASTSYNC_DATE NULL on all three) or it refuses and
-- says why. An incremental load stamps only what changed, which makes every
-- untouched row look deleted -- the age guard turns that into a refusal rather
-- than a disaster, but it does mean retirement is a post-full-load step.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TIME_PROJECT' AND column_name = 'FUSION_SYNCED_ON';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', where OC_TIME_PROJECT.FUSION_SYNCED_ON does not exist.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] What each feed last stamped, and what would retire
PROMPT ============================================================

COLUMN entity FORMAT A12
COLUMN newest_stamp FORMAT A12
SELECT 'PROJECT' AS entity,
       NVL(TO_CHAR(MAX(TRUNC(fusion_synced_on)),'DD-Mon-YY'),'(never)') AS newest_stamp,
       COUNT(*) AS active_rows,
       SUM(CASE WHEN NVL(TRUNC(fusion_synced_on), DATE '1900-01-01')
                     < (SELECT MAX(TRUNC(fusion_synced_on)) FROM oc_time_project)
                THEN 1 ELSE 0 END) AS would_retire
  FROM oc_time_project WHERE status = 'Active'
UNION ALL
SELECT 'WORKER',
       NVL(TO_CHAR(MAX(TRUNC(fusion_synced_on)),'DD-Mon-YY'),'(never)'),
       COUNT(*),
       SUM(CASE WHEN NVL(TRUNC(fusion_synced_on), DATE '1900-01-01')
                     < (SELECT MAX(TRUNC(fusion_synced_on)) FROM oc_time_worker)
                THEN 1 ELSE 0 END)
  FROM oc_time_worker WHERE status = 'Active'
UNION ALL
SELECT 'ALLOCATION',
       NVL(TO_CHAR(MAX(TRUNC(fusion_synced_on)),'DD-Mon-YY'),'(never)'),
       COUNT(*),
       SUM(CASE WHEN NVL(TRUNC(fusion_synced_on), DATE '1900-01-01')
                     < (SELECT MAX(TRUNC(fusion_synced_on)) FROM oc_time_allocation)
                THEN 1 ELSE 0 END)
  FROM oc_time_allocation WHERE status = 'Active';

PROMPT
PROMPT A stamp of (never), or older than two days, means that feed has not run
PROMPT since it began sending the column. Retirement refuses in that case.

PROMPT ============================================================
PROMPT [2/5] OC_TIME_RETIRE_UNSYNCED
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_retire_unsynced(
  p_entity  IN  VARCHAR2,                    -- PROJECT | WORKER | ALLOCATION
  p_actor   IN  VARCHAR2 DEFAULT 'SYNC_RETIRE',
  o_ended   OUT NUMBER,
  o_message OUT VARCHAR2)
IS
  v_latest  DATE;
  v_active  NUMBER;
  v_stale   NUMBER;
  v_tab     VARCHAR2(30);
  v_newstat VARCHAR2(20);
  c_max_age CONSTANT NUMBER := 2;
BEGIN
  o_ended := 0;

  CASE UPPER(p_entity)
    WHEN 'PROJECT'    THEN v_tab := 'OC_TIME_PROJECT';    v_newstat := 'Closed';
    WHEN 'WORKER'     THEN v_tab := 'OC_TIME_WORKER';     v_newstat := 'Inactive';
    WHEN 'ALLOCATION' THEN v_tab := 'OC_TIME_ALLOCATION'; v_newstat := 'Ended';
    ELSE
      o_message := 'Unknown entity ' || p_entity
                || '. Expected PROJECT, WORKER or ALLOCATION.';
      RETURN;
  END CASE;

  EXECUTE IMMEDIATE 'SELECT MAX(TRUNC(fusion_synced_on)) FROM ' || v_tab
    INTO v_latest;

  IF v_latest IS NULL THEN
    o_message := v_tab || ': nothing carries FUSION_SYNCED_ON yet. Run a full '
              || UPPER(p_entity) || ' load first. Nothing retired.';
    RETURN;
  END IF;

  -- THE TEST THAT WAS MISSING IN db/69. A stamp older than the run it is meant
  -- to describe proves nothing, however small a fraction disagrees with it.
  IF TRUNC(SYSDATE) - v_latest > c_max_age THEN
    o_message := v_tab || ': newest stamp is ' || TO_CHAR(v_latest,'DD-Mon-YY')
              || ', ' || TO_CHAR(TRUNC(SYSDATE) - v_latest) || ' days old. Not a '
              || 'load that just ran, so absence from it proves nothing. '
              || 'Nothing retired.';
    RETURN;
  END IF;

  EXECUTE IMMEDIATE
       'SELECT COUNT(*),'
    || '       SUM(CASE WHEN NVL(TRUNC(fusion_synced_on), DATE ''1900-01-01'') < :1'
    || '                THEN 1 ELSE 0 END)'
    || '  FROM ' || v_tab || ' WHERE status = ''Active'''
    INTO v_active, v_stale USING v_latest;

  IF NVL(v_stale,0) = 0 THEN
    o_message := v_tab || ': all ' || v_active
              || ' Active row(s) were stamped by the latest load. Nothing to do.';
    RETURN;
  END IF;

  IF v_stale > v_active / 5 THEN
    o_message := v_tab || ': ' || v_stale || ' of ' || v_active || ' look stale. '
              || 'Too many to be deletions -- it reads as a partial load. '
              || 'Nothing retired.';
    RETURN;
  END IF;

  -- ALLOCATION also gets an end date so it stops counting for today; the other
  -- two are governed by status alone. NVL keeps a real Fusion end date if the
  -- row already carried one.
  EXECUTE IMMEDIATE
       'UPDATE ' || v_tab
    || '   SET status = :1, updated_by = :2, updated_on = SYSTIMESTAMP'
    || CASE WHEN v_newstat = 'Ended'
            THEN ', end_date = NVL(end_date, TRUNC(SYSDATE) - 1)' ELSE '' END
    || ' WHERE status = ''Active'''
    || '   AND NVL(TRUNC(fusion_synced_on), DATE ''1900-01-01'') < :3'
    USING v_newstat, p_actor, v_latest;
  o_ended := SQL%ROWCOUNT;
  COMMIT;

  o_message := v_tab || ': ' || o_ended || ' row(s) set ' || v_newstat
            || ' -- absent from the load of ' || TO_CHAR(v_latest,'DD-Mon-YY') || '.';
END oc_time_retire_unsynced;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/5] Run it for all three
PROMPT ============================================================

-- ORDER MATTERS. Allocations first, then projects, then workers: doing the
-- children first means each pass sees a consistent picture rather than
-- allocations hanging off something already inactive.
DECLARE
  v_n NUMBER; v_msg VARCHAR2(400);
BEGIN
  FOR e IN (SELECT 'ALLOCATION' AS x FROM dual UNION ALL
            SELECT 'PROJECT'    FROM dual UNION ALL
            SELECT 'WORKER'     FROM dual)
  LOOP
    oc_time_retire_unsynced(e.x, 'SYNC_RETIRE', v_n, v_msg);
    DBMS_OUTPUT.PUT_LINE('  ' || v_msg);
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [4/5] The half that clears the Monthly Summary
PROMPT ============================================================

-- Prepopulated time left behind by an allocation that no longer exists. This is
-- what puts a stranger on the manager's screen, and no status change removes it.
--
-- FOUR GUARDS, and between them they make this narrow enough to be safe:
--
--   no live allocation   for that project+employee covering the entry's own
--                        date -- so somebody who legitimately rolled off in
--                        August keeps every June row they earned
--   untouched week       NotYetSubmitted + Pending. June and July are already
--                        Defaulted by the cut-off jobs, so they cannot qualify
--                        however this is run
--   no audit row         db/71's rule: OC_TS_AUDIT.TS_ENTRY_ID has no FK, so
--                        deleting an audited entry leaves a trail resolving to
--                        nothing -- worse than a stale cell
--   Prepopulated only    the system put it there and no human has touched it.
--                        Anything typed is 'Employee' and stays
--
-- Weeks are deliberately KEPT, per db/71: populate's guard is per cell and
-- ensure_week reuses what exists, so an emptied week refills exactly like a
-- missing one -- and deleting the week is what raised ORA-20026 twice.
DECLARE
  v_e NUMBER;
BEGIN
  DELETE FROM oc_ts_entry e
   WHERE e.source = 'Prepopulated'
     AND e.entry_type IN ('Actual','Default')
     AND e.ts_week_id IN (
           SELECT w.ts_week_id FROM oc_ts_week w
            WHERE NVL(w.submission_status,'NotYetSubmitted') = 'NotYetSubmitted'
              AND NVL(w.approval_status,'Pending')           = 'Pending')
     AND NOT EXISTS (SELECT 1 FROM oc_ts_audit a
                      WHERE a.ts_entry_id = e.ts_entry_id)
     AND NOT EXISTS (
           SELECT 1
             FROM oc_time_allocation al
             JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
            WHERE al.project_id  = e.project_id
              AND al.employee_id = w2.employee_id
              AND al.status      = 'Active'
              AND e.entry_date BETWEEN NVL(al.start_date, e.entry_date)
                                   AND NVL(al.end_date,   e.entry_date));
  v_e := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_e
    || ' prepopulated entry row(s) removed - no live allocation behind them.');
END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN project_number FORMAT A12
COLUMN project_name FORMAT A32
COLUMN pm FORMAT A10
COLUMN stamped FORMAT A11
SELECT p.project_number, p.project_name, p.status,
       NVL(p.project_manager_id,'-') AS pm,
       NVL(TO_CHAR(p.fusion_synced_on,'DD-Mon-YY'),'(never)') AS stamped
  FROM oc_time_project p
 WHERE p.project_number IN ('444','555','666','PCS10034')
 ORDER BY p.project_number;

PROMPT
PROMPT 666 should read Closed. It is not in the PROJECTS feed, so it is not a
PROMPT project anybody should be asked to approve.

COLUMN employee_id FORMAT A10
COLUMN employee_name FORMAT A26
SELECT w.employee_id, w.employee_name, w.status,
       (SELECT COUNT(*) FROM oc_time_allocation a
         WHERE a.employee_id = w.employee_id AND a.status = 'Active') AS live_allocs
  FROM oc_time_worker w
 WHERE w.employee_id IN ('7793','7897','RI2985','RI2900','RI2894','RI2824')
 ORDER BY w.employee_id;

PROMPT
PROMPT 7793 should be Inactive with no allocations - purged from HCM. 7897 is
PROMPT still a worker there so it stays Active, but its allocations go.

-- The screen itself. Anyone listed here for AUG-2026 with no live allocation is
-- a row the manager should not be seeing; this must come back empty.
COLUMN project_number FORMAT A12
COLUMN employee_id FORMAT A10
SELECT m.project_number, m.employee_id, m.employee_name, m.total_hours
  FROM v_oc_ts_month_summary m
 WHERE m.period_year = 2026 AND m.period_month = 8
   AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al
                    WHERE al.project_id  = m.project_id
                      AND al.employee_id = m.employee_id
                      AND al.status      = 'Active')
 ORDER BY m.project_number, m.employee_id;

PROMPT
PROMPT Rows above, if any, carry real or audited time and were kept on purpose.
PROMPT Check the hours before removing any of them by hand.
PROMPT
PROMPT V_OC_TS_MGR_PROJECTS and V_OC_TS_MONTH_SUMMARY both read live, so the
PROMPT manager screen corrects itself on the next load. No republish needed.
