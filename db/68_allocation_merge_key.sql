--==============================================================
-- time/68_allocation_merge_key.sql
-- O2C Timesheet Module — moving a start date created a second allocation
--
-- After the PPM rebuild every person has two rows per project:
--
--   RI2824   444 from 2026-07-30  AND  444 from 2026-08-17
--            555 from 2026-08-01  AND  555 from 2026-08-17
--            PCS10034 from 08-01  AND  PCS10034 from 08-14
--
-- Both Active, both counted. RI2824's August reads 326 hours against a
-- standard of ~168: the allocation percentage is applied twice on every
-- overlapping day, and the timesheet is right to do it -- it was told the
-- person holds two assignments.
--
-- THE MERGE KEY. oc_time_load_xml resolves the natural key from
-- USER_CONSTRAINTS when the config declares none, and OC_TIME_ALLOCATION's is
--
--     UK_OC_TAL_ASSIGN (PROJECT_ID, EMPLOYEE_ID, START_DATE)
--
-- so a changed start date is a key change, and the merge inserts rather than
-- updates. Which is exactly the reading the JSON handler in ords/13 already
-- rejects, in as many words:
--
--     "the extract already collapses each pair to ONE span, so matching on
--      the pair alone is right here: a changed start date is the same
--      assignment moving, not a second one."
--
-- That handler is correct and unused. OIC posts XML to /sync/load/{report},
-- never the JSON endpoint, so the careful comment guarded a path nothing takes
-- and the path everything takes had no such reasoning applied to it. Worth
-- remembering: two loaders for one table, and only one of them is live.
--
-- MERGE_KEY = 'PROJECT_ID,EMPLOYEE_ID' declares the pair and the discovery
-- fallback is skipped. TASKS already does this ('PROJECT_ID,TASK_CODE'), so
-- the mechanism is proven; ALLOCATIONS simply never had it set.
--
-- ORDER MATTERS. The duplicates must go BEFORE the key changes: a MERGE whose
-- ON clause matches two target rows raises ORA-30926 rather than choosing, so
-- with duplicates present the corrected key makes every allocation load fail.
--
-- Idempotent. Depends on: time/02, 16. Re-run the ALLOCATIONS sync afterwards.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_SYNC_CONFIG';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'OC_TIME_SYNC_CONFIG is missing. Run 16.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] How many people hold the same project twice
PROMPT ============================================================

COLUMN employee_id FORMAT A12
COLUMN project_number FORMAT A12
COLUMN starts FORMAT A40
SELECT w.employee_id, p.project_number,
       COUNT(*) AS rows_,
       SUM(a.alloc_pct) AS pct_total,
       LISTAGG(TO_CHAR(a.start_date,'DD-Mon'), ' + ')
         WITHIN GROUP (ORDER BY a.start_date) AS starts
  FROM oc_time_allocation a
  JOIN oc_time_worker  w ON w.employee_id = a.employee_id
  JOIN oc_time_project p ON p.project_id  = a.project_id
 WHERE a.status = 'Active'
 GROUP BY w.employee_id, p.project_number
HAVING COUNT(*) > 1
 ORDER BY COUNT(*) DESC, w.employee_id
 FETCH FIRST 25 ROWS ONLY;

SELECT COUNT(*) AS duplicated_pairs,
       SUM(n) - COUNT(*) AS surplus_rows
  FROM (SELECT COUNT(*) AS n FROM oc_time_allocation
         WHERE status = 'Active'
         GROUP BY project_id, employee_id
        HAVING COUNT(*) > 1);

PROMPT ============================================================
PROMPT [2/4] Keep one row per person per project
PROMPT ============================================================

-- The most recently SYNCED row survives: it is the one the last load touched,
-- so it carries the current percentage and billing status. Its START_DATE may
-- be wrong -- the feed sends MIN(party start) and the survivor may hold a
-- later one -- and the re-sync corrects it, which is the whole point of fixing
-- the key first.
--
-- DELETE, not 'Ended'. An end date would leave the row Active-until-then and
-- still overlapping the days it must not count for; and nothing references
-- OC_TIME_ALLOCATION, so there is no history to preserve here. The row was
-- never a real second assignment -- it is one assignment recorded twice.
DECLARE
  v_n NUMBER := 0;
BEGIN
  DELETE FROM oc_time_allocation a
   WHERE a.allocation_id NOT IN (
           SELECT MAX(b.allocation_id) KEEP (DENSE_RANK LAST
                    ORDER BY b.fusion_synced_on NULLS FIRST, b.allocation_id)
             FROM oc_time_allocation b
            WHERE b.project_id  = a.project_id
              AND b.employee_id = a.employee_id);
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' surplus allocation row(s) removed');
END;
/

PROMPT ============================================================
PROMPT [3/4] Declare the merge key so it cannot happen again
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_sync_config
     SET merge_key = 'PROJECT_ID,EMPLOYEE_ID',
         updated_by = 'ALLOC_MERGE_KEY',
         updated_on = SYSTIMESTAMP
   WHERE bip_report_name = 'ALLOCATIONS'
     AND NVL(merge_key,'~') <> 'PROJECT_ID,EMPLOYEE_ID';
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n > 0 THEN 'MERGE_KEY set for ALLOCATIONS'
                            ELSE 'MERGE_KEY already correct' END);
END;
/

COLUMN bip_report_name FORMAT A16
COLUMN merge_key FORMAT A34
SELECT bip_report_name, NVL(merge_key,'(discovered from constraints)') AS merge_key,
       target_table
  FROM oc_time_sync_config
 ORDER BY run_order;

PROMPT
PROMPT A report with no MERGE_KEY falls back to the table's own unique
PROMPT constraint. That is right where the constraint IS the feed's grain, and
PROMPT wrong wherever the feed collapses several source rows into one -- which
PROMPT is worth checking for any feed added later.

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

SELECT COUNT(*) AS pairs_still_duplicated
  FROM (SELECT 1 FROM oc_time_allocation WHERE status = 'Active'
         GROUP BY project_id, employee_id HAVING COUNT(*) > 1);

PROMPT
PROMPT --- allocation now totalled per person, which should not exceed 100
COLUMN employee_id FORMAT A12
SELECT w.employee_id, SUM(a.alloc_pct) AS total_pct, COUNT(*) AS projects
  FROM oc_time_allocation a
  JOIN oc_time_worker w ON w.employee_id = a.employee_id
 WHERE a.status = 'Active'
   AND w.employee_id IN ('RI2824','RI2894','RI9001','RI2249','RI2900','RI2935',
                         'RI2963','RI2985','RI3004','CRI0398','CRI0406','RI2914')
 GROUP BY w.employee_id
 ORDER BY 2 DESC;

PROMPT
PROMPT Over 100 here is now PPM's answer rather than a duplicate, and belongs in
PROMPT check_ppm_gaps.py finding 3.
PROMPT
PROMPT NEXT: re-run the ALLOCATIONS sync, then 62 to realign the hours the
PROMPT duplicates inflated.
