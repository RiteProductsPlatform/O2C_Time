-- ============================================================
-- 12_revoke.sql — allow a submitted week to be pulled back
-- ============================================================
-- An employee who submits by mistake currently has no way out: the week is
-- frozen the moment it is Submitted, and only a manager rejection could move
-- it. That makes the manager do administrative work for someone else's typo,
-- and it puts a rejection in the audit trail that never happened.
--
-- Revoke returns a Submitted week to 'Not yet submitted' so the employee can
-- correct and resubmit. It stops at Approved: once the manager has acted the
-- decision is theirs to undo, which is a rejection (send-back), not a revoke.
--
-- Idempotent and re-runnable, like every other script here. Order against
-- 09_pkg_oc_time.sql does not matter for compilation — the package only writes
-- 'Revoke' at run time — but BOTH must be run before the button will work, or
-- the first revoke fails on CHK_OC_TSA_ACTION.
-- ============================================================

SET DEFINE OFF

PROMPT ============================================================
PROMPT [1/1] OC_TS_APPROVAL — add 'Revoke' to the action domain
PROMPT ============================================================

-- CHK_OC_TSA_ACTION is created inline by 04_approval_audit.sql, which is
-- skipped once the table exists (ORA-00955), so the domain has to be widened
-- here rather than by editing the CREATE TABLE.
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM user_constraints
   WHERE constraint_name = 'CHK_OC_TSA_ACTION';

  IF v_count > 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_approval DROP CONSTRAINT chk_oc_tsa_action';
  END IF;

  EXECUTE IMMEDIATE q'~
    ALTER TABLE oc_ts_approval ADD CONSTRAINT chk_oc_tsa_action CHECK (action IN
      ('Approve','Reject','Override','AdvanceApprove','Confirm',
       'Submit','Resubmit','Default','Release','Revoke'))~';

  DBMS_OUTPUT.PUT_LINE('CHK_OC_TSA_ACTION now allows Revoke.');
EXCEPTION
  WHEN OTHERS THEN
    -- A row already violating the widened domain is impossible (it is a
    -- superset), so anything here is worth seeing rather than swallowing.
    DBMS_OUTPUT.PUT_LINE('CHK_OC_TSA_ACTION: ' || SQLERRM);
    RAISE;
END;
/

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN search_condition_vc FORMAT A78
SELECT search_condition_vc
  FROM user_constraints
 WHERE constraint_name = 'CHK_OC_TSA_ACTION';
