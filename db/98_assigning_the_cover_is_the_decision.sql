--==============================================================
-- time/98_assigning_the_cover_is_the_decision.sql
-- O2C Timesheet Module — one step, because the manager is the one taking it
--
-- Asked 21-Aug: "in LLC there is only step if we assign its approved only
-- because its the manager who is doing that there is no approval there. lets
-- keep it as 'Assigned'".
--
-- Checked against the BRD before changing anything, and the BRD agrees. 4.2.1:
--
--   "...against each entry will have ability to capture an employee id - this
--    drop down will display only employee who are marked as Unbilled in the
--    same project and who are not absent on that date in consideration. ONCE
--    EACH LINE IS FILLED IT IS APPROVED - treatment is as follows..."
--
-- Filling the line IS the approval. The sentence states a consequence and then
-- says what the consequence means; it does not describe a second action.
--
-- THE REQUIREMENT PACK SAYS OTHERWISE AND IS THE DERIVED ARTEFACT. It carries
-- ACT-022 "Assign Leave-Loss Cover" and ACT-023 "Approve Leave-Loss Coverage"
-- as separate actions, and SC-12 reads "Assign unbilled cover; approve". Those
-- were derived from the sentence above, in a pack still marked v0.3 Draft, and
-- the two-step flow was built from them. The source and the functional owner
-- agree with each other; only the derivation disagrees with both.
--
-- WHAT CHANGES
--
--   Assigned becomes terminal. There is no Approve, no Approve-all, and no
--   'Approved' produced from here on.
--
--   The annexure accepts Assigned. It required 'Approved', which would have
--   emptied it the moment the button went.
--
--   Retraction changes with it. db/96 deleted Open AND Assigned lines whose
--   absence had gone, on the reasoning that neither had asserted anything
--   downstream -- true when Assigned was a pending intention, false now that it
--   IS the decision and reaches the invoice. Only OPEN lines are deleted;
--   Assigned is kept, drops off the annexure through ABSENCE_EXISTS, and is
--   reported so somebody can unassign it deliberately. Exactly the treatment
--   Approved had.
--
-- EXISTING 'Approved' ROWS ARE LEFT ALONE. llc 4 was approved under the old
-- flow and that happened; rewriting it to 'Assigned' would edit a record of
-- something somebody did. The annexure and the retraction both accept either.
--
-- Idempotent. Supersedes db/96 [2/4] and [3/4]. Depends on: time/05, 08, 09, 96.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'V_OC_TS_LLC' AND column_name = 'ABSENCE_EXISTS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/96 has not been run: V_OC_TS_LLC.ABSENCE_EXISTS is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] The annexure takes an assigned cover
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
       -- ASSIGNED_BY is the decision-maker now. APPROVED_BY only ever holds a
       -- name for rows decided under the old two-step flow, so the downstream
       -- reads whichever is present rather than picking one and losing the
       -- other.
       NVL(l.assigned_by, l.approved_by) AS decided_by,
       NVL(l.assigned_on, l.approved_on) AS decided_on
  FROM v_oc_ts_llc l
  JOIN oc_time_project p ON p.project_id = l.project_id
 -- 'Assigned' OR 'Approved'. Naming a cover is the decision (BRD 4.2.1: "once
 -- each line is filled it is approved"), so Assigned reaches the invoice.
 -- 'Approved' stays admissible because rows decided under the old flow carry it
 -- and did happen.
 WHERE l.llc_status IN ('Assigned','Approved')
   AND l.cover_employee_id IS NOT NULL
   -- An absence withdrawn after the fact must not travel with an invoice
   -- claiming somebody covered a day nobody was away.
   AND l.absence_exists = 'Y';

PROMPT ============================================================
PROMPT [2/4] Retraction: only an OPEN line is safe to delete
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_retract_llc(
  p_project_id  IN  NUMBER   DEFAULT NULL,
  p_period_id   IN  NUMBER   DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'ABSENCE_SYNC',
  o_removed     OUT NUMBER,
  o_orphaned    OUT NUMBER)
IS
BEGIN
  -- OPEN ONLY. db/96 also deleted Assigned, on the reasoning that an assigned
  -- line was a manager's pending intention and nothing downstream depended on
  -- it. That was true while a second click was needed; naming the cover is now
  -- the whole decision and it reaches the invoice, so deleting it silently
  -- would erase the thing somebody actually did.
  --
  -- An Open line is still a to-do, and removing a to-do for an absence that did
  -- not happen is housekeeping.
  DELETE FROM oc_ts_leave_loss_cover l
   WHERE l.llc_status = 'Open'
     AND (p_project_id IS NULL OR l.project_id = p_project_id)
     AND (p_period_id  IS NULL OR l.period_id  = p_period_id)
     AND NOT EXISTS (SELECT 1 FROM oc_time_absence ab
                      WHERE ab.employee_id     = l.absent_employee_id
                        AND ab.absence_date    = l.absence_date
                        AND ab.approval_status = 'Approved');
  o_removed := SQL%ROWCOUNT;

  -- Decided, and the absence behind it has gone. Already off the annexure via
  -- ABSENCE_EXISTS; counted here so the screen can say there is something to
  -- unassign.
  SELECT COUNT(*) INTO o_orphaned
    FROM oc_ts_leave_loss_cover l
   WHERE l.llc_status IN ('Assigned','Approved')
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
PROMPT [3/4] APPROVE_COVER is retired
PROMPT ============================================================

-- Retired the way approve_day and reject_day were when day-level approval went
-- (-20027): the procedure stays so a stale caller gets a sentence rather than
-- PLS-00201, and the sentence says what replaced it.
CREATE OR REPLACE PROCEDURE oc_time_approve_cover(
  p_llc_id       IN NUMBER,
  p_actor_emp_id IN VARCHAR2,
  p_actor        IN VARCHAR2 DEFAULT 'VBCS_USER')
IS
BEGIN
  RAISE_APPLICATION_ERROR(-20033,
    'Leave-loss coverage has one step. Naming the covering colleague IS the '
    || 'decision (BRD 4.2.1), so assign_cover completes it and the line reaches '
    || 'the invoice annexure as Assigned. There is nothing left to approve.');
END oc_time_approve_cover;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

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
PROMPT Every row with a cover named should now be on the annexure below,
PROMPT whether it says Assigned or Approved.

SELECT project_number, absence_date, absent_employee_name,
       cover_employee_name, llc_status, decided_by
  FROM v_oc_ts_llc_annexure
 ORDER BY project_number, absence_date;

PROMPT
PROMPT NEXT: run db/ords/12_ords_time_approval.sql. Its llc/:id/approve handler
PROMPT still calls the retired procedure and would answer 400 with the sentence
PROMPT above; the screen no longer offers the button either way.
