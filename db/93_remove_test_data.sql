--==============================================================
-- time/93_remove_test_data.sql
-- O2C Timesheet Module — remove seeded test data, keep the logins
--
-- DESTRUCTIVE. Read 91_production_readiness.sql first; it is the read-only
-- survey and tells you what this will take.
--
-- WHAT GOES
--   * ALL timesheet transactions -- every week, entry, approval, adjustment,
--     salary hold, month confirm and accrual interface row. Every one of them
--     was built from seeded masters or a demo reset, so none of it is real.
--   * Projects, tasks and allocations with no Fusion id
--   * Hand-built calendar rows (SOURCE_METHOD IS NULL)
--   * Absences with no Fusion id
--
-- WHAT STAYS, DELIBERATELY
--   * OC_TIME_USER -- the logins, by explicit request. The module signs users
--     in itself and this is the one store that is not Fusion's (section 4).
--   * OC_TIME_WORKER -- untouched. The twelve HDL workers came back through the
--     sync carrying a FUSION_PERSON_ID, so they ARE Fusion rows now; and
--     deleting them would break the logins that reference them.
--   * COMMON tasks (Leave, Training, Travel) -- design data. Remove the COMMON
--     Leave task and absence prepopulation has nowhere to write (RULE-008).
--   * PRJ-ORG -- still guarded here even though it is being retired, because
--     23_unbilled_reason_per_line.sql owns that decision and does it by hand
--     once nothing points at it. Two scripts must not both think they own it.
--   * OC_TIME_PERIOD, cut-offs, OC_TIME_CONFIG, lookups -- decisions, not
--     facts about Fusion. Their VALUES need review before production; that is
--     configuration, not cleanup.
--
-- ORDER MATTERS. Transactions rest on masters: a test project cannot be
-- deleted while entries point at it -- the foreign key refuses, or cascades
-- and takes hours with it. Transactions first, then allocations, then tasks,
-- then projects.
--
-- Re-runnable: every statement is a DELETE with a predicate, so a second run
-- finds nothing and removes nothing.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT ============================================================
PROMPT [1/6] What is about to go
PROMPT ============================================================

COLUMN what FORMAT A44
SELECT 'timesheet weeks'         AS what, COUNT(*) AS rows_ FROM oc_ts_week
UNION ALL SELECT 'timesheet entries',      COUNT(*) FROM oc_ts_entry
UNION ALL SELECT 'approvals',              COUNT(*) FROM oc_ts_approval
UNION ALL SELECT 'adjustments',            COUNT(*) FROM oc_ts_adjustment
UNION ALL SELECT 'salary holds',           COUNT(*) FROM oc_ts_salary_hold
UNION ALL SELECT 'month confirms',         COUNT(*) FROM oc_ts_month_confirm
UNION ALL SELECT 'projects without a Fusion id',
       (SELECT COUNT(*) FROM oc_time_project
         WHERE fusion_project_id IS NULL AND project_number <> 'PRJ-ORG')
UNION ALL SELECT 'tasks without a Fusion id (non-COMMON)',
       (SELECT COUNT(*) FROM oc_time_task
         WHERE fusion_task_id IS NULL AND task_type <> 'COMMON')
UNION ALL SELECT 'allocations without a Fusion id',
       (SELECT COUNT(*) FROM oc_time_allocation WHERE fusion_project_id IS NULL)
UNION ALL SELECT 'calendar rows not from a sync',
       (SELECT COUNT(*) FROM oc_time_calendar WHERE source_method IS NULL)
UNION ALL SELECT 'absences without a Fusion id',
       (SELECT COUNT(*) FROM oc_time_absence WHERE fusion_absence_id IS NULL);

PROMPT
PROMPT Read that before continuing. Nothing has been deleted yet.

PROMPT
PROMPT ============================================================
PROMPT [2/6] Transactions — all of them
PROMPT ============================================================

-- Children before parents. OC_TS_ENTRY hangs off OC_TS_WEEK, and the audit and
-- approval rows hang off both, so the week cannot go first.
DECLARE
  v NUMBER;
  PROCEDURE wipe(p_table VARCHAR2) IS
    v_n NUMBER;
  BEGIN
    EXECUTE IMMEDIATE 'DELETE FROM ' || p_table;
    v_n := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_table, 28) || TO_CHAR(v_n, '999,999') || ' deleted');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_table, 28) || 'SKIPPED - ' || SUBSTR(SQLERRM, 1, 70));
  END;
BEGIN
  -- The interface first: it is denormalised and un-FK'd on purpose, so it does
  -- not block anything, but leaving it behind would hand the consumer hours
  -- whose timesheets no longer exist.
  BEGIN
    EXECUTE IMMEDIATE 'DELETE FROM xx_o2c_timesheet_accrual_if';
    DBMS_OUTPUT.PUT_LINE(RPAD('accrual interface', 28)
                      || TO_CHAR(SQL%ROWCOUNT, '999,999') || ' deleted');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('accrual interface           SKIPPED - '
                      || SUBSTR(SQLERRM, 1, 60));
  END;

  wipe('oc_ts_audit');
  wipe('oc_ts_leave_loss_cover');
  wipe('oc_ts_salary_hold_day');
  wipe('oc_ts_salary_hold');
  wipe('oc_ts_adjustment');
  wipe('oc_ts_approval');
  wipe('oc_ts_client_doc');
  wipe('oc_ts_month_confirm');
  wipe('oc_ts_entry');
  wipe('oc_ts_week');
  COMMIT;
END;
/

PROMPT
PROMPT ============================================================
PROMPT [3/6] Allocations, then tasks, then projects
PROMPT ============================================================

DECLARE
  v_a NUMBER; v_t NUMBER; v_p NUMBER;
BEGIN
  -- Allocations reference both worker and project, so they go before either.
  DELETE FROM oc_time_allocation WHERE fusion_project_id IS NULL;
  v_a := SQL%ROWCOUNT;

  -- COMMON tasks are design data and are NOT touched: RULE-008 writes absence
  -- prepopulation against the COMMON Leave task, so removing it silently
  -- breaks every leave row the module will ever build.
  DELETE FROM oc_time_task
   WHERE fusion_task_id IS NULL AND task_type <> 'COMMON';
  v_t := SQL%ROWCOUNT;

  -- PRJ-ORG is guarded here on purpose -- see the header.
  DELETE FROM oc_time_project
   WHERE fusion_project_id IS NULL AND project_number <> 'PRJ-ORG';
  v_p := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('allocations  ' || v_a || ' deleted');
  DBMS_OUTPUT.PUT_LINE('tasks        ' || v_t || ' deleted (COMMON kept)');
  DBMS_OUTPUT.PUT_LINE('projects     ' || v_p || ' deleted (PRJ-ORG kept)');
END;
/

PROMPT
PROMPT ============================================================
PROMPT [4/6] Calendar and absences
PROMPT ============================================================

-- THE CALENDAR IS DELIBERATELY LEFT ALONE. Decided 12-Aug-2026.
--
-- SOURCE_METHOD would have been the discriminator -- 'BIP' or 'REST' on
-- anything a sync wrote, NULL on a hand-seeded row -- but deleting on it is
-- not safe yet, because the two sets OVERLAP rather than sitting side by side:
--
--   SELECT COUNT(*) FROM oc_time_calendar
--    WHERE cal_date BETWEEN DATE '2026-08-01' AND DATE '2026-08-31'
--      AND is_working_day = 'Y';           -->  42, for a month with 21
--
-- Every August date carries TWO CORPORATE rows, one seeded and one synced,
-- with the same values. Dropping the seeded half would probably be correct and
-- would probably leave 21 -- but "probably" is not good enough for the table
-- that decides whether a day exists at all. A calendar that comes back short
-- silently populates nothing, and the symptom is an empty timesheet rather
-- than an error.
--
-- The duplication is worth fixing on its own terms, not as a side effect of a
-- cleanup: two rows at the same LAYER and PRECEDENCE for one date make the
-- precedence resolution ambiguous, and nothing in the model forbids it.
-- Recorded as an open item rather than acted on here.
DECLARE
  v_b NUMBER;
BEGIN
  DELETE FROM oc_time_absence WHERE fusion_absence_id IS NULL;
  v_b := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('absences      ' || v_b || ' deleted');
  DBMS_OUTPUT.PUT_LINE('calendar      untouched by decision - see the note above');
END;
/

PROMPT
PROMPT ============================================================
PROMPT [5/6] What is left
PROMPT ============================================================

SELECT 'OC_TIME_WORKER' AS table_name, COUNT(*) AS total,
       COUNT(fusion_person_id) AS from_fusion FROM oc_time_worker
UNION ALL SELECT 'OC_TIME_PROJECT', COUNT(*), COUNT(fusion_project_id)
  FROM oc_time_project
UNION ALL SELECT 'OC_TIME_TASK', COUNT(*), COUNT(fusion_task_id)
  FROM oc_time_task
UNION ALL SELECT 'OC_TIME_ALLOCATION', COUNT(*), COUNT(fusion_project_id)
  FROM oc_time_allocation
UNION ALL SELECT 'OC_TIME_CALENDAR', COUNT(*), COUNT(source_method)
  FROM oc_time_calendar
UNION ALL SELECT 'OC_TIME_ABSENCE', COUNT(*), COUNT(fusion_absence_id)
  FROM oc_time_absence
UNION ALL SELECT 'OC_TIME_USER (untouched)', COUNT(*), NULL FROM oc_time_user
UNION ALL SELECT 'OC_TS_WEEK', COUNT(*), NULL FROM oc_ts_week;

PROMPT
PROMPT TOTAL should equal FROM_FUSION on every master row except the two
PROMPT design exceptions -- PRJ-ORG on projects, COMMON on tasks.
PROMPT OC_TS_WEEK should be 0. OC_TIME_USER is unchanged.

PROMPT
PROMPT ============================================================
PROMPT [6/6] Rebuild from Fusion
PROMPT ============================================================
PROMPT
PROMPT Nothing populates itself. Run the OIC daily sync -- or populate by hand:
PROMPT
PROMPT   DECLARE v NUMBER;
PROMPT   BEGIN
PROMPT     v := oc_time_pkg.populate_month(
PROMPT            (SELECT period_id FROM oc_time_period WHERE status='Open'
PROMPT              AND ROWNUM = 1), NULL, 'POST_CLEANUP');
PROMPT     COMMIT;
PROMPT   END;
PROMPT   /
PROMPT
PROMPT Expect fewer people than before: 233 allocations point at projects with
PROMPT no chargeable WBS task and those workers get no rows at all until PPM
PROMPT is fixed. That is the data gap, not a fault in the cleanup.
