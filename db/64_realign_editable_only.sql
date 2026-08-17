--==============================================================
-- time/64_realign_editable_only.sql
-- O2C Timesheet Module — a closed month is corrected by adjustment, not by a job
--
-- 62 widened the realign to every date holding an entry, which fixed the 66
-- rows it had been leaving in future months and also made it rewrite hours in
-- CLOSED periods. That last part is wrong, and the module already says so:
--
--   "There is no Closed. A week is not editable because the cut-off passed
--    ... a change after the delivery cut-off is an ADJUSTMENT."  (CLAUDE.md s7)
--
-- Silently rewriting a closed month is worse than leaving it wrong. The hours
-- have been approved, confirmed to accrual, possibly paid. OC_TS_ADJUSTMENT
-- exists precisely so that a retro change carries a reason, a requester and an
-- approval -- RA-014 requires BOTH the old and new project manager -- and a job
-- that edits the row directly produces the same number with none of that. The
-- audit trail would show a correction nobody asked for and nobody approved.
--
-- SO THE GATE IS V_OC_TS_MY_PERIODS.EDITABLE_FLAG, which is already the answer
-- everywhere else: 'N' for a future period (RULE-004), for a period that is not
-- Open, and for one past its delivery cut-off (RULE-007). The realign now
-- touches 'Y' only.
--
-- What is left is not ignored. Section [2] lists every disagreement in a
-- non-editable period, with whether an adjustment is even still allowed
-- (ADJUSTMENT_ALLOWED, which closes after ADJUSTMENT_MONTHS). Those need a
-- person to raise ACT-013, not a script.
--
-- Idempotent. Depends on: time/08, 13, 62.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views
   WHERE view_name IN ('V_OC_TS_ENTRY_EXPECTED','V_OC_TS_MY_PERIODS');
  IF v_n < 2 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Needs V_OC_TS_ENTRY_EXPECTED (62) and V_OC_TS_MY_PERIODS (08/13).');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] The expectation view now says whether the day may be touched
PROMPT ============================================================

-- EDITABLE_FLAG and ADJUSTMENT_ALLOWED are carried on the row rather than
-- joined by every caller, so "may this be corrected in place?" and "what does
-- it currently hold?" are one question with one answer.
CREATE OR REPLACE VIEW v_oc_ts_entry_expected AS
SELECT e.ts_entry_id,
       e.ts_week_id,
       w.employee_id,
       w.approval_status,
       w.period_id,
       e.entry_date,
       e.project_id,
       p.project_number,
       e.hours AS held_hours,
       NVL(e.standard_hours,
           (SELECT wk.std_hours_per_day FROM oc_time_worker wk
             WHERE wk.employee_id = w.employee_id)) AS std_hours,
       NVL((SELECT MAX(al.alloc_pct) FROM oc_time_allocation al
             WHERE al.employee_id = w.employee_id
               AND al.project_id  = e.project_id
               AND al.status      = 'Active'
               -- The allocation in force ON THAT DAY, not merely active now.
               AND e.entry_date BETWEEN al.start_date
                                    AND NVL(al.end_date, DATE '4712-12-31')), 0)
         AS alloc_pct,
       ROUND(NVL(NVL(e.standard_hours,
                     (SELECT wk.std_hours_per_day FROM oc_time_worker wk
                       WHERE wk.employee_id = w.employee_id)), 0)
             * NVL((SELECT MAX(al.alloc_pct) FROM oc_time_allocation al
                     WHERE al.employee_id = w.employee_id
                       AND al.project_id  = e.project_id
                       AND al.status      = 'Active'
                       AND e.entry_date BETWEEN al.start_date
                                            AND NVL(al.end_date, DATE '4712-12-31')), 0)
             / 100 * 4) / 4 AS expected_hours,
       pe.editable_flag,
       pe.adjustment_allowed,
       pe.period_name,
       pe.period_state
  FROM oc_ts_entry e
  JOIN oc_ts_week  w  ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_project p ON p.project_id = e.project_id
  JOIN v_oc_ts_my_periods pe ON pe.period_id = w.period_id
 WHERE e.source     = 'Prepopulated'
   AND e.is_leave   = 'N'
   AND e.entry_type IN ('Actual','Default')
   AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                    WHERE ab.employee_id     = w.employee_id
                      AND ab.absence_date    = e.entry_date
                      AND ab.approval_status = 'Approved');

PROMPT ============================================================
PROMPT [2/4] What a job may NOT fix, and what to do with it
PROMPT ============================================================

COLUMN period_name FORMAT A11
COLUMN period_state FORMAT A8
COLUMN employee_id FORMAT A11
COLUMN project_number FORMAT A12
COLUMN route FORMAT A34
SELECT x.period_name, x.period_state, x.employee_id, x.project_number,
       COUNT(*)               AS days,
       SUM(x.held_hours)      AS holds,
       SUM(x.expected_hours)  AS should_hold,
       CASE WHEN x.adjustment_allowed = 'Y'
            THEN 'raise an adjustment (ACT-013)'
            ELSE 'past the adjustment window' END AS route
  FROM v_oc_ts_entry_expected x
 WHERE x.held_hours <> x.expected_hours
   AND x.editable_flag = 'N'
 GROUP BY x.period_name, x.period_state, x.employee_id, x.project_number,
          x.adjustment_allowed
 ORDER BY x.period_name, x.employee_id;

PROMPT
PROMPT These are NOT corrected below. The hours were approved and may have been
PROMPT confirmed to accrual, so the difference is a retro change: it needs a
PROMPT reason, a requester and RA-014's dual approval, which OC_TS_ADJUSTMENT
PROMPT carries and a background UPDATE does not.
PROMPT
PROMPT 'Past the adjustment window' means even that route has closed
PROMPT (ADJUSTMENT_MONTHS on the period). Those need Finance, not the module.

PROMPT ============================================================
PROMPT [3/4] Realign the editable periods only
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_restore_default_hours(
  p_from        IN  DATE,
  p_to          IN  DATE,
  p_employee_id IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'LEAVE_RESTORE',
  o_restored    OUT NUMBER)
IS
  v_skipped NUMBER := 0;
BEGIN
  o_restored := 0;

  -- Counted before the loop so the caller learns that something was left
  -- alone. A silent skip and nothing to fix look identical in the log.
  SELECT COUNT(*) INTO v_skipped
    FROM v_oc_ts_entry_expected x
   WHERE x.entry_date BETWEEN p_from AND p_to
     AND (p_employee_id IS NULL OR x.employee_id = p_employee_id)
     AND x.held_hours <> x.expected_hours
     AND x.expected_hours > 0
     AND x.editable_flag = 'N';

  FOR e IN (SELECT * FROM v_oc_ts_entry_expected x
             WHERE x.entry_date BETWEEN p_from AND p_to
               AND (p_employee_id IS NULL OR x.employee_id = p_employee_id)
               AND x.held_hours <> x.expected_hours
               AND x.expected_hours > 0
               -- RULE-004 / RULE-007. Past the delivery cut-off, or in a period
               -- that is not Open, a change is an ADJUSTMENT and belongs to a
               -- person. See the header.
               AND x.editable_flag = 'Y')
  LOOP
    UPDATE oc_ts_entry
       SET hours      = e.expected_hours,
           updated_by = p_actor,
           updated_on = SYSTIMESTAMP
     WHERE ts_entry_id = e.ts_entry_id;
    o_restored := o_restored + 1;

    IF e.approval_status <> 'Pending' THEN
      DECLARE
        v_s VARCHAR2(30); v_a VARCHAR2(30); v_f VARCHAR2(30);
      BEGIN
        oc_time_apply_event(e.ts_week_id, 'DailyChange', p_actor, v_s, v_a, v_f);
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  DailyChange skipped on week ' || e.ts_week_id
                          || ': ' || SUBSTR(SQLERRM, 1, 90));
      END;
    END IF;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(o_restored || ' day-row(s) realigned');
  IF v_skipped > 0 THEN
    DBMS_OUTPUT.PUT_LINE(v_skipped || ' left alone in non-editable periods - '
      || 'these need an adjustment, not a correction');
  END IF;
END oc_time_restore_default_hours;
/
SHOW ERRORS

DECLARE
  v_from DATE; v_to DATE; v_n NUMBER;
BEGIN
  SELECT MIN(entry_date), MAX(entry_date) INTO v_from, v_to FROM oc_ts_entry;
  IF v_from IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('No entries.'); RETURN;
  END IF;
  oc_time_restore_default_hours(v_from, v_to, NULL, 'ALLOC_REALIGN', v_n);
END;
/

PROMPT ============================================================
PROMPT [4/4] The other thing only a person can fix
PROMPT ============================================================
PROMPT
PROMPT A resource staffed in PPM with no project TEAM MEMBER row behind them
PROMPT cannot record time, and is invisible from this schema -- the ALLOCATIONS
PROMPT feed is anchored on PJF_PROJECT_PARTIES, so somebody missing from it
PROMPT never arrives to be counted here.
PROMPT
PROMPT That check has to run against Fusion:
PROMPT
PROMPT   python integration/bip/check_ppm_gaps.py
PROMPT
PROMPT Measured on PCS10034: RI2824 and RI9001 hold both rows, RI2894 holds only
PROMPT the resource, and all three appear on the Manage Project Resources
PROMPT screen -- which reads the resource table, so the gap is invisible there.
PROMPT Fix it in PPM by adding the person as a project team member. Adding a
PROMPT party row from here would invent a Track Time answer Fusion has not
PROMPT given, and OTL would refuse the time later anyway.
