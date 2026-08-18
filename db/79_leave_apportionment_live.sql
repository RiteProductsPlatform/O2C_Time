--==============================================================
-- time/79_leave_apportionment_live.sql
-- O2C Timesheet Module — the live absence loop had its own MIN(project_id)
--
-- db/09 taught populate_month to split a day's leave across the allocations by
-- ALLOC_PCT. That fixed the MONTHLY job and nothing else, because the live
-- browser loop does not go through populate_month at all:
--
--   PAGE-001 load -> refreshAbsenceChain -> POST sync/absence
--                 -> oc_time_sync_leave  (db/44)
--
-- and oc_time_sync_leave carries its OWN copy of the rule, twice. Left alone it
-- does not merely fail to apportion -- it actively undoes it. The retract half
-- decides a leave row is a stale duplicate when it is not on MIN(project_id):
--
--     AND e.project_id = (SELECT MIN(al.project_id) FROM oc_time_allocation al
--                          WHERE al.employee_id = w.employee_id
--                            AND al.status = 'Active')
--
-- With RI2824's day now split 4h/2h/2h across 444, 555 and PCS10034, the 555
-- and PCS10034 rows fail that test, read as stale, and are DELETED -- with an
-- audit row apiece saying the leave was withdrawn, which nobody did. The next
-- page load would have silently put the whole day back on 444 and left a trail
-- claiming a withdrawal. Found before testing, not after.
--
-- Same lesson as the sync-handler drift already in CLAUDE.md: check the whole
-- surface, not the handler in front of you. Two producers, one rule, and the
-- rule was written down twice.
--
-- THE RULE, now in one place. OC_TIME_LEAVE_SHARE returns the apportioned
-- hours per project for one employee-day, so populate_month, oc_time_sync_leave
-- and anything later cannot drift again. It is a pipelined-free plain view
-- function returning a cursor-friendly collection, because the callers need it
-- in a FOR loop and in a NOT EXISTS.
--
-- WHAT MATCHES db/09 EXACTLY, because a difference here is a difference in the
-- numbers depending on which producer ran last:
--   * allocations covering the ABSENCE DATE, not merely Active today
--   * divided by the allocations' own SUM, not by 100
--   * the rounding remainder to the last row, so the shares sum exactly
--   * aggregated per DAY -- two absence types on one date are two rows in
--     OC_TIME_ABSENCE but one cell per project in OC_TS_ENTRY
--
-- Idempotent. Depends on: time/03, 09, 44.
-- RUN db/09 FIRST -- this assumes populate_month already apportions.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_SYNC_LEAVE' AND object_type = 'PROCEDURE';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'OC_TIME_SYNC_LEAVE does not exist here. '
      || 'Run db/44_leave_and_allocation_retraction.sql first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] V_OC_TS_LEAVE_SHARE — the split, defined once
PROMPT ============================================================

-- One row per employee per absence date per project, with the hours that
-- project should carry. Every consumer reads this instead of restating the
-- rule; that is the whole point of it existing.
--
-- The remainder is given to the LAST project by ordering deterministically and
-- comparing the running total to the day total. Deterministic ordering matters
-- more than which row wins: an ORDER BY that can tie differently between two
-- runs would move a cent-hour between projects on every sync, and every move
-- is an UPDATE that the audit trigger records as a change nobody made.
CREATE OR REPLACE VIEW v_oc_ts_leave_share AS
WITH day_abs AS (
  SELECT ab.employee_id, ab.absence_date,
         SUM(ab.absence_hours) AS absence_hours,
         MAX(ab.absence_type) KEEP (DENSE_RANK FIRST
             ORDER BY ab.absence_hours DESC) AS absence_type
    FROM oc_time_absence ab
   WHERE ab.approval_status = 'Approved'
   GROUP BY ab.employee_id, ab.absence_date
),
alloc AS (
  SELECT d.employee_id, d.absence_date, d.absence_hours, d.absence_type,
         al.project_id, al.alloc_pct,
         SUM(al.alloc_pct) OVER (PARTITION BY d.employee_id, d.absence_date)
           AS pct_total,
         ROW_NUMBER() OVER (PARTITION BY d.employee_id, d.absence_date
                            ORDER BY al.alloc_pct DESC, al.project_id) AS seq,
         COUNT(*)     OVER (PARTITION BY d.employee_id, d.absence_date) AS n
    FROM day_abs d
    JOIN oc_time_allocation al
      ON al.employee_id = d.employee_id
     AND al.status      = 'Active'
     AND d.absence_date BETWEEN al.start_date
                        AND NVL(al.end_date, d.absence_date)
),
shared AS (
  SELECT a.*,
         ROUND(a.absence_hours * a.alloc_pct / NULLIF(a.pct_total,0), 2) AS raw_share,
         SUM(ROUND(a.absence_hours * a.alloc_pct / NULLIF(a.pct_total,0), 2))
             OVER (PARTITION BY a.employee_id, a.absence_date
                   ORDER BY a.seq ROWS BETWEEN UNBOUNDED PRECEDING
                                           AND 1 PRECEDING) AS prior_sum
    FROM alloc a
)
SELECT employee_id, absence_date, absence_type, project_id, alloc_pct,
       pct_total, seq, n, absence_hours AS day_hours,
       CASE WHEN seq = n
            -- the last row absorbs the rounding residue
            THEN absence_hours - NVL(prior_sum, 0)
            ELSE raw_share END AS share_hours
  FROM shared;

PROMPT ============================================================
PROMPT [2/4] Proof the shares sum to the day, before anything uses it
PROMPT ============================================================

COLUMN employee_id FORMAT A12
SELECT employee_id, TO_CHAR(absence_date,'DD-Mon-YY') AS absence_date,
       MAX(day_hours) AS day_hours, SUM(share_hours) AS split_total,
       COUNT(*) AS projects,
       CASE WHEN SUM(share_hours) = MAX(day_hours) THEN 'exact'
            ELSE 'MISMATCH' END AS check_result
  FROM v_oc_ts_leave_share
 GROUP BY employee_id, absence_date
HAVING SUM(share_hours) <> MAX(day_hours)
 ORDER BY 1, 2;

PROMPT
PROMPT No rows above means every split sums exactly to its day. Any MISMATCH is
PROMPT the rounding remainder failing, and nothing below should be run.

PROMPT ============================================================
PROMPT [3/4] OC_TIME_SYNC_LEAVE — reading the shared rule
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_sync_leave(
  p_from        IN DATE,
  p_to          IN DATE,
  p_employee_id IN VARCHAR2 DEFAULT NULL,
  p_actor       IN VARCHAR2 DEFAULT 'ABSENCE_SYNC')
IS
  v_task    NUMBER;
  v_week    NUMBER;
  v_added   NUMBER := 0;
  v_pulled  NUMBER := 0;
  v_unappr  NUMBER := 0;
  v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
BEGIN
  SELECT task_id INTO v_task
    FROM oc_time_task
   WHERE task_type = 'COMMON' AND UPPER(task_code) = 'LEAVE';

  -- ── RETRACT ────────────────────────────────────────────────
  -- A leave row with no share behind it. Two causes, handled identically: the
  -- absence was withdrawn, or the split moved and this project is no longer in
  -- it. The test used to be "is this row on MIN(project_id)" -- which, once the
  -- day is legitimately spread over three projects, condemns two of them.
  FOR e IN (
    SELECT e.ts_entry_id, e.ts_week_id, e.entry_date, e.project_id, e.task_id,
           e.hours, e.absence_type, w.employee_id, w.period_id,
           w.approval_status
      FROM oc_ts_entry e
      JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
     WHERE e.is_leave = 'Y'
       AND e.entry_date BETWEEN p_from AND p_to
       AND (p_employee_id IS NULL OR w.employee_id = p_employee_id)
       AND NOT EXISTS (
             SELECT 1 FROM v_oc_ts_leave_share ls
              WHERE ls.employee_id  = w.employee_id
                AND ls.absence_date = e.entry_date
                AND ls.project_id   = e.project_id)
  ) LOOP

    -- HISTORY FIRST. There is no DELETE trigger on OC_TS_ENTRY -- the audit
    -- triggers are BEFORE UPDATE OF -- so a deleted row would otherwise leave
    -- no trace at all. Written before the delete so the values are still here.
    INSERT INTO oc_ts_audit (
      ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
      old_project_id, old_task_id, old_hours, old_bill_type,
      new_project_id, new_task_id, new_hours,
      change_reason, changed_by, changed_on)
    VALUES (
      e.ts_entry_id, e.ts_week_id, e.employee_id, e.entry_date, 'AbsenceSync',
      e.project_id, e.task_id, e.hours, 'Non-billable',
      NULL, NULL, 0,
      'Leave no longer applies to this project ('
        || NVL(e.absence_type,'Leave') || '): the absence was withdrawn or the '
        || 'allocation split changed. Row removed by the sync.',
      p_actor, SYSTIMESTAMP);

    DELETE FROM oc_ts_entry WHERE ts_entry_id = e.ts_entry_id;
    v_pulled := v_pulled + 1;

    -- A DECIDED WEEK GOES BACK. The hours changed after the manager looked at
    -- them, which is precisely DailyChange -- confirmed 15-Aug that a withdrawn
    -- absence may un-approve a week. A Pending week needs no event: nobody has
    -- judged it yet, and firing one would only add noise to its version trail.
    IF e.approval_status <> 'Pending' THEN
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', p_actor, v_s, v_a, v_f);
        v_unappr := v_unappr + 1;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;

  -- ── APPLY ──────────────────────────────────────────────────
  -- One row per project per day, at its apportioned share. The retract above
  -- has already removed anything no longer in the split, so this cannot leave
  -- a second copy behind.
  FOR ls IN (
    SELECT ls.employee_id, ls.absence_date, ls.absence_type,
           ls.project_id, ls.share_hours
      FROM v_oc_ts_leave_share ls
     WHERE ls.absence_date BETWEEN p_from AND p_to
       AND (p_employee_id IS NULL OR ls.employee_id = p_employee_id)
  ) LOOP
    -- Resolved into a variable BEFORE the MERGE, never called inside it.
    -- ensure_week INSERTs a missing week, and a function that performs DML
    -- cannot be called from a SQL statement -- ORA-14551, raised at runtime
    -- rather than at compile time, so it would have passed every check here
    -- and failed on the first absence the sync tried to apply.
    v_week := oc_time_pkg.ensure_week(ls.employee_id, ls.absence_date, p_actor);

    MERGE INTO oc_ts_entry e
    USING (SELECT v_week AS wk, ls.project_id AS pid,
                  v_task AS tid, ls.absence_date AS d FROM dual) s
       ON (e.ts_week_id = s.wk AND e.project_id = s.pid
       AND e.task_id    = s.tid AND e.entry_date = s.d
       AND e.entry_type = 'Actual')
     WHEN MATCHED THEN UPDATE
          SET e.hours        = ls.share_hours,
              e.is_leave     = 'Y',
              e.absence_type = ls.absence_type,
              e.source       = 'Absence',
              e.updated_by   = p_actor
     WHEN NOT MATCHED THEN
          INSERT (ts_week_id, project_id, task_id, entry_date, hours,
                  entry_type, is_leave, absence_type, source,
                  billable_type, unbilled_reason, created_by)
          VALUES (s.wk, s.pid, s.tid, s.d, ls.share_hours,
                  'Actual', 'Y', ls.absence_type, 'Absence',
                  'Non-billable', 'Leave', p_actor);
    v_added := v_added + SQL%ROWCOUNT;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_pulled || ' leave row(s) retracted, '
    || v_unappr || ' decided week(s) sent back, '
    || v_added  || ' applied');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Re-split what is already there
PROMPT ============================================================

-- Existing leave rows were written by the old rule and all sit on one project.
-- Re-run over every period that has leave so the cache matches the rule; the
-- procedure is idempotent, so this is also the repair for any half-applied
-- state left by an earlier run.
DECLARE
  v_from DATE; v_to DATE;
BEGIN
  SELECT MIN(absence_date), MAX(absence_date) INTO v_from, v_to
    FROM oc_time_absence WHERE approval_status = 'Approved';
  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('  No approved absence; nothing to re-split.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  Re-splitting ' || TO_CHAR(v_from,'DD-Mon-YY')
                      || ' to ' || TO_CHAR(v_to,'DD-Mon-YY'));
    oc_time_sync_leave(v_from, v_to, NULL, 'APPORTION_79');
  END IF;
END;
/

COLUMN employee_name FORMAT A24
COLUMN project_number FORMAT A12
SELECT w.employee_id, wk.employee_name,
       TO_CHAR(e.entry_date,'DD-Mon-YY') AS entry_date,
       p.project_number, e.hours,
       SUM(e.hours) OVER (PARTITION BY w.employee_id, e.entry_date) AS day_total
  FROM oc_ts_entry e
  JOIN oc_ts_week      w  ON w.ts_week_id  = e.ts_week_id
  JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
  JOIN oc_time_project p  ON p.project_id  = e.project_id
 WHERE e.is_leave = 'Y'
   AND w.employee_id IN ('RI2824','RI2894','RI2900','RI9001','RI2249')
 ORDER BY w.employee_id, e.entry_date, p.project_number;

PROMPT
PROMPT RI2824 is 50/25/25 across 444, 555 and PCS10034, so a leave day should
PROMPT show three rows whose DAY_TOTAL equals their standard day.
PROMPT
PROMPT NOW SAFE TO TEST apply -> withdraw -> apply from Fusion.
