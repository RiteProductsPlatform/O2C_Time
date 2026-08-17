--==============================================================
-- time/70_undo_bad_retire.sql
-- O2C Timesheet Module — undoing a retirement that should never have run
--
-- 69's generic pass retired 15 allocations and reported
--
--     "15 allocation(s) retired: absent from the load of 03-Aug-26."
--
-- 03-Aug was two weeks ago. FUSION_SYNCED_ON had not been written since, because
-- the feed only began sending it in the same commit that added the procedure --
-- and the sync had not run yet. So "not stamped by the latest load" meant "not
-- touched in a fortnight", which is not the same thing at all, and seven of the
-- twelve cohort members lost every allocation they had.
--
-- THE GUARD WAS THE WRONG SHAPE. It checked the PROPORTION -- refuse if more
-- than a fifth look stale -- and 15 of ~550 passed comfortably. What it never
-- checked was whether the newest stamp was RECENT ENOUGH TO MEAN ANYTHING. A
-- stamp from two weeks ago cannot be evidence about a load that has not
-- happened, at any proportion. Both tests are needed and only one was written.
--
-- Reversible precisely because the procedure stamped its own name:
-- UPDATED_BY = 'SETUP_RUN' identifies every row it touched and nothing else.
-- That is the only reason this is a clean undo rather than a restore from the
-- allocation feed, and it is worth doing on any procedure that ends rows in
-- bulk.
--
-- Also finishes what 69's section [3] could not: clearing SEP-2026 raised
-- ORA-20026 from TRG_OC_TS_AUDIT_APPEND_ONLY. OC_TS_AUDIT cascades from
-- OC_TS_ENTRY, and db/62 had just written audit rows against September when it
-- realigned those hours -- so deleting the entries tried to delete the trail
-- with them, which the trigger exists to refuse. See [3].
--
-- Idempotent. Depends on: time/69.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_RETIRE_UNSYNCED_ALLOCATIONS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Run 69_stale_allocations_and_september.sql first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] Put back what SETUP_RUN ended
PROMPT ============================================================

-- END_DATE is cleared as well as the status. The procedure set it to yesterday
-- so the row would stop counting today; leaving that behind would reinstate an
-- allocation that expires immediately, which looks Active and behaves Ended --
-- the worst of both.
--
-- NOT the seven from section [1] of 69: those carry UPDATED_BY = 'PPM_DELETED'
-- and are genuinely gone from PPM. Only SETUP_RUN's are undone.
DECLARE
  v_n NUMBER := 0;
BEGIN
  UPDATE oc_time_allocation
     SET status     = 'Active',
         end_date   = NULL,
         updated_by = 'UNDO_BAD_RETIRE',
         updated_on = SYSTIMESTAMP
   WHERE status     = 'Ended'
     AND updated_by = 'SETUP_RUN';
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' allocation(s) reinstated');
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Nothing to undo - either already run, or 69''s '
                      || 'generic pass retired nothing here.');
  END IF;
END;
/

COLUMN employee_id FORMAT A12
SELECT w.employee_id, SUM(a.alloc_pct) AS total_pct, COUNT(*) AS projects
  FROM oc_time_allocation a
  JOIN oc_time_worker w ON w.employee_id = a.employee_id
 WHERE a.status = 'Active'
   AND w.employee_id IN ('RI2824','RI2894','RI9001','RI2249','RI2900','RI2935',
                         'RI2963','RI2985','RI3004','CRI0398','CRI0406','RI2914')
 GROUP BY w.employee_id
 ORDER BY w.employee_id;

PROMPT
PROMPT Every cohort member should hold an allocation again, and RI2985 should
PROMPT hold none -- theirs was ended by PPM_DELETED, which was correct.

PROMPT ============================================================
PROMPT [2/4] The guard the procedure was missing
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_retire_unsynced_allocations(
  p_actor    IN  VARCHAR2 DEFAULT 'SYNC_RETIRE',
  o_ended    OUT NUMBER,
  o_message  OUT VARCHAR2)
IS
  v_latest DATE;
  v_active NUMBER;
  v_stale  NUMBER;
  -- How old the newest stamp may be and still describe "the latest load". A
  -- retirement is only ever run right after a sync, so anything beyond a couple
  -- of days is not the load being reasoned about.
  c_max_age CONSTANT NUMBER := 2;
BEGIN
  o_ended := 0;

  SELECT MAX(TRUNC(fusion_synced_on)) INTO v_latest FROM oc_time_allocation;
  IF v_latest IS NULL THEN
    o_message := 'No allocation carries FUSION_SYNCED_ON yet; run a full '
              || 'ALLOCATIONS load first. Nothing retired.';
    RETURN;
  END IF;

  -- THE TEST THAT WAS MISSING, and the one that mattered. The first version
  -- checked only the proportion, so a stamp from 03-Aug-2026 -- written before
  -- the feed carried the column at all -- was treated as "the latest load" and
  -- 15 live allocations were ended on the strength of it. A stamp that predates
  -- the run cannot be evidence about it, whatever fraction agrees.
  IF TRUNC(SYSDATE) - v_latest > c_max_age THEN
    o_message := 'The newest FUSION_SYNCED_ON is ' || TO_CHAR(v_latest,'DD-Mon-YY')
              || ', ' || (TRUNC(SYSDATE) - v_latest) || ' days old. That is not '
              || 'a load that just ran, so absence from it proves nothing. '
              || 'Nothing retired -- re-run ALLOCATIONS with LASTSYNC_DATE NULL '
              || 'and call this again.';
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
  oc_time_retire_unsynced_allocations('GUARD_CHECK', v_n, v_msg);
  DBMS_OUTPUT.PUT_LINE(v_msg);
END;
/

PROMPT
PROMPT It should now REFUSE, naming the stamp's age. That is the fix working:
PROMPT the stamp is still 03-Aug until a full ALLOCATIONS load has run.

PROMPT ============================================================
PROMPT [3/4] Clear SEP-2026, trail intact
PROMPT ============================================================

-- OC_TS_AUDIT cascades from OC_TS_ENTRY, and TRG_OC_TS_AUDIT_APPEND_ONLY
-- refuses the DELETE the cascade attempts. That trigger is right and stays:
-- the trail's whole value is that it cannot be rewritten.
--
-- So the ENTRIES ARE NOT DELETED. Their hours go to zero and the week goes
-- with them, which leaves the audit rows pointing at rows that still exist and
-- still say what happened.
--
-- Does that let the monthly job rebuild September? Yes -- populate's guard is
-- NOT EXISTS a row for the cell, so a zeroed row would still block it. Hence
-- the week rows go, and OC_TS_ENTRY cascades on OC_TS_WEEK... which is the same
-- problem again.
--
-- The honest answer is that September's PREPOPULATED rows can be deleted and
-- its AUDITED ones cannot, so only the first are removed. db/62 wrote audit
-- rows against exactly the September entries it realigned, and those keep both
-- their row and their trail. A handful of cells the monthly job will skip is a
-- far better outcome than a trail with holes in it.
DECLARE
  v_period NUMBER;
  v_kept   NUMBER := 0;
  v_e      NUMBER := 0;
  v_w      NUMBER := 0;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period WHERE period_name = 'SEP-2026';

  SELECT COUNT(*) INTO v_kept
    FROM oc_ts_entry e
    JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
   WHERE w.period_id = v_period
     AND EXISTS (SELECT 1 FROM oc_ts_audit a WHERE a.ts_entry_id = e.ts_entry_id);

  DELETE FROM oc_ts_entry e
   WHERE e.ts_week_id IN (SELECT ts_week_id FROM oc_ts_week
                           WHERE period_id = v_period)
     AND NOT EXISTS (SELECT 1 FROM oc_ts_audit a
                      WHERE a.ts_entry_id = e.ts_entry_id);
  v_e := SQL%ROWCOUNT;

  -- Only weeks that are now empty AND that nobody has acted on.
  DELETE FROM oc_ts_week w
   WHERE w.period_id = v_period
     AND NVL(w.submission_status,'NotYetSubmitted') = 'NotYetSubmitted'
     AND NVL(w.approval_status,'Pending')           = 'Pending'
     AND NOT EXISTS (SELECT 1 FROM oc_ts_entry e WHERE e.ts_week_id = w.ts_week_id);
  v_w := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_e || ' entry row(s) and ' || v_w || ' week row(s) removed');
  DBMS_OUTPUT.PUT_LINE(v_kept || ' entry row(s) kept because they carry an audit trail');
EXCEPTION WHEN NO_DATA_FOUND THEN
  DBMS_OUTPUT.PUT_LINE('No SEP-2026 period; nothing to clear.');
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
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
PROMPT SEP-2026 near zero is the aim; whatever remains carries an audit trail
PROMPT and is deliberately kept.
