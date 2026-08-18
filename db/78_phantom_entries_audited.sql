--==============================================================
-- time/78_phantom_entries_audited.sql
-- O2C Timesheet Module — the residue the audit guard was protecting
--
-- Reported from the manager screen, 18-Aug-2026:
--
--   * RI2894 Santosh listed on 444 with 20 hours. PPM's team for 444 is
--     Navamani, Saicharan, Sam Joshuva, Shaik, Shivani and User Rite. No
--     Santosh. His only allocation is 555.
--   * RI2249 Saicharan showing 555 rows inside his 444 week. His only
--     allocation is 444.
--
-- Both are the same shape and both survived db/76 for the same reason: they
-- carry an OC_TS_AUDIT row, and db/76 refuses anything audited. The giveaway is
-- visible on the screen itself -- Santosh's BILLING cell reads '-' where every
-- other row reads Billable or Unbilled, because that column comes from a LEFT
-- JOIN to OC_TIME_ALLOCATION and there is nothing to join to.
--
-- WHY THE AUDIT GUARD IS DROPPED HERE, HAVING BEEN RIGHT TWICE BEFORE.
-- db/71 set the rule: deleting an audited entry leaves OC_TS_AUDIT.TS_ENTRY_ID
-- pointing at nothing -- there is no FK -- and it judged that "worse than a few
-- cells the monthly job will skip". That judgement was made about SEPTEMBER
-- cells nobody was looking at. It does not transfer, for two reasons:
--
--   1. THE COST CHANGED SIDES. These cells are not dormant. They put a stranger
--      on a manager's approval list and their hours into a project month that
--      confirm_month will write to the accrual interface. A dangling pointer in
--      a trail nobody queries is cheaper than fabricated hours in accrual.
--
--   2. THE TRAIL DOES NOT NEED THE ENTRY. OC_TS_AUDIT is self-describing:
--      TS_WEEK_ID, OLD_PROJECT_ID, NEW_PROJECT_ID, OLD_HOURS, NEW_HOURS,
--      CHANGE_TYPE, CHANGED_BY, CHANGED_ON. Every question the trail exists to
--      answer -- who changed what, when, from what to what -- is answered
--      without ever dereferencing TS_ENTRY_ID. It is a convenience pointer, not
--      the substance. db/71 treated it as the substance.
--
-- Not a licence to widen further. THE GUARDS THAT DO NOT MOVE:
--
--   no allocation   the core rule -- nothing in PPM puts this person on this
--                   project on this date. Everything else here is subordinate
--   system-written  source 'Prepopulated' or 'Job' only. If a human typed it,
--                   it stays, whatever PPM says -- a person recording work is
--                   evidence, and a wrong allocation is the likelier fault
--   not Approved    a manager's decision is not unpicked by a cleanup script
--   not confirmed   the month reached accrual and the interface holds rows
--                   this cannot retract
--
-- Verified before writing: the safety probe for typed time behind a
-- non-tracking allocation returned ZERO rows, so no human-entered hour is in
-- scope here at all.
--
-- Idempotent. Depends on: time/03, 04, 75, 76.
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
PROMPT [1/4] What is about to go, and how much of it is audited
PROMPT ============================================================

COLUMN project_number FORMAT A12
COLUMN employee_id FORMAT A10
COLUMN employee_name FORMAT A24
SELECT p.project_number, w.employee_id, wk.employee_name,
       w.period_year AS yr, w.period_month AS mth,
       COUNT(*) AS entries, SUM(e.hours) AS hours,
       SUM(CASE WHEN EXISTS (SELECT 1 FROM oc_ts_audit a
                              WHERE a.ts_entry_id = e.ts_entry_id)
                THEN 1 ELSE 0 END) AS audited
  FROM oc_ts_entry e
  JOIN oc_ts_week      w  ON w.ts_week_id  = e.ts_week_id
  JOIN oc_time_worker  wk ON wk.employee_id = w.employee_id
  JOIN oc_time_project p  ON p.project_id  = e.project_id
 WHERE e.source IN ('Prepopulated','Job')
   AND NVL(w.approval_status,'Pending') <> 'Approved'
   AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al
                    WHERE al.project_id  = e.project_id
                      AND al.employee_id = w.employee_id
                      AND al.status      = 'Active'
                      AND e.entry_date BETWEEN al.start_date
                                           AND NVL(al.end_date, e.entry_date))
   AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm c
                    WHERE c.project_id = e.project_id
                      AND c.period_id  = w.period_id)
 GROUP BY p.project_number, w.employee_id, wk.employee_name,
          w.period_year, w.period_month
 ORDER BY 1, 2, 4, 5;

PROMPT
PROMPT Expect 444/RI2894 and 555/RI2249 among these. The AUDITED count is the
PROMPT part db/76 refused and this script deliberately takes.

PROMPT ============================================================
PROMPT [2/4] Remove them
PROMPT ============================================================

DECLARE
  v_e NUMBER;
BEGIN
  DELETE FROM oc_ts_entry e
   WHERE e.source IN ('Prepopulated','Job')
     AND EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id
                    AND NVL(w.approval_status,'Pending') <> 'Approved')
     AND NOT EXISTS (
           SELECT 1 FROM oc_time_allocation al
             JOIN oc_ts_week w2 ON w2.ts_week_id = e.ts_week_id
            WHERE al.project_id  = e.project_id
              AND al.employee_id = w2.employee_id
              AND al.status      = 'Active'
              AND e.entry_date BETWEEN al.start_date
                                   AND NVL(al.end_date, e.entry_date))
     AND NOT EXISTS (
           SELECT 1 FROM oc_ts_month_confirm c
             JOIN oc_ts_week w3 ON w3.ts_week_id = e.ts_week_id
            WHERE c.project_id = e.project_id
              AND c.period_id  = w3.period_id);
  v_e := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_e || ' phantom entry row(s) removed.');
END;
/

PROMPT ============================================================
PROMPT [3/4] Audit rows now pointing at a deleted entry
PROMPT ============================================================

-- Reported, not repaired. The trail stays readable -- every one of these rows
-- still carries its week, its old and new project, its hours, who changed it
-- and when. Nothing can be done to them in any case: OC_TS_AUDIT is append-only
-- and refuses UPDATE and DELETE alike with -20026.
SELECT COUNT(*) AS dangling_entry_pointers
  FROM oc_ts_audit a
 WHERE a.ts_entry_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM oc_ts_entry e
                    WHERE e.ts_entry_id = a.ts_entry_id);

PROMPT
PROMPT These resolve to no row by design. See the header for why that is the
PROMPT cheaper side of the trade here and was not in db/71.

PROMPT ============================================================
PROMPT [4/4] Verification — the manager's team, against PPM
PROMPT ============================================================

COLUMN project_number FORMAT A12
COLUMN employee_id FORMAT A10
COLUMN employee_name FORMAT A24
COLUMN in_ppm FORMAT A8
SELECT m.project_number, m.employee_id, m.employee_name, m.total_hours,
       CASE WHEN EXISTS (SELECT 1 FROM oc_time_allocation al
                          WHERE al.project_id  = m.project_id
                            AND al.employee_id = m.employee_id
                            AND al.status      = 'Active')
            THEN 'yes' ELSE 'NO' END AS in_ppm
  FROM v_oc_ts_month_summary m
 WHERE m.period_year = 2026 AND m.period_month = 8
 ORDER BY m.project_number, m.employee_id;

PROMPT
PROMPT Every row must read yes. A NO is somebody on the manager's approval list
PROMPT who is not on the project in Fusion -- the fault this script exists for.
PROMPT
PROMPT 444 should now match PPM exactly: Navamani, Saicharan, Sam Joshuva,
PROMPT Shaik, Shivani, User Rite. No Santosh.
