--==============================================================
-- time/63_unallocated_entries.sql
-- O2C Timesheet Module — remove rows seeded on days nobody was allocated
--
-- 62 realigned 131 rows and left 66 wrong, on purpose: it skips anything whose
-- expected hours resolve to ZERO, on the reasoning that zeroing a timesheet to
-- fix a lookup would destroy hours somebody worked. That caution was right in
-- general and wrong for this case, and the output said which:
--
--   RI2824  555        alloc_pct 0   holds 2   10 days
--   RI2824  PCS10034   alloc_pct 0   holds 8    4 days
--   7897    555        alloc_pct 0   holds 8   18 days
--
-- ALLOC_PCT = 0 there does not mean "allocated at zero". It means NO
-- ALLOCATION ROW COVERS THAT DATE. RI2824's 555 allocation starts 17-Aug and
-- these rows sit on 02-Aug onwards: days on a project they were not yet on.
--
-- THE CAUSE IS FIXED SEPARATELY, in db/09. populate's cursor asks whether an
-- allocation overlaps the PERIOD and its day loop then seeded every day of the
-- period, never testing the allocation's own span. A mid-month start seeded the
-- days before it. This file only clears what that already produced -- re-run
-- 09_pkg_oc_time.sql or none of it stays fixed.
--
-- WHY DELETE RATHER THAN ZERO
--   A zero-hour line is worse than no line: it shows the employee a project
--   they cannot charge to, on a day they were not on it, and invites the
--   question of why it is there. These cells should never have existed, so
--   they go. Only SOURCE = 'Prepopulated' -- nothing typed is touched, and a
--   typed row on an unallocated day is a real conversation, not a cleanup.
--
-- OC_TS_ENTRY has no DELETE trigger (the audit triggers are BEFORE UPDATE OF),
-- so the audit row is written first, the same way oc_time_sync_leave does it.
--
-- Idempotent. Depends on: time/09 (re-run first), 62.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views
   WHERE view_name = 'V_OC_TS_ENTRY_EXPECTED';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'V_OC_TS_ENTRY_EXPECTED does not exist. Run 62 first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] Prepopulated rows on days with no allocation
PROMPT ============================================================

COLUMN employee_id FORMAT A11
COLUMN project_number FORMAT A12
COLUMN span FORMAT A26
SELECT x.employee_id, x.project_number,
       COUNT(*)                                  AS rows_,
       SUM(x.held_hours)                         AS hours_held,
       TO_CHAR(MIN(x.entry_date),'DD-Mon') || ' .. '
         || TO_CHAR(MAX(x.entry_date),'DD-Mon')  AS span,
       -- What the allocation actually says, so the gap is visible rather than
       -- asserted. NULL means there is no allocation row at all.
       NVL((SELECT TO_CHAR(MIN(al.start_date),'DD-Mon-YY')
              FROM oc_time_allocation al
             WHERE al.employee_id = x.employee_id
               AND al.project_id  = x.project_id
               AND al.status      = 'Active'), '(no active allocation)')
         AS alloc_starts
  FROM v_oc_ts_entry_expected x
 WHERE x.expected_hours = 0
 GROUP BY x.employee_id, x.project_number, x.project_id
 ORDER BY 3 DESC;

SELECT COUNT(*) AS rows_to_remove, SUM(held_hours) AS hours_removed
  FROM v_oc_ts_entry_expected WHERE expected_hours = 0;

PROMPT ============================================================
PROMPT [2/3] Remove them
PROMPT ============================================================

DECLARE
  v_gone NUMBER := 0;
  v_evt  NUMBER := 0;
BEGIN
  FOR e IN (SELECT x.ts_entry_id, x.ts_week_id, x.employee_id, x.entry_date,
                   x.project_id, x.held_hours, x.approval_status,
                   e.task_id
              FROM v_oc_ts_entry_expected x
              JOIN oc_ts_entry e ON e.ts_entry_id = x.ts_entry_id
             WHERE x.expected_hours = 0)
  LOOP
    -- History before the delete, while the values still exist.
    INSERT INTO oc_ts_audit (
      ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
      old_project_id, old_task_id, old_hours, old_bill_type,
      new_project_id, new_task_id, new_hours,
      change_reason, changed_by, changed_on)
    VALUES (
      e.ts_entry_id, e.ts_week_id, e.employee_id, e.entry_date, 'AbsenceSync',
      e.project_id, e.task_id, e.held_hours, 'Billable',
      NULL, NULL, 0,
      'Prepopulated on a date no active allocation covers; row removed.',
      'ALLOC_CLEANUP', SYSTIMESTAMP);

    DELETE FROM oc_ts_entry WHERE ts_entry_id = e.ts_entry_id;
    v_gone := v_gone + 1;

    IF e.approval_status <> 'Pending' THEN
      DECLARE
        v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', 'ALLOC_CLEANUP',
                            v_s, v_a, v_f);
        v_evt := v_evt + 1;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_gone || ' row(s) removed, '
    || v_evt || ' decided week(s) sent back');
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

SELECT COUNT(*) AS still_disagreeing
  FROM v_oc_ts_entry_expected
 WHERE held_hours <> expected_hours;

PROMPT
PROMPT Zero means every prepopulated row now matches its allocation exactly:
PROMPT both the ones that held the wrong figure and the ones that should not
PROMPT have existed.

PROMPT
PROMPT --- days still seeded past their standard hours
SELECT w.employee_id, TO_CHAR(e.entry_date,'YYYY-MM-DD') AS entry_date,
       SUM(e.hours) AS seeded, MAX(e.standard_hours) AS standard
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_period pe ON pe.status = 'Open'
                        AND e.entry_date BETWEEN pe.start_date AND pe.end_date
 WHERE e.source = 'Prepopulated' AND e.is_leave = 'N'
   AND e.entry_type IN ('Actual','Default')
 GROUP BY w.employee_id, e.entry_date
HAVING SUM(e.hours) > MAX(e.standard_hours)
 ORDER BY 3 DESC
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT Anything left is PPM saying that person is allocated above 100% on that
PROMPT day, and the module apportioning exactly what it was given. Persons 32
PROMPT and 35 read 80 hours against 8 because they hold ten projects at 100%
PROMPT each -- a PPM correction, not a timesheet one.
PROMPT
PROMPT RE-RUN 09_pkg_oc_time.sql IF YOU HAVE NOT. Without the day-span guard in
PROMPT populate, the next run seeds these dates again.
