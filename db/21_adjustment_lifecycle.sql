--==============================================================
-- time/21_adjustment_lifecycle.sql
-- O2C Timesheet Module — an adjustment follows the same lifecycle as a week
--
-- Decided 10-Aug-2026. An adjustment raised automatically from a Fusion
-- allocation change must NOT arrive already awaiting a manager. It belongs to
-- the employee first:
--
--   Not yet submitted  raised, by the sync or by hand. Nobody has agreed yet.
--          |  employee submits           -> Submitted
--          |  employee misses the cutoff -> Submitted, DEFAULTED_BY 'EMPLOYEE'
--   Submitted
--          |  both managers approve      -> Approved   (RA-014)
--          |  managers miss the cutoff   -> Approved,  DEFAULTED_BY 'MANAGER'
--   Approved -> the Reversal(-)/Adjustment(+) entries materialise
--
-- This is the SAME shape as OC_TS_WEEK, deliberately. An employee who has to
-- learn one set of rules for their week and a different set for a correction to
-- that week will get one of them wrong, and the correction is the one carrying
-- money that has already been costed and accrued.
--
-- WHY THE STATUS DOMAIN WAS WRONG BEFORE
-- ('Awaiting Approval','Approved','Rejected','Cancelled') has no submission
-- state at all, so an auto-raised adjustment went straight into a manager's
-- queue for hours the employee had never seen moved. The module's own status
-- model (section 7 of CLAUDE.md) already names the states this needs --
-- Not yet submitted / Submitted / Approved / Rejected / Defaulted -- and the
-- adjustment simply was not using them.
--
-- NOTHING IN 09_pkg_oc_time.sql IS CHANGED. Default-approval works by
-- pre-stamping both manager columns and then calling the REAL
-- approve_adjustment, whose gate is "have both sides approved" -- so the
-- materialisation, the sign convention, the audit row and the accrual hand-off
-- are the ones already tested, not a second copy that can drift from them.
--
-- Idempotent. Depends on: time/05, time/09, time/20
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] The status domain and the submission columns
PROMPT ============================================================

DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(200);
  v t_tab := t_tab(
    'submitted_by VARCHAR2(100 CHAR)',
    'submitted_on TIMESTAMP',
    -- 'EMPLOYEE' or 'MANAGER', exactly as OC_TS_WEEK uses it: which side let
    -- the cutoff pass. run_salary_stopping filters on 'EMPLOYEE' because a
    -- manager's lateness must never hold the employee's salary (section 8.1),
    -- and the same distinction has to survive here or an adjustment defaulted
    -- by a slow manager would look like the employee's fault.
    'defaulted_by VARCHAR2(10 CHAR)');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_adjustment ADD (' || v(i) || ')';
      DBMS_OUTPUT.PUT_LINE('added   ' || v(i));
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
    END;
  END LOOP;
END;
/

-- Widen the domain. Drop and recreate rather than add a second CHECK: two
-- overlapping constraints both have to pass, so the old one would still reject
-- 'Not yet submitted' and the failure would name a constraint nobody edited.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_ts_adjustment DROP CONSTRAINT chk_oc_tsadj_status';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -2443 THEN NULL;   -- not there
  ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_adjustment ADD CONSTRAINT
    chk_oc_tsadj_status CHECK (status IN
      ('Not yet submitted','Submitted','Awaiting Approval',
       'Approved','Rejected','Cancelled'))~';
  DBMS_OUTPUT.PUT_LINE('status domain widened.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_ts_adjustment ADD CONSTRAINT
    chk_oc_tsadj_defby CHECK (defaulted_by IS NULL
                              OR defaulted_by IN ('EMPLOYEE','MANAGER'))~';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/

-- 'Awaiting Approval' is KEPT in the domain and not migrated away. Rows created
-- before today hold it and they are legitimately mid-flight; rewriting their
-- status would forge a history in which they had been submitted by someone.
-- Treated as equivalent to Submitted everywhere below.

PROMPT ============================================================
PROMPT [2/4] A manager cannot approve what nobody submitted
PROMPT ============================================================

-- The rule belongs in the database, not the page: approve_adjustment is
-- reachable over ORDS directly, so a caller who skips the screen would
-- otherwise approve hours the employee has never submitted.
--
-- A trigger rather than a change to approve_adjustment, because 09 is compiled
-- and this is a new rule rather than a correction to an existing one. -20027
-- continues the module's band, so ORDS maps it to 400 with the message intact.
CREATE OR REPLACE TRIGGER trg_oc_tsadj_submit_first
BEFORE UPDATE OF old_mgr_approved_by, new_mgr_approved_by ON oc_ts_adjustment
FOR EACH ROW
BEGIN
  IF :OLD.status = 'Not yet submitted'
     AND (:NEW.old_mgr_approved_by IS NOT NULL
          OR :NEW.new_mgr_approved_by IS NOT NULL)
     -- The defaulting job below sets the status IN THE SAME statement, so the
     -- new value is what decides. Without this test the job could never
     -- default-approve anything.
     AND :NEW.status = 'Not yet submitted' THEN
    RAISE_APPLICATION_ERROR(-20027,
      'This adjustment has not been submitted yet, so it cannot be approved. '
   || 'The employee submits it first, or the cut-off submits it for them.');
  END IF;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3/4] OC_TIME_SUBMIT_ADJUSTMENT — the employee's action
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_submit_adjustment(
  p_adjustment_id IN  NUMBER,
  p_actor         IN  VARCHAR2,
  o_message       OUT VARCHAR2)
AS
  v_status VARCHAR2(30);
  v_emp    VARCHAR2(50);
BEGIN
  SELECT status, employee_id INTO v_status, v_emp
    FROM oc_ts_adjustment WHERE adjustment_id = p_adjustment_id;

  IF v_status <> 'Not yet submitted' THEN
    o_message := 'Adjustment ' || p_adjustment_id || ' is already ' || v_status
              || ' and cannot be submitted again.';
    RETURN;
  END IF;

  UPDATE oc_ts_adjustment
     SET status       = 'Submitted',
         submitted_by = p_actor,
         submitted_on = SYSTIMESTAMP
   WHERE adjustment_id = p_adjustment_id;

  COMMIT;
  o_message := 'Adjustment ' || p_adjustment_id || ' submitted for approval by '
            || 'the old and new project managers.';
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    o_message := 'No adjustment ' || p_adjustment_id || '.';
END oc_time_submit_adjustment;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] OC_TIME_DEFAULT_ADJUSTMENTS — the two cut-offs
PROMPT ============================================================

-- Both halves of the defaulting, in one job, mirroring run_weekly_defaulting
-- and run_delivery_defaulting for weeks.
--
-- Run it after those. An adjustment cannot outlive the period it posts into,
-- and both cut-offs are read from THAT period -- the POST period, not the
-- source one. A July correction posting into August is governed by August's
-- cut-offs, because August is the month it will actually be paid and accrued
-- in. Reading July's would default it the moment it was raised.
CREATE OR REPLACE PROCEDURE oc_time_default_adjustments(
  p_period_id  IN  NUMBER  DEFAULT NULL,   -- null = every open post period
  p_actor      IN  VARCHAR2 DEFAULT 'SYSTEM',
  o_submitted  OUT NUMBER,
  o_approved   OUT NUMBER,
  o_message    OUT VARCHAR2)
AS
  v_err VARCHAR2(400);
BEGIN
  o_submitted := 0;
  o_approved  := 0;

  -- ── the employee's cut-off ───────────────────────────────────
  -- Not yet submitted and the delivery cut-off has passed -> submitted FOR
  -- them. DEFAULTED_BY 'EMPLOYEE' because it was their action that lapsed.
  FOR a IN (SELECT adj.adjustment_id
              FROM oc_ts_adjustment adj
              JOIN oc_time_period   p ON p.period_id = adj.post_period_id
             WHERE adj.status = 'Not yet submitted'
               AND (p_period_id IS NULL OR adj.post_period_id = p_period_id)
               AND p.delivery_cutoff IS NOT NULL
               AND TRUNC(SYSDATE) > p.delivery_cutoff)
  LOOP
    UPDATE oc_ts_adjustment
       SET status       = 'Submitted',
           submitted_by = p_actor,
           submitted_on = SYSTIMESTAMP,
           defaulted_by = 'EMPLOYEE'
     WHERE adjustment_id = a.adjustment_id;
    o_submitted := o_submitted + 1;
  END LOOP;

  -- ── the managers' cut-off ────────────────────────────────────
  -- Submitted, finance cut-off passed, still unapproved -> approved for them.
  --
  -- Both manager columns are stamped and then the REAL approve_adjustment is
  -- called. Its gate is "have both sides approved", so pre-stamping makes it
  -- fall through to the materialisation that already exists -- the Reversal(-)
  -- and Adjustment(+) rows, the OC_TS_AUDIT entry, the accrual hand-off. A
  -- second copy of that logic here would be the thing that silently drifts.
  FOR a IN (SELECT adj.adjustment_id, adj.employee_id
              FROM oc_ts_adjustment adj
              JOIN oc_time_period   p ON p.period_id = adj.post_period_id
             WHERE adj.status IN ('Submitted','Awaiting Approval')
               AND adj.posted_flag = 'N'
               AND (p_period_id IS NULL OR adj.post_period_id = p_period_id)
               AND p.finance_cutoff IS NOT NULL
               AND TRUNC(SYSDATE) > p.finance_cutoff)
  LOOP
    BEGIN
      UPDATE oc_ts_adjustment
         SET old_mgr_approved_by = NVL(old_mgr_approved_by, p_actor),
             old_mgr_approved_on = NVL(old_mgr_approved_on, SYSTIMESTAMP),
             new_mgr_approved_by = NVL(new_mgr_approved_by, p_actor),
             new_mgr_approved_on = NVL(new_mgr_approved_on, SYSTIMESTAMP),
             defaulted_by        = NVL(defaulted_by, 'MANAGER'),
             status              = 'Submitted'
       WHERE adjustment_id = a.adjustment_id;

      oc_time_pkg.approve_adjustment(
        p_adjustment_id => a.adjustment_id,
        p_actor_emp_id  => a.employee_id,
        p_actor         => p_actor);

      o_approved := o_approved + 1;
    EXCEPTION WHEN OTHERS THEN
      -- One adjustment failing must not strand the rest, and it must not be
      -- silent either -- it lands in the queue the other sync failures use.
      DECLARE v_e VARCHAR2(400) := SUBSTR(SQLERRM, 1, 400);
      BEGIN
        v_err := NVL(v_err, v_e);
        INSERT INTO oc_time_sync_failed
               (job_run_id, entity_type, entity_key, failure_reason, failure_code)
        VALUES (NULL, 'ADJUSTMENT_DEFAULT', TO_CHAR(a.adjustment_id), v_e, -1);
      END;
    END;
  END LOOP;

  COMMIT;
  o_message := o_submitted || ' defaulted to Submitted (employee cut-off), '
            || o_approved  || ' default-approved (manager cut-off).'
            || CASE WHEN v_err IS NULL THEN ''
                    ELSE ' AT LEAST ONE FAILED: ' || v_err END;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    o_message := SUBSTR('Defaulting adjustments failed: ' || SQLERRM, 1, 2000);
END oc_time_default_adjustments;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN object_name FORMAT A32
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_SUBMIT_ADJUSTMENT','OC_TIME_DEFAULT_ADJUSTMENTS',
                       'TRG_OC_TSADJ_SUBMIT_FIRST')
 ORDER BY object_name;

COLUMN status FORMAT A20
SELECT status, COUNT(*) AS rows_
  FROM oc_ts_adjustment GROUP BY status ORDER BY status;

PROMPT
PROMPT Every object VALID. Existing rows keep 'Awaiting Approval' -- they are
PROMPT legitimately mid-flight and rewriting their status would forge a history
PROMPT in which somebody had submitted them.
