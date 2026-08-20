--==============================================================
-- time/85_llc_project_share_and_correction.sql
-- O2C Timesheet Module — the leave-loss screen's hours, and the correction
-- button that has never worked
--
-- Three faults reported from the screen on 20-Aug, two of them the same shape:
-- a number that is honestly recorded somewhere and wrongly presented somewhere
-- else.
--
-- ── 1. THE ABSENCE IS 8 HOURS. THE LOSS TO THIS PROJECT IS 2 ──────────────
--
-- PAGE-006 showed 8.00 against Sam Joshuva S on 555. Sam is allocated 25% to
-- 555, so a day of his leave costs that project 2 hours, not 8 -- the other 6
-- belong to 444 and PCS10034, which have their own managers and their own
-- contracts. OC_TS_LEAVE_LOSS_COVER is scoped BY PROJECT, so a project row
-- displaying the whole-company absence overstates that project's loss
-- fourfold, and the "hours recovered as billed" total inherits the same error.
--
-- ABSENCE_HOURS stays what it is: the absence, as Absence Management recorded
-- it. That is a fact about the person and it should not be quietly rewritten
-- to mean something else. LOSS_HOURS is the derived, project-scoped number and
-- it is what the screen shows.
--
-- ONE DEFINITION, NOT TWO. db/84's oc_time_cover_billing already computed this
-- inside PL/SQL. Leaving that copy in place and adding a second in the view
-- would let the screen and the billing disagree about the same day -- which is
-- exactly the disagreement db/84 was written to end. So the view is now the
-- definition and the procedure reads LOSS_HOURS from it.
--
-- Capped at ABSENCE_HOURS, which db/84 was not. A 100%-allocated person taking
-- a half day loses 4 hours, not their standard 8; without the cap the loss
-- exceeds the absence that caused it.
--
-- ── 2. "APPLY CORRECTION" RAISES ORA-20026 EVERY TIME ─────────────────────
--
-- Measured against ORDS SIT, 20-Aug:
--
--   POST /oc/time/approval/override/174892
--   400 {"error":"OC_TS_AUDIT is append-only. A correction is a NEW row,
--        never an edit to an existing one ..."}
--
-- override_approve ends by stamping the manager's reason onto the audit row
-- the capture trigger has just written:
--
--   UPDATE oc_ts_audit SET change_reason = p_reason, trace_id = p_trace_id
--    WHERE audit_id = (SELECT MAX(audit_id) ...);
--
-- and db/19 put a BEFORE UPDATE OR DELETE trigger on that table which refuses
-- every UPDATE unconditionally. The two were written against each other. It
-- fires at STATEMENT level, so it raises even when the WHERE matches nothing --
-- there is no input for which this path succeeds, and ACT-016 has been dead
-- since db/19 was applied.
--
-- Both sides are right, which is why neither is simply reverted. The trail must
-- not be editable; the correction must carry its reason. The reason therefore
-- has to be present when the row is INSERTED, and the only thing that can carry
-- it from the caller into a row trigger is session state. OC_TIME_CTX holds it
-- for the duration of the one statement.
--
-- NOT SYS_CONTEXT: that needs CREATE ANY CONTEXT, and this module has already
-- decided once (DBMS_CRYPTO, 01-Aug) not to ask for grants it can do without.
-- A package global is session-private, needs no grant, and dies with the call.
--
-- RUN ORDER: this file FIRST, then db/09 -- override_approve is edited there to
-- set the context, and it will not compile until OC_TIME_CTX exists.
--
-- ── 3. A ROW APPROVED BEFORE db/84 WAS WIRED ──────────────────────────────
--
-- llc_id 4 reads BILLED_FLAG='Y' with COVER_HOURS_BILLED null: it was approved
-- through the old handler, which set the flag and moved nothing. Section [5/6]
-- completes those rather than leaving the screen claiming a recovery that never
-- happened.
--
-- Idempotent. Depends on: time/04, 05, 08, 09, 19, 25, 84.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables
   WHERE table_name = 'OC_TS_LEAVE_LOSS_COVER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TS_LEAVE_LOSS_COVER' AND column_name = 'COVER_HOURS_BILLED';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'db/84 has not been run here: '
      || 'OC_TS_LEAVE_LOSS_COVER.COVER_HOURS_BILLED is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/6] V_OC_TS_LLC gains LOSS_HOURS, the project's share
PROMPT ============================================================

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
       -- THE PROJECT'S SHARE OF THAT ABSENCE, and the module's one definition
       -- of it -- oc_time_cover_billing reads this column rather than keeping
       -- its own copy of the arithmetic.
       --
       -- The standard day is the one the timesheet actually used for that date
       -- (a work pattern can vary it) and falls back to the worker's own
       -- STD_HOURS_PER_DAY, never a global 8: several people here are on nine.
       --
       -- Rounded to the quarter CHK_OC_TSE_QUARTER requires, then capped at the
       -- absence itself -- a 100% allocation against a half day loses the half
       -- day, not a whole one.
       LEAST(
         ROUND(
           NVL((SELECT MAX(al.alloc_pct)
                  FROM oc_time_allocation al
                 WHERE al.employee_id = l.absent_employee_id
                   AND al.project_id  = l.project_id
                   AND al.status      = 'Active'
                   AND l.absence_date BETWEEN al.start_date
                                          AND NVL(al.end_date, l.absence_date)), 0)
           * NVL((SELECT MAX(e.standard_hours)
                    FROM oc_ts_entry e
                    JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
                   WHERE w.employee_id = l.absent_employee_id
                     AND e.entry_date  = l.absence_date),
                 aw.std_hours_per_day)
           / 100 * 4) / 4,
         l.absence_hours)                     AS loss_hours,
       l.cover_employee_id,                                 -- FLD-064
       cw.employee_name AS cover_employee_name,
       l.llc_status,                                        -- FLD-065
       l.billed_flag,
       -- What actually moved to a billable task. NULL means nothing has, which
       -- is a different statement from zero and the screen renders it as such.
       l.cover_hours_billed,
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
PROMPT [2/6] OC_TIME_CTX — the reason, carried into the audit INSERT
PROMPT ============================================================

CREATE OR REPLACE PACKAGE oc_time_ctx AS
  -- Set immediately before a write, read by TRG_OC_TSE_AUDIT_CAPTURE, cleared
  -- immediately after. Session-private and short-lived by construction: two
  -- callers cannot see each other's value, and a value left behind by a failed
  -- call would be visible to the next one on the same session, which is why
  -- every setter is paired with clear() on the normal AND the exception path.
  g_change_reason VARCHAR2(1000);
  g_trace_id      VARCHAR2(64);

  PROCEDURE set_reason(p_reason IN VARCHAR2, p_trace_id IN VARCHAR2 DEFAULT NULL);
  PROCEDURE clear;
END oc_time_ctx;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE BODY oc_time_ctx AS
  PROCEDURE set_reason(p_reason IN VARCHAR2, p_trace_id IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    g_change_reason := SUBSTR(p_reason, 1, 1000);
    g_trace_id      := SUBSTR(p_trace_id, 1, 64);
  END set_reason;

  PROCEDURE clear IS
  BEGIN
    g_change_reason := NULL;
    g_trace_id      := NULL;
  END clear;
END oc_time_ctx;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/6] TRG_OC_TSE_AUDIT_CAPTURE writes the reason at INSERT time
PROMPT ============================================================

-- Unchanged from db/25 except for the two trailing columns. Repeated in full
-- rather than patched, because a trigger cannot be altered a column at a time
-- and a partial copy here would silently drop the AbsenceSync case db/25 added.
CREATE OR REPLACE TRIGGER trg_oc_tse_audit_capture
BEFORE UPDATE OF hours, project_id, task_id, unbilled_reason ON oc_ts_entry
FOR EACH ROW
DECLARE
  v_emp  oc_ts_week.employee_id%TYPE;
  v_type oc_ts_audit.change_type%TYPE;
BEGIN
  IF NVL(:OLD.hours,-1)           = NVL(:NEW.hours,-1)
 AND NVL(:OLD.project_id,-1)      = NVL(:NEW.project_id,-1)
 AND NVL(:OLD.task_id,-1)         = NVL(:NEW.task_id,-1)
 AND NVL(:OLD.unbilled_reason,'~')= NVL(:NEW.unbilled_reason,'~') THEN
    RETURN;
  END IF;

  SELECT employee_id INTO v_emp FROM oc_ts_week WHERE ts_week_id = :NEW.ts_week_id;

  v_type := CASE :NEW.source
              WHEN 'Manager' THEN 'Override'
              WHEN 'Import'  THEN 'Import'
              WHEN 'Job'     THEN 'DefaultCorrection'
              WHEN 'Absence' THEN 'AbsenceSync'
              ELSE 'ManagerEdit'
            END;

  IF :NEW.source = 'Employee' THEN RETURN; END IF;

  INSERT INTO oc_ts_audit (
    ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
    old_project_id, old_task_id, old_hours, old_bill_type, old_reason,
    new_project_id, new_task_id, new_hours, new_bill_type, new_reason,
    changed_by,
    -- WRITTEN HERE, NOT STAMPED AFTERWARDS. OC_TS_AUDIT is append-only
    -- (db/19), so the reason has one chance to be recorded and this is it.
    -- Null when the caller set nothing, which is the honest answer for a
    -- change that arrived without one.
    change_reason, trace_id)
  VALUES (
    :NEW.ts_entry_id, :NEW.ts_week_id, v_emp, :NEW.entry_date, v_type,
    :OLD.project_id, :OLD.task_id, :OLD.hours, :OLD.billable_type, :OLD.unbilled_reason,
    :NEW.project_id, :NEW.task_id, :NEW.hours, :NEW.billable_type, :NEW.unbilled_reason,
    NVL(:NEW.updated_by, :NEW.created_by),
    oc_time_ctx.g_change_reason, oc_time_ctx.g_trace_id);
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/6] OC_TIME_COVER_BILLING - superseded, see db/86
PROMPT ============================================================

-- THIS SECTION DELIBERATELY DOES NOTHING NOW.
--
-- It created OC_TIME_COVER_BILLING guarded by oc_time_pkg.assert_editable,
-- which is the EMPLOYEE's editability gate. Running this file after db/86
-- would put that guard back, and the symptom would be llc rows refusing with
-- "This week is locked. Only a manager can edit a defaulted timesheet." --
-- a message aimed at the employee, raised at a manager doing the one thing it
-- says a manager may do.
--
-- Commented out rather than deleted, for the same reason 01_time_reference.sql
-- keeps UK_OC_TP_SINGLE_OPEN commented rather than removed: a re-run that
-- silently restores a withdrawn rule is worse than a file with a hole in it.
--
-- The live definition is db/86_annexure_bills_what_moved.sql [2/5].

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_COVER_BILLING' AND object_type = 'PROCEDURE';
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  OC_TIME_COVER_BILLING does not exist yet - run db/86.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  Left alone. The live definition is db/86 [2/5].');
  END IF;
END;
/


PROMPT ============================================================
PROMPT [5/6] Complete the rows approved before the billing was wired
PROMPT ============================================================

DECLARE
  v_h   NUMBER;
  v_msg VARCHAR2(400);
  v_n   NUMBER := 0;
BEGIN
  FOR r IN (SELECT llc_id
              FROM oc_ts_leave_loss_cover
             WHERE llc_status = 'Approved'
               AND billed_flag = 'Y'
               AND cover_hours_billed IS NULL
             ORDER BY llc_id)
  LOOP
    BEGIN
      oc_time_cover_billing(r.llc_id, 'Y', 'FIX_85', v_h, v_msg);
      DBMS_OUTPUT.PUT_LINE('  llc ' || r.llc_id || ': ' || v_msg);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      -- A week that has since locked, or a cover whose non-billable line has
      -- gone, is reported and skipped: one unfinishable row must not stop the
      -- rest, and inventing the hours would be worse than saying so.
      DBMS_OUTPUT.PUT_LINE('  llc ' || r.llc_id || ': NOT COMPLETED - '
                           || SUBSTR(SQLERRM,1,200));
    END;
  END LOOP;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Nothing to complete.');
  END IF;
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [6/6] Verification
PROMPT ============================================================

COLUMN absent FORMAT A22
COLUMN cover  FORMAT A22
COLUMN proj   FORMAT A10
SELECT l.llc_id, l.project_number AS proj,
       TO_CHAR(TO_DATE(l.absence_date,'YYYY-MM-DD'),'DD-Mon') AS on_date,
       l.absent_employee_name AS absent,
       l.absence_hours, l.loss_hours,
       NVL(l.cover_employee_name,'(none)') AS cover,
       l.llc_status, l.billed_flag,
       NVL(TO_CHAR(l.cover_hours_billed),'-') AS billed_hrs
  FROM v_oc_ts_llc l
 ORDER BY l.project_number, l.absence_date, l.absent_employee_name;

PROMPT
PROMPT LOSS_HOURS is the project's share and is what PAGE-006 now shows.
PROMPT ABSENCE_HOURS stays the whole absence. For a 25% allocation on an
PROMPT 8-hour day those read 2.00 and 8.00 respectively.

PROMPT
PROMPT Any Approved row still showing BILLED_HRS as a dash could not be
PROMPT completed; section [5/6] printed the reason for each one above.

PROMPT
PROMPT NEXT: run db/86_annexure_bills_what_moved.sql, then
PROMPT db/09_pkg_oc_time.sql. 86 stops the invoice annexure billing the whole
PROMPT absence and gives the billing a manager's guard instead of the
PROMPT employee's; 09 recompiles override_approve, and the Apply correction
PROMPT button stays broken until it is.
