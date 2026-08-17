--==============================================================
-- time/69_stale_allocations_and_september.sql
-- O2C Timesheet Module — retire what PPM deleted, and clear September
--
-- TWO JOBS, both cleaning up after a sync that could not know better.
--
-- ── 1. PPM DELETES, IT DOES NOT END-DATE ────────────────────────────────
--
-- oc_time_expire_allocations carries the assumption in its own comment:
--
--     "PPM end-dates an assignment when somebody is taken off a project;
--      it does not delete it, and neither do we."
--
-- Measured against the pod 18-Aug-2026, that is false. RI2894 is a party on
-- 555 alone; the cache also holds Active 444 and PCS10034 rows for them with
-- no end date. There is nothing in PJF_PROJECT_PARTIES to end-date -- the rows
-- are gone. Seven such allocations across the cohort:
--
--     RI2824  666        RI2894  444, PCS10034     RI9001  666
--     RI2900  444        RI2249  555               RI2985  444
--
-- and they are what puts four people above 100%: RI2900 at 200, RI2824,
-- RI2894 and RI9001 at 150. Every one of those inflates the working day.
--
-- WHY THE LIST IS LITERAL. Retiring "what the feed no longer contains" needs
-- the database to know what the feed contained, and it could not: the XML
-- loader writes neither SYNC_JOB_RUN_ID (its own c_never list excludes it) nor
-- FUSION_SYNCED_ON (the feed never sent it). So the seven are named here, from
-- a live comparison, and the extract now stamps FUSION_SYNCED_ON so the NEXT
-- one is detectable without anybody diffing by hand -- section [2] below is the
-- generic pass, and it is deliberately inert until a full load has run.
--
-- ── 2. SEPTEMBER IS ALREADY BUILT ───────────────────────────────────────
--
-- SEP-2026 holds five weeks and 176 hours for RI2824 alone. The monthly job is
-- meant to build it a day or two before August ends, and populate skips a cell
-- that already has a row -- so with September seeded the job would run, report
-- success, and change nothing. Cleared so the demonstration is real.
--
-- OCT-2026 is left alone: nothing has populated it and there is nothing to
-- clear.
--
-- Idempotent. Depends on: time/02, 03.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_ALLOCATION';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] Retire the seven PPM no longer has
PROMPT ============================================================

-- 'Ended', not deleted. These WERE real assignments -- somebody worked under
-- them and there may be approved hours against them - so the row stays and
-- stops being current. CHK_OC_TAL_STATUS admits ('Active','Ended') only.
DECLARE
  TYPE t_pair IS RECORD (emp VARCHAR2(50), proj VARCHAR2(60));
  TYPE t_tab  IS TABLE OF t_pair;
  v t_tab := t_tab();
  v_n NUMBER := 0;

  PROCEDURE add(p_emp VARCHAR2, p_proj VARCHAR2) IS
  BEGIN
    v.EXTEND; v(v.COUNT).emp := p_emp; v(v.COUNT).proj := p_proj;
  END add;
BEGIN
  add('RI2824', '666');
  add('RI9001', '666');
  add('RI2894', '444');
  add('RI2894', 'PCS10034');
  add('RI2900', '444');
  add('RI2249', '555');
  add('RI2985', '444');

  FOR i IN 1 .. v.COUNT LOOP
    UPDATE oc_time_allocation a
       SET a.status     = 'Ended',
           -- Yesterday, so it is not current for today either. Ending it
           -- "today" would leave it counting for the day the script ran.
           a.end_date   = NVL(a.end_date, TRUNC(SYSDATE) - 1),
           a.updated_by = 'PPM_DELETED',
           a.updated_on = SYSTIMESTAMP
     WHERE a.status      = 'Active'
       AND a.employee_id = v(i).emp
       AND a.project_id  = (SELECT project_id FROM oc_time_project
                             WHERE project_number = v(i).proj);
    IF SQL%ROWCOUNT > 0 THEN
      v_n := v_n + SQL%ROWCOUNT;
      DBMS_OUTPUT.PUT_LINE('ended  ' || RPAD(v(i).emp, 9) || v(i).proj);
    END IF;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE(v_n || ' stale allocation(s) ended');
END;
/

PROMPT ============================================================
PROMPT [2/5] The generic pass, for next time
PROMPT ============================================================

-- Retires every Active allocation the last FULL load did not stamp. Inert
-- until the ALLOCATIONS feed has run once carrying FUSION_SYNCED_ON, which it
-- now sends.
--
-- THE GUARD IS THE POINT. An INCREMENTAL load stamps only what changed, so
-- this would see almost everything as deleted. Rather than trust the caller to
-- remember, it measures: if more than a fifth of Active allocations look
-- stale, that is a partial load and it refuses, reporting instead. A real set
-- of deletions is a handful; a partial load is nearly all of them, and the two
-- are trivially far apart.
CREATE OR REPLACE PROCEDURE oc_time_retire_unsynced_allocations(
  p_actor    IN  VARCHAR2 DEFAULT 'SYNC_RETIRE',
  o_ended    OUT NUMBER,
  o_message  OUT VARCHAR2)
IS
  v_latest DATE;
  v_active NUMBER;
  v_stale  NUMBER;
BEGIN
  o_ended := 0;

  SELECT MAX(TRUNC(fusion_synced_on)) INTO v_latest FROM oc_time_allocation;
  IF v_latest IS NULL THEN
    o_message := 'No allocation carries FUSION_SYNCED_ON yet; run a full '
              || 'ALLOCATIONS load first. Nothing retired.';
    RETURN;
  END IF;

  SELECT COUNT(*),
         SUM(CASE WHEN NVL(TRUNC(fusion_synced_on), DATE '1900-01-01') < v_latest
                  THEN 1 ELSE 0 END)
    INTO v_active, v_stale
    FROM oc_time_allocation WHERE status = 'Active';

  IF v_stale = 0 THEN
    o_message := 'Every Active allocation was stamped by the latest load.';
    RETURN;
  END IF;

  IF v_stale > v_active / 5 THEN
    o_message := v_stale || ' of ' || v_active || ' Active allocations were not '
              || 'stamped on ' || TO_CHAR(v_latest,'DD-Mon-YY') || '. That is '
              || 'too many to be deletions -- it reads as a partial load. '
              || 'Nothing retired; re-run ALLOCATIONS with LASTSYNC_DATE NULL.';
    RETURN;
  END IF;

  UPDATE oc_time_allocation
     SET status     = 'Ended',
         end_date   = NVL(end_date, TRUNC(SYSDATE) - 1),
         updated_by = p_actor,
         updated_on = SYSTIMESTAMP
   WHERE status = 'Active'
     AND NVL(TRUNC(fusion_synced_on), DATE '1900-01-01') < v_latest;
  o_ended := SQL%ROWCOUNT;
  COMMIT;
  o_message := o_ended || ' allocation(s) retired: absent from the load of '
            || TO_CHAR(v_latest,'DD-Mon-YY') || '.';
END oc_time_retire_unsynced_allocations;
/
SHOW ERRORS

DECLARE
  v_n NUMBER; v_msg VARCHAR2(400);
BEGIN
  oc_time_retire_unsynced_allocations('SETUP_RUN', v_n, v_msg);
  DBMS_OUTPUT.PUT_LINE(v_msg);
END;
/

PROMPT ============================================================
PROMPT [3/5] Clear September so the monthly job can build it
PROMPT ============================================================

DECLARE
  v_period NUMBER;
  v_e NUMBER := 0; v_w NUMBER := 0;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period WHERE period_name = 'SEP-2026';

  -- Entries first, then the weeks. OC_TS_ENTRY cascades on the week, but
  -- deleting the parent to remove the child hides how much went.
  DELETE FROM oc_ts_entry e
   WHERE e.ts_week_id IN (SELECT ts_week_id FROM oc_ts_week
                           WHERE period_id = v_period);
  v_e := SQL%ROWCOUNT;

  -- Only weeks nobody has acted on. A submitted or approved September week
  -- would be somebody's work and a decision somebody made; there should be
  -- none, and if there is, it stays and is reported in [4].
  DELETE FROM oc_ts_week w
   WHERE w.period_id = v_period
     AND NVL(w.submission_status,'NotYetSubmitted') = 'NotYetSubmitted'
     AND NVL(w.approval_status,'Pending')           = 'Pending';
  v_w := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_e || ' entry row(s) and ' || v_w
                       || ' week row(s) removed from SEP-2026');
EXCEPTION WHEN NO_DATA_FOUND THEN
  DBMS_OUTPUT.PUT_LINE('No SEP-2026 period; nothing to clear.');
END;
/

PROMPT ============================================================
PROMPT [4/5] Verification
PROMPT ============================================================

COLUMN period_name FORMAT A11
SELECT p.period_name, p.status,
       COUNT(DISTINCT w.ts_week_id) AS weeks,
       COUNT(e.ts_entry_id)         AS entries,
       NVL(SUM(e.hours),0)          AS hours
  FROM oc_time_period p
  LEFT JOIN oc_ts_week  w ON w.period_id  = p.period_id
  LEFT JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
 GROUP BY p.period_name, p.status, p.start_date
 ORDER BY p.start_date;

PROMPT
PROMPT SEP-2026 should read zero. JUN and JUL will fill on the next population
PROMPT now that the allocations reach back to 01-Jan and 01-Jul.

PROMPT
PROMPT --- and the cohort's allocation, which should now stop at 100
COLUMN employee_id FORMAT A12
SELECT w.employee_id, SUM(a.alloc_pct) AS total_pct, COUNT(*) AS projects
  FROM oc_time_allocation a
  JOIN oc_time_worker w ON w.employee_id = a.employee_id
 WHERE a.status = 'Active'
   AND w.employee_id IN ('RI2824','RI2894','RI9001','RI2249','RI2900','RI2935',
                         'RI2963','RI2985','RI3004','CRI0398','CRI0406','RI2914')
 GROUP BY w.employee_id
 ORDER BY 2 DESC;

PROMPT ============================================================
PROMPT [5/5] Next
PROMPT ============================================================
PROMPT
PROMPT   1. POST /oc/time/admin/jobs/populate/{periodId} for JUN and JUL
PROMPT   2. then 62_realign_alloc_hours.sql, so the days match the allocation
PROMPT   3. leave SEP alone -- the monthly job builds it near month end, which
PROMPT      is the thing being demonstrated
PROMPT
PROMPT RI2985 now holds no allocation at all and will derive to ROLE_TIME_NONE.
PROMPT That is correct if they are meant to be the empty-menu case, and a PPM
PROMPT correction if not.
