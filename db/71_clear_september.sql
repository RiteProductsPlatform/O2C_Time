--==============================================================
-- time/71_clear_september.sql
-- O2C Timesheet Module — clearing September without touching the trail
--
-- Two attempts at this failed with the same ORA-20026, and both times I fixed
-- the wrong half. The audit table is anchored on the WEEK, not the entry:
--
--     OC_TS_AUDIT.TS_ENTRY_ID   NUMBER            -- nullable, NO foreign key
--     OC_TS_AUDIT.TS_WEEK_ID    NUMBER NOT NULL
--       CONSTRAINT fk_oc_tsau_week REFERENCES oc_ts_week ON DELETE CASCADE
--
-- So deleting an ENTRY cascades nowhere, and deleting a WEEK deletes its audit
-- rows -- which TRG_OC_TS_AUDIT_APPEND_ONLY exists to refuse. Both failures
-- were the week delete; db/70's NOT EXISTS on a.ts_entry_id guarded the
-- statement that was never blocked and left the one that was.
--
-- AND THE WEEK DELETE WAS NEVER NEEDED. populate's guard is per CELL --
--
--     NOT EXISTS (... ts_week_id = v_week AND project_id = ... AND
--                     task_id = ... AND entry_date = ...)
--
-- -- and ensure_week reuses a week that already exists. So an empty week is
-- refilled exactly like a missing one, and removing the entries is the whole
-- job. Two scripts spent effort deleting something that only ever stood in the
-- way of itself.
--
-- Entries that DO carry an audit row are still kept. There is no FK to enforce
-- it, so deleting them would leave OC_TS_AUDIT.TS_ENTRY_ID pointing at nothing
-- -- a trail that reads fine and resolves to no row, which is worse than a few
-- cells the monthly job will skip.
--
-- Idempotent. Depends on: time/03, 04.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TS_ENTRY';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] What SEP-2026 holds, and what carries a trail
PROMPT ============================================================

SELECT COUNT(*) AS entries,
       SUM(CASE WHEN EXISTS (SELECT 1 FROM oc_ts_audit a
                              WHERE a.ts_entry_id = e.ts_entry_id)
                THEN 1 ELSE 0 END) AS with_audit,
       COUNT(DISTINCT e.ts_week_id) AS weeks,
       NVL(SUM(e.hours),0) AS hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_period p ON p.period_id = w.period_id
 WHERE p.period_name = 'SEP-2026';

PROMPT
PROMPT WITH_AUDIT rows stay. They are the September entries db/62 realigned, and
PROMPT their trail has no foreign key holding it to them.

PROMPT ============================================================
PROMPT [2/3] Remove the prepopulated entries
PROMPT ============================================================

-- ENTRIES ONLY. The week rows stay: they cascade the audit trail and they cost
-- nothing, because ensure_week reuses them and populate fills by cell.
--
-- Also left alone: anything somebody acted on. A submitted or approved
-- September week should not exist, and if one does it is real work.
DECLARE
  v_period NUMBER;
  v_e NUMBER := 0;
BEGIN
  SELECT period_id INTO v_period
    FROM oc_time_period WHERE period_name = 'SEP-2026';

  DELETE FROM oc_ts_entry e
   WHERE e.ts_week_id IN (
           SELECT w.ts_week_id FROM oc_ts_week w
            WHERE w.period_id = v_period
              AND NVL(w.submission_status,'NotYetSubmitted') = 'NotYetSubmitted'
              AND NVL(w.approval_status,'Pending')           = 'Pending')
     AND NOT EXISTS (SELECT 1 FROM oc_ts_audit a
                      WHERE a.ts_entry_id = e.ts_entry_id);
  v_e := SQL%ROWCOUNT;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE(v_e || ' September entry row(s) removed');
  DBMS_OUTPUT.PUT_LINE('Week rows deliberately kept - populate fills by cell '
                    || 'and reuses the week.');
EXCEPTION WHEN NO_DATA_FOUND THEN
  DBMS_OUTPUT.PUT_LINE('No SEP-2026 period; nothing to clear.');
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification
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
PROMPT SEP-2026 should now show its weeks with few or no entries. The weeks
PROMPT remaining is correct and is not a failure to clear.
PROMPT
PROMPT NEXT
PROMPT   1. re-run the ALLOCATIONS sync   - writes a real FUSION_SYNCED_ON, after
PROMPT      which oc_time_retire_unsynced_allocations stops refusing
PROMPT   2. POST /oc/time/admin/jobs/populate/47   (JUN)
PROMPT   3. POST /oc/time/admin/jobs/populate/43   (JUL)
PROMPT   4. 62_realign_alloc_hours.sql
PROMPT   5. leave SEP for the monthly job
