--==============================================================
-- time/96_withdrawn_absence_retracts_its_coverage.sql
-- O2C Timesheet Module — withdraw the leave and the coverage line goes with it
--
-- Asked 21-Aug: "if we withdraw what will happen". Traced it, and the answer was
-- worse than expected. Everything downstream of the absence retracts correctly:
--
--   OC_TIME_ABSENCE      the sync handler DELETEs on %WITHDRAWN%, and the
--                        windowed claim deletes anything it was not sent
--   OC_TS_ENTRY leave    oc_time_sync_leave's retract half removes any leave
--                        row with no share behind it, with an audit row
--   worked hours         oc_time_leave_displace gives back PRE_LEAVE_HOURS
--                        verbatim once the leave has gone
--
-- and then OC_TS_LEAVE_LOSS_COVER just sits there. NOTHING deletes a coverage
-- line when the absence behind it disappears -- grep finds no DELETE outside the
-- demo-reset and purge scripts. generate_llc_lines only ever INSERTs.
--
-- So a withdrawn absence leaves:
--
--   * a line on PAGE-006 for an absence that no longer exists, which a manager
--     can still assign somebody to
--   * and if it was already Approved, A ROW ON THE INVOICE ANNEXURE naming a
--     colleague as covering an absence that never happened
--
-- That last one is the same shape as scenario 23 -- the cancelled-leave gap the
-- module fixed for leave ENTRIES and never for COVERAGE.
--
-- ── WHAT GETS DELETED AND WHAT DOES NOT ──────────────────────────────────
--
-- Open and Assigned lines are DELETED. Nothing downstream has been asserted
-- about them: an unassigned line is a to-do, and an assigned one is a manager's
-- pending intention. Removing a to-do for an absence that did not happen is
-- housekeeping, not rewriting a decision.
--
-- APPROVED LINES ARE KEPT. A manager approved that coverage and the approval is
-- theirs; deleting it would erase a decision to make a screen tidier. Instead
-- the ANNEXURE stops carrying it -- V_OC_TS_LLC_ANNEXURE now requires the
-- absence to still exist -- so the invoice self-corrects without anyone
-- rewriting history, and [4/4] lists the orphans so the manager can revoke them
-- deliberately.
--
-- That split is the same one db/86 drew between BILLED_FLAG and the hours: the
-- fact that somebody decided, and the consequence of the decision, are separate
-- records and only the consequence is safe to withdraw automatically.
--
-- Idempotent. Depends on: time/05, 08, 09, 88, 94.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_views WHERE view_name = 'V_OC_TS_LLC';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] V_OC_TS_LLC says whether the absence is still there
PROMPT ============================================================

-- ABSENCE_EXISTS is what makes an orphan visible. The alternative was to drop
-- orphaned lines from the view, which would have hidden an Approved coverage
-- the manager still needs to revoke -- invisible and un-actionable is worse
-- than visible and wrong.
CREATE OR REPLACE VIEW v_oc_ts_llc AS
SELECT l.llc_id,
       l.project_id,
       p.project_number,
       p.project_name,
       p.revenue_model,
       p.leave_loss_flag,
       p.project_manager_id,
       l.period_id,
       pe.period_name,
       l.absent_employee_id,                                -- FLD-060
       aw.employee_name AS absent_employee_name,            -- FLD-061
       TO_CHAR(l.absence_date,'YYYY-MM-DD') AS absence_date, -- FLD-062
       TO_CHAR(l.absence_date,'DY')         AS absence_day,
       l.absence_type,
       l.absence_hours,                                     -- FLD-063
       -- THE CAPACITY THIS PROJECT LOST, screen only (db/94). Allocation share
       -- of the person's SHIFT day, scaled by how much of the day the absence
       -- took, divided by 100 and not by the person's allocation total.
       ROUND(
         NVL((SELECT MAX(al.alloc_pct)
                FROM oc_time_allocation al
               WHERE al.employee_id = l.absent_employee_id
                 AND al.project_id  = l.project_id
                 AND al.status      = 'Active'
                 AND l.absence_date BETWEEN al.start_date
                                        AND NVL(al.end_date, l.absence_date)), 0)
         / 100
         * LEAST(1, NVL(l.absence_hours,0)
                    / NULLIF(NVL(aw.std_hours_per_day, 8), 0))
         * NVL((SELECT MAX(e.standard_hours)
                  FROM oc_ts_entry e
                  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
                 WHERE w.employee_id = l.absent_employee_id
                   AND e.entry_date  = l.absence_date),
               aw.std_hours_per_day)
         * 4) / 4                             AS loss_hours,
       -- Is the absence this line was created for still on record? 'N' means it
       -- was withdrawn or cancelled in Absence Management after the line was
       -- built. Approved orphans keep their row and drop off the annexure.
       CASE WHEN EXISTS (SELECT 1 FROM oc_time_absence ab
                          WHERE ab.employee_id     = l.absent_employee_id
                            AND ab.absence_date    = l.absence_date
                            AND ab.approval_status = 'Approved')
            THEN 'Y' ELSE 'N' END             AS absence_exists,
       l.cover_employee_id,                                 -- FLD-064
       cw.employee_name AS cover_employee_name,
       l.llc_status,                                        -- FLD-065
       l.billed_flag,
       l.assigned_by,
       TO_CHAR(l.assigned_on,'YYYY-MM-DD HH24:MI') AS assigned_on,
       l.approved_by,
       TO_CHAR(l.approved_on,'YYYY-MM-DD HH24:MI') AS approved_on,
       l.remarks
  FROM oc_ts_leave_loss_cover l
  JOIN oc_time_project p  ON p.project_id   = l.project_id
                         AND p.revenue_model   = 'FCP'
                         AND p.leave_loss_flag = 'Y'
  JOIN oc_time_period  pe ON pe.period_id    = l.period_id
  JOIN oc_time_worker  aw ON aw.employee_id  = l.absent_employee_id
  LEFT JOIN oc_time_worker cw ON cw.employee_id = l.cover_employee_id;

PROMPT ============================================================
PROMPT [2/4] The annexure requires the absence to still exist
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_ts_llc_annexure AS
SELECT l.llc_id,
       l.project_id,
       l.project_number,
       l.project_name,
       p.customer_name,
       l.revenue_model,
       l.period_id,
       l.period_name,
       l.absent_employee_id,
       l.absent_employee_name,
       l.absence_date,
       l.absence_day,
       l.absence_type,
       l.cover_employee_id,
       l.cover_employee_name,
       l.llc_status,
       l.approved_by,
       l.approved_on
  FROM v_oc_ts_llc l
  JOIN oc_time_project p ON p.project_id = l.project_id
 WHERE l.llc_status = 'Approved'
   AND l.cover_employee_id IS NOT NULL
   -- THE INVOICE SELF-CORRECTS. An approved coverage whose absence has since
   -- been withdrawn stays on OC_TS_LEAVE_LOSS_COVER -- the manager's decision
   -- is theirs -- but it must not travel with an invoice claiming somebody
   -- covered a day nobody was away.
   AND l.absence_exists = 'Y';

PROMPT ============================================================
PROMPT [3/4] OC_TIME_RETRACT_LLC — drop the lines with nothing behind them
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_retract_llc(
  p_project_id  IN  NUMBER   DEFAULT NULL,
  p_period_id   IN  NUMBER   DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'ABSENCE_SYNC',
  o_removed     OUT NUMBER,
  o_orphaned    OUT NUMBER)
IS
BEGIN
  -- Open and Assigned only. An Approved line is a decision and is left alone;
  -- the annexure already stops carrying it, and o_orphaned counts them so the
  -- caller can say so.
  DELETE FROM oc_ts_leave_loss_cover l
   WHERE l.llc_status IN ('Open','Assigned')
     AND (p_project_id IS NULL OR l.project_id = p_project_id)
     AND (p_period_id  IS NULL OR l.period_id  = p_period_id)
     AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                      WHERE ab.employee_id     = l.absent_employee_id
                        AND ab.absence_date    = l.absence_date
                        AND ab.approval_status = 'Approved');
  o_removed := SQL%ROWCOUNT;

  SELECT COUNT(*) INTO o_orphaned
    FROM oc_ts_leave_loss_cover l
   WHERE l.llc_status = 'Approved'
     AND (p_project_id IS NULL OR l.project_id = p_project_id)
     AND (p_period_id  IS NULL OR l.period_id  = p_period_id)
     AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                      WHERE ab.employee_id     = l.absent_employee_id
                        AND ab.absence_date    = l.absence_date
                        AND ab.approval_status = 'Approved');
END oc_time_retract_llc;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

DECLARE
  v_rem NUMBER; v_orp NUMBER;
BEGIN
  oc_time_retract_llc(NULL, NULL, 'FIX_96', v_rem, v_orp);
  DBMS_OUTPUT.PUT_LINE('  ' || v_rem || ' stale line(s) removed, '
    || v_orp || ' approved line(s) orphaned.');
  COMMIT;
END;
/

COLUMN absent FORMAT A24
COLUMN cover  FORMAT A24
COLUMN proj   FORMAT A10
SELECT l.project_number AS proj, l.absence_date AS on_date,
       l.absent_employee_name AS absent, l.loss_hours,
       NVL(l.cover_employee_name,'(none)') AS cover,
       l.llc_status, l.absence_exists
  FROM v_oc_ts_llc l
 ORDER BY l.project_number, l.absence_date, l.absent_employee_name;

PROMPT
PROMPT ABSENCE_EXISTS must be Y on every row above. An N is an approved
PROMPT coverage whose absence has been withdrawn: it keeps its row, because a
PROMPT manager decided it, and it is already off the annexure. Revoke it from
PROMPT the screen rather than deleting it here.

PROMPT
PROMPT What the invoice would carry. Nothing whose absence has gone.

SELECT project_number, absence_date, absent_employee_name, cover_employee_name
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;
