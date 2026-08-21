--==============================================================
-- time/104_a_manager_may_approve_their_own_week.sql
-- O2C Timesheet Module — RULE-015 is relaxed, on instruction
--
-- ── THE DECISION, AND THAT IT CONTRADICTS THE PACK ───────────
--
-- Asked 21-Aug-2026, explicitly, after the alternatives were put and declined:
-- a manager may approve their own timesheet.
--
-- This REVERSES a rule the requirement pack states as blocking. From
-- O2C_Timesheet_Requirements_Metadata_COMPLETE.xlsx, Document_Control sheet:
--
--   RULE-015 | Manager cannot approve own timesheet | security | Approval (all)
--            | pre-action | approver != timesheet_owner
--            | "A manager's own time is approved by their reporting manager."
--            | blocking | Correction #1 | reports-to, never self
--
-- "Correction #1" means it was revisited once and reaffirmed, so it is not a
-- first-draft rule nobody looked at again. Every session transcript in this
-- project was searched for a prior decision to relax it and there is none.
-- Recording that here because the pack and the code now disagree, and whoever
-- reads one without the other will conclude the code is wrong.
--
-- REQ-PACK ACTION: RULE-015 and SC-07 both need amending. Not done here — the
-- pack is an input to this repo, not an output of it.
--
-- ── WHAT ACTUALLY PROMPTED IT, AND WHY THAT MATTERS ──────────
--
-- July could not be confirmed on 555: RI9001 Navamani is the project manager
-- AND a 25% allocated resource, so his own week sat Pending and RULE-020 held
-- the month. But the rule was only the visible half. Measured on the pod:
--
--   RI9001  Navamani Solairajan             reports-to = NONE
--   RI2894  Santosh Kumar Kanala            reports-to = NONE
--   RI2824  Sam Joshuva S                   reports-to = NONE
--   RI2900  SaiSowmith Kantipudi            reports-to = NONE
--   CRI0398 Kishore Krovvidi                reports-to = NONE
--   RI2914  Venkata Bhaskar Reddy Sangana   reports-to = NONE
--   7781    User Rite                       reports-to = 4675, not on the project
--
-- MANAGER_EMP_ID is empty for the whole team. So the rule had nobody to route
-- the week TO. It was not "a manager may not approve their own time", it was
-- "no approver exists", and the month was unconfirmable for as long as that
-- stayed true.
--
-- ** THAT SECOND PROBLEM IS NOT FIXED BY THIS SCRIPT. ** Self-approval removes
-- the symptom on 555 because the manager is on their own project. A team whose
-- manager is NOT allocated to it still has no reporting line, and RULE-015 was
-- the only thing that would have made the gap visible. Populating
-- MANAGER_EMP_ID from HCM remains worth doing and is now unpoliced.
--
-- ── FOUR ENFORCEMENT POINTS, AND THEY MUST ALL AGREE ─────────
--
--   1. OC_TIME_PKG.assert_not_self   10 call sites, all routed through one
--                                    procedure — changed here to consult a flag
--   2. CHK_OC_TSA_SELF               a CHECK on OC_TS_APPROVAL, independent of
--                                    the package — dropped below
--   3. db/04_approval_audit.sql      creates that constraint, so a fresh
--                                    install would silently restore the rule —
--                                    commented out at source, not deleted
--   4. selectAllEmployees (VBCS)     filtered the manager's own row out of
--                                    "Select all pending" — filter removed
--
-- Change only the package and the INSERT into OC_TS_APPROVAL still fails with
-- ORA-02290 after the approval has already been written, which is the worst of
-- the four outcomes: a half-applied approval.
--
-- ── A FLAG, NOT A DELETION ───────────────────────────────────
--
-- OC_TIME_CONFIG already carries CONFIG_TYPE 'feature_flag', so the rule stays
-- named and reversible by an UPDATE rather than a redeploy. It DEFAULTS TO
-- ENFORCED: a schema that has run db/09 but not this script keeps the pack's
-- behaviour, which is the conservative direction for a security rule.
--
-- The constraint cannot be made conditional the same way — a CHECK cannot read
-- a table — so it is dropped outright. That asymmetry is the reason the flag
-- alone is not enough, and the reason this script exists rather than a one-line
-- edit to db/09.
--
-- Idempotent. Depends on: time/01 (OC_TIME_CONFIG), 04, 09.
-- RUN db/09 AFTER THIS: assert_not_self is edited there to read the flag.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_CONFIG';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', or db/01 has not been run: OC_TIME_CONFIG is missing.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] Before — who could approve whom
PROMPT ============================================================

COLUMN nm  FORMAT A32
COLUMN mgr FORMAT A32
SELECT w.employee_id, w.employee_name AS nm, w.app_role,
       NVL(m.employee_name, '(nobody)') AS mgr
  FROM oc_time_worker w
  LEFT JOIN oc_time_worker m ON m.employee_id = w.manager_emp_id
 WHERE EXISTS (SELECT 1 FROM oc_time_allocation al
                WHERE al.employee_id = w.employee_id
                  AND al.status = 'Active'
                  AND al.project_id = (SELECT project_id FROM oc_time_project
                                        WHERE project_number = '555'))
 ORDER BY w.employee_name;

PROMPT
PROMPT Every '(nobody)' above is a week RULE-015 could not route anywhere.

PROMPT ============================================================
PROMPT [2/5] The flag
PROMPT ============================================================

MERGE INTO oc_time_config c
USING (SELECT 'ALLOW_SELF_APPROVAL' AS config_name, 'GLOBAL' AS scope_key FROM dual) s
   ON (c.config_name = s.config_name AND c.scope_key = s.scope_key)
 WHEN MATCHED THEN UPDATE SET
   c.config_value = 'Y',
   c.updated_by   = 'DECISION_21AUG2026',
   c.updated_on   = SYSTIMESTAMP
 WHEN NOT MATCHED THEN INSERT
   (config_name, config_type, config_value, scope_key, description, created_by)
 VALUES
   ('ALLOW_SELF_APPROVAL', 'feature_flag', 'Y', 'GLOBAL',
    'Y = a manager may approve their own timesheet. Set 21-Aug-2026 by explicit '
    || 'instruction. REVERSES RULE-015, which the requirement pack marks blocking. '
    || 'Set to N to restore the pack behaviour - assert_not_self reads this on '
    || 'every call, so no redeploy is needed. NOTE: CHK_OC_TSA_SELF was dropped '
    || 'and setting N alone will not bring it back; see db/104 section 3.',
    'DECISION_21AUG2026');

COMMIT;

SELECT config_name, config_type, config_value, created_by
  FROM oc_time_config WHERE config_name = 'ALLOW_SELF_APPROVAL';

PROMPT ============================================================
PROMPT [3/5] Drop the constraint — the package flag cannot reach it
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSA_SELF' AND table_name = 'OC_TS_APPROVAL';
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  CHK_OC_TSA_SELF already absent - skipped.');
  ELSE
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_approval DROP CONSTRAINT chk_oc_tsa_self';
    DBMS_OUTPUT.PUT_LINE('  CHK_OC_TSA_SELF dropped.');
  END IF;
END;
/

-- The table has to carry the reason, because the constraint that used to state
-- the rule is gone and a reader of the DDL alone would never know it existed.
COMMENT ON COLUMN oc_ts_approval.actor_emp_id IS
  'Who performed the action. Until 21-Aug-2026 CHK_OC_TSA_SELF required this to differ from EMPLOYEE_ID for Approve/Reject/Override/AdvanceApprove/Confirm - RULE-015, "a manager''s own time is approved by their reporting manager". That constraint was dropped by explicit decision and self-approval is now permitted; OC_TIME_CONFIG.ALLOW_SELF_APPROVAL=N restores the package-level guard but NOT this constraint. The pack still states RULE-015 as blocking and has not been amended.';

PROMPT ============================================================
PROMPT [4/5] Nothing recorded so far relied on the rule
PROMPT ============================================================

-- If self-approvals already exist the constraint was not doing its job, which
-- would mean a third enforcement gap nobody has found yet. Expect zero.
SELECT COUNT(*) AS pre_existing_self_approvals
  FROM oc_ts_approval
 WHERE action IN ('Approve','Reject','Override','AdvanceApprove','Confirm')
   AND actor_emp_id = employee_id;

PROMPT
PROMPT Zero is expected. Anything else means the rule was already being bypassed
PROMPT somewhere this script has not accounted for.

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN what FORMAT A46
COLUMN state FORMAT A30
SELECT 'ALLOW_SELF_APPROVAL flag' AS what,
       NVL((SELECT config_value FROM oc_time_config
             WHERE config_name = 'ALLOW_SELF_APPROVAL' AND scope_key = 'GLOBAL'),
           '(absent - rule still enforced)') AS state
  FROM dual
UNION ALL
SELECT 'CHK_OC_TSA_SELF',
       CASE WHEN EXISTS (SELECT 1 FROM user_constraints
                          WHERE constraint_name = 'CHK_OC_TSA_SELF')
            THEN 'still present - NOT DONE' ELSE 'dropped' END
  FROM dual
UNION ALL
SELECT 'OC_TIME_PKG body',
       CASE WHEN EXISTS (SELECT 1 FROM user_objects
                          WHERE object_name = 'OC_TIME_PKG'
                            AND object_type = 'PACKAGE BODY'
                            AND status = 'VALID')
            THEN 'VALID' ELSE 'INVALID - run db/09' END
  FROM dual
UNION ALL
SELECT 'assert_not_self reads the flag',
       CASE WHEN EXISTS (SELECT 1 FROM user_source
                          WHERE name = 'OC_TIME_PKG' AND type = 'PACKAGE BODY'
                            AND UPPER(text) LIKE '%ALLOW_SELF_APPROVAL%')
            THEN 'yes' ELSE 'NO - db/09 not re-run' END
  FROM dual;

PROMPT
PROMPT All four rows must read flag=Y, dropped, VALID, yes. If the last two do
PROMPT not, run db/09_pkg_oc_time.sql and re-run this.

PROMPT
PROMPT STILL OPEN, and this script does not address it: MANAGER_EMP_ID is null
PROMPT for the whole 555 team. Self-approval hides that on projects whose
PROMPT manager is allocated to them, and hides nothing on the ones where the
PROMPT manager is not.
