--==============================================================
-- time/25_absence_source.sql
-- O2C Timesheet Module — leave is its own source, not a manager edit
--
-- Reported 12-Aug-2026: the approval workflow on a week containing leave read
--
--     Edited by the manager (2026-08-17) by sampaul.jeevan@rite.digital
--
-- No manager edited anything. Leave arrived from Absence Management.
--
-- WHY IT SAID THAT
--   TRG_OC_TSE_AUDIT_CAPTURE classifies a change by OC_TS_ENTRY.SOURCE:
--     'Manager' -> Override, 'Import' -> Import, 'Job' -> DefaultCorrection,
--     anything else -> ManagerEdit.
--   The absence MERGE in populate_month never set SOURCE on its UPDATE branch,
--   so a prepopulated day that later received leave kept 'Prepopulated' -- a
--   value with no case of its own -- and fell through to ManagerEdit.
--
--   The default was wrong in a way that matters: it named a person as having
--   done something they did not do, on a screen whose entire purpose is to be
--   the audit trail.
--
-- WHAT CHANGES
--   * SOURCE gains 'Absence'. populate_month sets it on both branches (time/09)
--   * CHANGE_TYPE gains 'AbsenceSync'
--   * the trigger maps one to the other
--
-- The stored SOURCE is also what records that these hours came from the
-- absence module, which is why the timesheet grid no longer carries a chip
-- saying so -- the fact lives in the database rather than in a label.
--
-- Idempotent. Depends on: time/03, time/04, time/09
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] OC_TS_ENTRY.SOURCE accepts 'Absence'
PROMPT ============================================================

DECLARE
  PROCEDURE swap(p_table VARCHAR2, p_con VARCHAR2, p_check VARCHAR2) IS
  BEGIN
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' DROP CONSTRAINT ' || p_con;
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE != -2443 THEN RAISE; END IF;   -- -2443 = no such constraint
    END;
    EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' ADD CONSTRAINT '
                   || p_con || ' CHECK (' || p_check || ')';
    DBMS_OUTPUT.PUT_LINE(p_con || ' redefined');
  END;
BEGIN
  swap('oc_ts_entry', 'chk_oc_tse_source',
       q'~source IN ('Prepopulated','Employee','Manager','Job','Import','Absence')~');

  -- Existing leave rows carry whatever they were written with. Correcting them
  -- now means the workflow reads correctly for weeks already on screen, and it
  -- is safe: IS_LEAVE='Y' is only ever set by the absence path.
  UPDATE oc_ts_entry SET source = 'Absence'
   WHERE is_leave = 'Y' AND NVL(source,'x') <> 'Absence';
  DBMS_OUTPUT.PUT_LINE('existing leave rows restamped: ' || SQL%ROWCOUNT);
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [2/4] OC_TS_AUDIT.CHANGE_TYPE accepts 'AbsenceSync'
PROMPT ============================================================

-- CORRECTED 15-Aug-2026. This dropped and re-added 'chk_oc_tsa_ctype'. The
-- constraint 04_approval_audit.sql actually creates is 'chk_oc_tsau_type' --
-- different name. So the DROP failed with ORA-02443, which the handler
-- swallowed, a SECOND constraint was added, and the ORIGINAL one, which does
-- not allow AbsenceSync, stayed in force. A row has to satisfy both.
--
-- The comment below predicted exactly this and said the trigger "will raise
-- loudly on the first leave row if this did not take". It did not raise,
-- because nothing wrote AbsenceSync to OC_TS_AUDIT until 44 came along months
-- later -- so the prediction was right and the detection never fired. A
-- warning that depends on an untravelled code path is not a warning.
--
-- Now driven off the dictionary: every CHECK on CHANGE_TYPE is widened,
-- whatever it is called.
DECLARE
  v_done NUMBER := 0;
BEGIN
  FOR c IN (SELECT constraint_name
              FROM user_constraints
             WHERE table_name      = 'OC_TS_AUDIT'
               AND constraint_type = 'C'
               AND UPPER(search_condition_vc) LIKE '%CHANGE_TYPE%'
               -- NOT NULL is a CHECK constraint too, rendered as
               -- "CHANGE_TYPE" IS NOT NULL, so it matches the filter above.
               -- Dropping it silently makes the column nullable.
               AND UPPER(search_condition_vc) NOT LIKE '%IS NOT NULL%')
  LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_audit DROP CONSTRAINT ' || c.constraint_name;
    DBMS_OUTPUT.PUT_LINE('  dropped ' || c.constraint_name);
    v_done := v_done + 1;
  END LOOP;

  EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_audit ADD CONSTRAINT chk_oc_tsau_type
    CHECK (change_type IN ('Override','Adjustment','Reversal','ManagerEdit',
                           'Import','DefaultCorrection','AbsenceSync'))~';
  DBMS_OUTPUT.PUT_LINE('chk_oc_tsau_type redefined ('
                    || v_done || ' old constraint(s) removed)');
END;
/

PROMPT ============================================================
PROMPT [3/4] The trigger learns the new source
PROMPT ============================================================

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
              -- NEW. Without this, leave lands as ManagerEdit and the workflow
              -- accuses a named person of an edit they did not make.
              WHEN 'Absence' THEN 'AbsenceSync'
              ELSE 'ManagerEdit'
            END;

  IF :NEW.source = 'Employee' THEN RETURN; END IF;

  INSERT INTO oc_ts_audit (
    ts_entry_id, ts_week_id, employee_id, entry_date, change_type,
    old_project_id, old_task_id, old_hours, old_bill_type, old_reason,
    new_project_id, new_task_id, new_hours, new_bill_type, new_reason,
    changed_by)
  VALUES (
    :NEW.ts_entry_id, :NEW.ts_week_id, v_emp, :NEW.entry_date, v_type,
    :OLD.project_id, :OLD.task_id, :OLD.hours, :OLD.billable_type, :OLD.unbilled_reason,
    :NEW.project_id, :NEW.task_id, :NEW.hours, :NEW.billable_type, :NEW.unbilled_reason,
    NVL(:NEW.updated_by, :NEW.created_by));
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN source FORMAT A14
SELECT source, is_leave, COUNT(*) AS entries
  FROM oc_ts_entry GROUP BY source, is_leave ORDER BY source, is_leave;

PROMPT
PROMPT Every IS_LEAVE='Y' row should read SOURCE='Absence'. That is the record
PROMPT that these hours came from Absence Management -- the grid no longer says
PROMPT it in a chip, so this column is where it lives.

COLUMN change_type FORMAT A20
SELECT change_type, COUNT(*) AS rows_ FROM oc_ts_audit
 GROUP BY change_type ORDER BY change_type;

PROMPT
PROMPT Existing ManagerEdit rows against leave days are HISTORY and are left
PROMPT alone -- rewriting an audit trail to make it read better is exactly what
PROMPT an audit trail must never do. New ones will say AbsenceSync.
