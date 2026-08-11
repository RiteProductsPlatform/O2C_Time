--==============================================================
-- time/23_unbilled_reason_per_line.sql
-- O2C Timesheet Module — the unbilled reason moves from the task to the line
--
-- Decided 11-Aug-2026, together with dropping PRJ-ORG.
--
-- WHAT CHANGED AND WHY
--
-- PRJ-ORG was the Organization (Non-Billable) project, implicitly everyone's
-- (FLD-006), and it was where non-project time went. It is gone: every project
-- in this schema now comes from Fusion, and PRJ-ORG never did -- it existed
-- only here, so it could not be costed, reported on, or reconciled against PPM.
--
-- The hours it carried have to go somewhere, and the better place is the
-- employee's REAL project with a reason on the line saying why they are not
-- billable. The hours stay attached to the engagement that incurred them, and
-- the reason is recorded per line rather than per project.
--
-- THE RULE THIS REPLACES
--   RULE-002 / ACT-007: the TASK decides billable type, and for a non-billable
--   task the reason IS the task. TRG_OC_TSE_DERIVE enforced it by NULLING
--   UNBILLED_REASON on any billable line.
--
-- THE RULE NOW
--   The task still decides by DEFAULT. But a reason supplied on the line is
--   respected on ANY line, and a line that carries one is Non-billable --
--   because that is what the reason means. Saying "why these hours are not
--   billable" and leaving them billable would be a contradiction the accrual
--   would then have to resolve on its own.
--
-- ABSENCE IS EXCLUDED, deliberately. A leave line comes from HCM through the
-- absence sync (RULE-008, IS_LEAVE='Y'); nobody chooses it and nobody should
-- be asked to justify it. Its reason stays whatever the leave type set.
--
-- WHAT THIS MEANS DOWNSTREAM -- worth being explicit, because it is money.
-- BILLABLE_TYPE drives the accrual interface and the invoice annexure. Hours
-- that used to be billable become non-billable the moment someone picks a
-- reason, so the reason is not a note: it changes what is billed. That is the
-- point, and it is why the dropdown must not be offered on absence lines,
-- where it would be meaningless.
--
-- Idempotent. Depends on: time/03, time/10
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] TRG_OC_TSE_DERIVE — the reason now wins
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tse_derive
BEFORE INSERT OR UPDATE ON oc_ts_entry
FOR EACH ROW
DECLARE
  v_bill   oc_time_task.billable_type%TYPE;
  v_reason oc_time_task.unbilled_reason%TYPE;
BEGIN
  SELECT billable_type, unbilled_reason
    INTO v_bill, v_reason
    FROM oc_time_task
   WHERE task_id = :NEW.task_id;

  IF NVL(:NEW.is_leave, 'N') = 'Y' THEN
    -- Absence, from HCM. Not chosen by anyone, so not justified by anyone.
    -- The task's own values stand and the line is left alone.
    :NEW.billable_type   := v_bill;
    :NEW.unbilled_reason := NVL(:NEW.unbilled_reason, v_reason);

  ELSIF :NEW.unbilled_reason IS NOT NULL THEN
    -- A reason was given on the LINE. It wins, on a billable task as much as a
    -- non-billable one -- this is what replaces booking the hours to PRJ-ORG.
    -- The line is Non-billable BECAUSE a reason was given: the reason says the
    -- hours are not billable, so leaving BILLABLE_TYPE alone would put a
    -- contradiction into the accrual for it to resolve on its own.
    :NEW.billable_type := 'Non-billable';

  ELSE
    -- No reason on the line: the task decides, exactly as before. A
    -- non-billable task still supplies its own reason, so the common tasks
    -- keep working untouched (RULE-002).
    :NEW.billable_type := v_bill;
    IF v_bill = 'Non-billable' THEN
      :NEW.unbilled_reason := v_reason;
    END IF;
  END IF;

  IF INSERTING THEN
    :NEW.created_on := NVL(:NEW.created_on, SYSTIMESTAMP);
  ELSE
    :NEW.updated_on := SYSTIMESTAMP;
  END IF;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/3] The reasons the dropdown offers
PROMPT ============================================================

-- A view rather than the page holding a list. The page renders whatever is
-- here, so adding a reason is a row, not a release -- and every caller,
-- including one hitting ORDS directly, sees the same set.
CREATE OR REPLACE VIEW v_oc_ts_unbilled_reason_lov AS
SELECT lookup_code   AS reason_code,
       meaning       AS reason_name,
       sort_order
  FROM oc_time_lookup
 WHERE lookup_type = 'unbilled_reason'
   -- ACTIVE_FLAG and SELECTABLE, not ENABLED_FLAG -- OC_TIME_LOOKUP has both
   -- and neither is called that. SELECTABLE is the one that decides whether a
   -- value may be CHOSEN: a reason can stay active, so historical rows still
   -- render it, while being withdrawn from the picker.
   AND active_flag = 'Y'
   AND selectable  = 'Y'
 ORDER BY sort_order, meaning;

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A32
COLUMN status      FORMAT A8
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('TRG_OC_TSE_DERIVE', 'V_OC_TS_UNBILLED_REASON_LOV')
 ORDER BY object_name;

COLUMN reason_name FORMAT A40
SELECT reason_code, reason_name FROM v_oc_ts_unbilled_reason_lov;

PROMPT
PROMPT The list above is what the per-line dropdown offers. If it is empty,
PROMPT 10_seed.sql section [4/11] has not run.

PROMPT
PROMPT ============================================================
PROMPT PRJ-ORG — remove the row, if this schema still has it
PROMPT ============================================================

-- Not run automatically. Entries may still point at it, and a delete that
-- cascades through timesheet history is not something a script should decide
-- on its own. Check first, then run the DELETE by hand.
DECLARE
  v_id NUMBER;
  v_e  NUMBER := 0;
  v_a  NUMBER := 0;
BEGIN
  SELECT MAX(project_id) INTO v_id
    FROM oc_time_project WHERE project_number = 'PRJ-ORG';

  IF v_id IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('PRJ-ORG is not in this schema. Nothing to do.');
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_e FROM oc_ts_entry      WHERE project_id = v_id;
  SELECT COUNT(*) INTO v_a FROM oc_time_allocation WHERE project_id = v_id;

  DBMS_OUTPUT.PUT_LINE('PRJ-ORG is project_id ' || v_id);
  DBMS_OUTPUT.PUT_LINE('   timesheet entries on it : ' || v_e);
  DBMS_OUTPUT.PUT_LINE('   allocations on it       : ' || v_a);
  DBMS_OUTPUT.PUT_LINE('');
  IF v_e = 0 AND v_a = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Nothing depends on it. Safe to remove:');
    DBMS_OUTPUT.PUT_LINE('   DELETE FROM oc_time_project WHERE project_id = '
                      || v_id || '; COMMIT;');
  ELSE
    DBMS_OUTPUT.PUT_LINE('THOSE ROWS WOULD GO WITH IT. Move the hours to a real '
                      || 'project with an unbilled reason first, or clear the '
                      || 'period with 90_demo_reset.sql, then re-check.');
  END IF;
END;
/
