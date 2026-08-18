--==============================================================
-- time/76_project_scope_and_defaulted_phantoms.sql
-- O2C Timesheet Module — the two things db/75 could not finish
--
-- db/75 worked: the stamp landed 18-Aug, 4 allocations Ended, 7793 went
-- Inactive, 65 phantom entries went. Two things it stopped short of, for
-- opposite reasons -- one guard fired correctly and one was aimed wrong.
--
-- A. THE 377 PROJECTS. We hold 426 Active; the feed returns 49. The proportion
--    guard refused, and it was right to: it cannot tell a narrowed scope from a
--    half-finished load, and refusing is the safe answer to that ambiguity.
--
--    But we know which this is. The 03-Aug load ran a DEPLOYED model that was
--    never scoped to time-tracking projects -- the 424-loaded-when-46-validated
--    incident already recorded at run_extract.py:156. The current model returns
--    49 because PJS_TRACK_TIME is now applied. So 377 of these were never
--    timesheet projects; they are residue from a model that pulled everything.
--
--    Closing is not destructive and this is worth being clear about, because it
--    is why no entry guard is needed here. V_OC_TS_MGR_PROJECTS filters
--    status = 'Active'; OC_TS_ENTRY has no opinion on project status. So a
--    closed project keeps every hour ever booked to it and simply stops being
--    offered for approval. 666 has 20 hours on it and still must close.
--
-- B. THE DEFAULTED PHANTOMS. db/75 removed 65 rows and left 10, and the
--    diagnostic showed why: SOURCE = 'Job', week = 'Defaulted'.
--
--        UPDATE oc_ts_entry SET entry_type = 'Default', source = 'Job'
--         WHERE ts_week_id = w.ts_week_id
--           AND entry_type = 'Actual' AND source = 'Prepopulated';
--
--    run_weekly_defaulting (09_pkg:1553) retags the exact rows db/75 was
--    hunting and sets the week Defaulted in the same pass. So both of its
--    guards -- source = 'Prepopulated', week NotYetSubmitted -- invert the
--    moment a week passes its weekly cut-off. db/75's header claims June and
--    July "cannot qualify however this is run" as a safety property. It is the
--    hole, and the reasoning behind it was backwards: Defaulted hours are the
--    ones a JOB INVENTED because nobody filled them in, so phantom time is more
--    suspect after defaulting, not less. 80 fabricated hours on a project the
--    person is not on is worse than 80 stale ones.
--
--    Kept regardless, and these are real limits, not caution:
--      * an audit row  -- somebody touched it. RI2894's 20h and RI2249's 20h
--                         are audited and stay
--      * Approved      -- a manager signed it off; that is a decision, not data
--      * confirmed     -- the month reached accrual and the interface holds
--                         rows we cannot retract from here
--      * typed         -- source 'Employee'/'Manager'/'Absence' is a person
--
-- C. WHAT THIS DELIBERATELY DOES NOT DO. Removing entries does not release a
--    salary hold. OC_TS_SALARY_HOLD is keyed (employee_id, period_id) and
--    driven by WEEKS_DEFAULTED off the WEEK, so a week emptied here stays
--    Defaulted and keeps holding pay -- now with nothing on screen to explain
--    why. Section 5 reports that population and changes nothing. Releasing pay
--    is not a side effect of a cleanup script.
--
-- Idempotent. Depends on: time/02, 03, 04, 05, 75.
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
PROMPT [1/6] The 377 — what is about to close, and what it carries
PROMPT ============================================================

COLUMN carries FORMAT A28
SELECT CASE WHEN EXISTS (SELECT 1 FROM oc_ts_entry e
                          WHERE e.project_id = p.project_id)
            THEN 'has timesheet history' ELSE 'never used' END AS carries,
       COUNT(*) AS projects
  FROM oc_time_project p
 WHERE p.status = 'Active'
   AND NVL(TRUNC(p.fusion_synced_on), DATE '1900-01-01')
       < (SELECT MAX(TRUNC(fusion_synced_on)) FROM oc_time_project)
 GROUP BY CASE WHEN EXISTS (SELECT 1 FROM oc_ts_entry e
                             WHERE e.project_id = p.project_id)
               THEN 'has timesheet history' ELSE 'never used' END;

PROMPT
PROMPT Both groups close. History is kept -- OC_TS_ENTRY does not read project
PROMPT status, only V_OC_TS_MGR_PROJECTS does. This is listed so the number is
PROMPT on the record, not because it gates anything.

PROMPT ============================================================
PROMPT [2/6] Close them
PROMPT ============================================================

-- The age guard from db/75 still applies -- a stale stamp still proves nothing,
-- and that is the fault db/69 actually made. Only the PROPORTION test is being
-- overridden, and only because the scope change above is a measured fact.
DECLARE
  v_latest DATE;
  v_closed NUMBER;
BEGIN
  SELECT MAX(TRUNC(fusion_synced_on)) INTO v_latest FROM oc_time_project;

  IF v_latest IS NULL OR TRUNC(SYSDATE) - v_latest > 2 THEN
    DBMS_OUTPUT.PUT_LINE('  Newest PROJECTS stamp is '
      || NVL(TO_CHAR(v_latest,'DD-Mon-YY'),'(never)')
      || '. Run a full PROJECTS load first. Nothing closed.');
  ELSE
    UPDATE oc_time_project
       SET status     = 'Closed',
           updated_by = 'SCOPE_76',
           updated_on = SYSTIMESTAMP
     WHERE status = 'Active'
       AND NVL(TRUNC(fusion_synced_on), DATE '1900-01-01') < v_latest;
    v_closed := SQL%ROWCOUNT;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  ' || v_closed || ' project(s) closed -- absent from '
      || 'the time-tracking feed of ' || TO_CHAR(v_latest,'DD-Mon-YY') || '.');
    DBMS_OUTPUT.PUT_LINE('  Any that return to the feed go back to Active on '
      || 'the next load: the extract sends STATUS, so this is self-healing.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [3/6] Defaulted phantoms — what would go, before it goes
PROMPT ============================================================

COLUMN project_number FORMAT A12
COLUMN employee_id FORMAT A10
SELECT p.project_number, w.employee_id, w.period_year, w.period_month,
       COUNT(*) AS entries, SUM(e.hours) AS hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_project p ON p.project_id = e.project_id
 WHERE e.source IN ('Prepopulated','Job')
   AND e.entry_type IN ('Actual','Default')
   AND NVL(w.submission_status,'NotYetSubmitted') IN ('NotYetSubmitted','Defaulted')
   AND NVL(w.approval_status,'Pending') = 'Pending'
   AND NOT EXISTS (SELECT 1 FROM oc_ts_audit a WHERE a.ts_entry_id = e.ts_entry_id)
   AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al
                    WHERE al.project_id  = e.project_id
                      AND al.employee_id = w.employee_id
                      AND al.status      = 'Active'
                      AND e.entry_date BETWEEN al.start_date
                                           AND NVL(al.end_date, e.entry_date))
   AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm c
                    WHERE c.project_id = e.project_id
                      AND c.period_id  = w.period_id)
 GROUP BY p.project_number, w.employee_id, w.period_year, w.period_month
 ORDER BY 1, 2, 3, 4;

PROMPT ============================================================
PROMPT [4/6] Remove them
PROMPT ============================================================

DECLARE
  v_e NUMBER;
BEGIN
  DELETE FROM oc_ts_entry e
   WHERE e.source IN ('Prepopulated','Job')
     AND e.entry_type IN ('Actual','Default')
     AND EXISTS (SELECT 1 FROM oc_ts_week w
                  WHERE w.ts_week_id = e.ts_week_id
                    AND NVL(w.submission_status,'NotYetSubmitted')
                        IN ('NotYetSubmitted','Defaulted')
                    AND NVL(w.approval_status,'Pending') = 'Pending')
     AND NOT EXISTS (SELECT 1 FROM oc_ts_audit a
                      WHERE a.ts_entry_id = e.ts_entry_id)
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
  DBMS_OUTPUT.PUT_LINE('  ' || v_e || ' defaulted phantom entry row(s) removed.');
END;
/

PROMPT ============================================================
PROMPT [5/6] REPORT ONLY — weeks now empty, and pay still held
PROMPT ============================================================

-- Nothing below is acted on. A week emptied above keeps its Defaulted status,
-- and OC_TS_SALARY_HOLD counts WEEKS_DEFAULTED off the week, so the hold stands
-- with no hours on screen behind it. That is a worse state than before if it is
-- left, and releasing pay is not something a cleanup script decides.
COLUMN employee_id FORMAT A10
COLUMN employee_name FORMAT A26
SELECT w.employee_id, wk.employee_name, w.period_year, w.period_month,
       COUNT(*) AS empty_weeks
  FROM oc_ts_week w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
 WHERE NVL(w.submission_status,'NotYetSubmitted') = 'Defaulted'
   AND NOT EXISTS (SELECT 1 FROM oc_ts_entry e WHERE e.ts_week_id = w.ts_week_id)
 GROUP BY w.employee_id, wk.employee_name, w.period_year, w.period_month
 ORDER BY 1, 3, 4;

PROMPT
PROMPT Any employee listed above is Defaulted for a week with no hours at all.

COLUMN salary_status FORMAT A14
SELECT h.employee_id, wk.employee_name, pe.period_name, h.salary_status,
       h.weeks_defaulted, h.default_hours
  FROM oc_ts_salary_hold h
  JOIN oc_time_worker  wk ON wk.employee_id = h.employee_id
  JOIN oc_time_period  pe ON pe.period_id   = h.period_id
 WHERE h.salary_status = 'Held'
   AND NOT EXISTS (SELECT 1 FROM oc_ts_week w
                    JOIN oc_ts_entry e ON e.ts_week_id = w.ts_week_id
                   WHERE w.employee_id = h.employee_id
                     AND w.period_id   = h.period_id)
 ORDER BY 1, 3;

PROMPT
PROMPT Held with no timesheet rows left in that period. Decide these explicitly:
PROMPT either the week should not be Defaulted, or the person should not be held.

PROMPT ============================================================
PROMPT [6/6] Verification — the manager screen
PROMPT ============================================================

COLUMN project_number FORMAT A12
COLUMN project_name FORMAT A32
SELECT p.project_number, p.project_name, p.status
  FROM oc_time_project p
 WHERE p.project_number IN ('444','555','666','PCS10034')
 ORDER BY p.project_number;

PROMPT
PROMPT 666 must read Closed; the other three stay Active.

SELECT COUNT(*) AS active_projects FROM oc_time_project WHERE status = 'Active';

PROMPT
PROMPT Should be 49 or close to it - the size of the time-tracking feed.

COLUMN employee_name FORMAT A26
SELECT m.project_number, m.employee_id, m.employee_name, m.total_hours
  FROM v_oc_ts_month_summary m
 WHERE m.period_year = 2026 AND m.period_month = 8
   AND NOT EXISTS (SELECT 1 FROM oc_time_allocation al
                    WHERE al.project_id  = m.project_id
                      AND al.employee_id = m.employee_id
                      AND al.status      = 'Active')
 ORDER BY 1, 2;

PROMPT
PROMPT Whatever remains is audited, approved or confirmed to accrual, and was
PROMPT kept on purpose. Read the hours before touching any of it by hand.
