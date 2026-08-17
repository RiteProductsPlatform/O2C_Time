--==============================================================
-- time/67_resource_billability.sql
-- O2C Timesheet Module — a non-billable RESOURCE, not just a non-billable task
--
-- PPM now carries "Assignment Type" per person per project on the Update
-- Project Resource dialog, and it is the answer the module never had:
--
--     444        RI2935, RI2963      NON-BILLABLE
--     555        CRI0398, RI2914     NON-BILLABLE
--     PCS10034   RI3004              NON-BILLABLE
--
-- Pod-wide: BILLABLE 1,113, NON-BILLABLE 157, null 6,357. Carried into
-- OC_TIME_ALLOCATION.BILLING_STATUS by the ALLOCATIONS extract (null defaults
-- to Billable, matching the column, because calling 6,357 unfilled rows
-- unbilled would make most of the pod non-billable on a field nobody has set).
--
-- TWO AXES, NOT ONE. They are independent and both are needed:
--
--   the TASK      OC_TIME_TASK.BILLABLE_TYPE, from
--                 PJF_PROJ_ELEMENTS_B.BILLABLE_FLAG. Billable or not for
--                 EVERYONE -- Training is Training whoever books it.
--   the RESOURCE  OC_TIME_ALLOCATION.BILLING_STATUS, from
--                 PJT_PROJECT_RESOURCE.ASSIGNMENT_TYPE. Billable or not for
--                 ONE PERSON on ONE project -- Shivani's time on 444 is not
--                 billable even on a billable task.
--
-- EITHER makes the entry non-billable. Not both: a non-billable resource on a
-- billable task is still not billable, which is the whole point of the field.
--
-- WHY THE TRIGGER AND NOT A SWEEP. TRG_OC_TSE_DERIVE already sets BILLABLE_TYPE
-- and UNBILLED_REASON from the task on every insert and update, so every writer
-- -- populate, save_entry, the absence sync, a caller hitting ORDS directly --
-- already passes through it. A separate job would leave a window where the two
-- disagree, and would have to be remembered by anyone adding a new writer.
--
-- RULE-002 NEEDS A REASON. CHK_OC_TSE_UNBILLED refuses a non-billable line
-- carrying hours without one, and a non-billable RESOURCE on a BILLABLE task
-- has no reason to inherit -- the task has none, and PPM's "Billable Percent
-- Reason" is empty on all five rows. So one is seeded below rather than the
-- trigger inventing a literal: the reason has to exist in the same lookup the
-- dropdown reads, or the grid would display a value it cannot offer.
--
-- Idempotent. Depends on: time/03, 10, 23. Re-run the ALLOCATIONS sync first
-- or BILLING_STATUS is still 'Billable' everywhere and this changes nothing.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TIME_ALLOCATION' AND column_name = 'BILLING_STATUS';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'OC_TIME_ALLOCATION.BILLING_STATUS is missing. Run 02_time_master.sql.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] The reason a resource-level non-billable line carries
PROMPT ============================================================

-- In the same lookup the dropdown reads (23_unbilled_reason_per_line.sql), so
-- the grid can display it.
--
-- SELECTABLE = 'N', and the column really is called SELECTABLE -- not
-- SELECTABLE_FLAG, which is OC_TIME_TASK's. 23 records the same confusion
-- about ENABLED_FLAG; OC_TIME_LOOKUP has ACTIVE_FLAG and SELECTABLE and
-- neither is named the obvious way.
--
-- 'N' because this reason is DERIVED from PPM. Offering it in the picker would
-- invite somebody to mark a line non-billable for a reason that is not true of
-- their assignment, and the LOV view filters on SELECTABLE = 'Y' so setting it
-- here keeps the value renderable on historical rows while withdrawing it from
-- the dropdown -- which is exactly the distinction that column exists for.
DECLARE
  v_n NUMBER := 0;
BEGIN
  INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note,
                              sort_order, selectable, created_by)
  SELECT 'unbilled_reason', 'Non-billable Assignment',
         'Non-billable assignment (from PPM)',
         'Derived from PJT_PROJECT_RESOURCE.ASSIGNMENT_TYPE; not user-selectable',
         60, 'N', 'PPM_BILLABILITY'
    FROM dual
   WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                      WHERE LOWER(lookup_type) = 'unbilled_reason'
                        AND lookup_code = 'Non-billable Assignment');
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n = 1 THEN 'reason seeded'
                            ELSE 'reason already present' END);
END;
/

PROMPT ============================================================
PROMPT [2/4] TRG_OC_TSE_DERIVE — the resource axis added
PROMPT ============================================================

CREATE OR REPLACE TRIGGER trg_oc_tse_derive
BEFORE INSERT OR UPDATE ON oc_ts_entry
FOR EACH ROW
DECLARE
  v_bill    oc_time_task.billable_type%TYPE;
  v_reason  oc_time_task.unbilled_reason%TYPE;
  v_alloc   oc_time_allocation.billing_status%TYPE;
BEGIN
  SELECT billable_type, unbilled_reason
    INTO v_bill, v_reason
    FROM oc_time_task
   WHERE task_id = :NEW.task_id;

  IF NVL(:NEW.is_leave, 'N') = 'Y' THEN
    -- Absence, from HCM. Not chosen by anyone, so not justified by anyone.
    -- The task's own values stand and the line is left alone. The resource
    -- axis is NOT applied: leave is not work, so whether the person's work is
    -- billable says nothing about it.
    :NEW.billable_type   := v_bill;
    :NEW.unbilled_reason := NVL(:NEW.unbilled_reason, v_reason);

  ELSIF :NEW.unbilled_reason IS NOT NULL THEN
    -- A reason was given on the LINE. It wins, on a billable task as much as a
    -- non-billable one -- this is what replaces booking the hours to PRJ-ORG.
    -- The line is Non-billable BECAUSE a reason was given: the reason says the
    -- hours are not billable, so leaving BILLABLE_TYPE alone would put a
    -- contradiction into the accrual for it to resolve on its own.
    :NEW.billable_type := 'Non-billable';

  ELSIF v_bill = 'Non-billable' THEN
    -- The task decides and supplies its own reason, so the common tasks keep
    -- working untouched (RULE-002).
    :NEW.billable_type   := v_bill;
    :NEW.unbilled_reason := v_reason;

  ELSE
    -- BILLABLE TASK, NO REASON ON THE LINE: the RESOURCE decides. Added
    -- 18-Aug-2026, when PPM began carrying Assignment Type per person per
    -- project. Shivani on 444 is NON-BILLABLE, so her hours on a billable task
    -- are not billable -- which is exactly what the field is for and what the
    -- module could not express until now.
    --
    -- Looked up by DATE, not merely "active": an assignment type that changes
    -- mid-month must not retag the days before it.
    BEGIN
      SELECT MAX(al.billing_status) INTO v_alloc
        FROM oc_time_allocation al
        JOIN oc_ts_week w ON w.employee_id = al.employee_id
       WHERE w.ts_week_id  = :NEW.ts_week_id
         AND al.project_id = :NEW.project_id
         AND al.status     = 'Active'
         AND :NEW.entry_date BETWEEN al.start_date
                                 AND NVL(al.end_date, DATE '4712-12-31');
    EXCEPTION WHEN OTHERS THEN
      v_alloc := NULL;
    END;

    IF v_alloc = 'Unbilled' THEN
      :NEW.billable_type   := 'Non-billable';
      -- RULE-002. The task has no reason to lend -- it is billable -- so the
      -- seeded one names why, rather than leaving a line that fails
      -- CHK_OC_TSE_UNBILLED the moment it carries hours.
      :NEW.unbilled_reason := 'Non-billable Assignment';
    ELSE
      -- No allocation row, or a billable one. NOT non-billable: a missing
      -- allocation is a data gap, and treating it as unbilled would quietly
      -- stop billing for it.
      :NEW.billable_type := v_bill;
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
PROMPT [3/4] Retag the entries already written
PROMPT ============================================================

-- The trigger only fires on write, so existing rows keep whatever they were
-- given. A no-op UPDATE re-fires it and lets the trigger do the deciding --
-- rather than this script reimplementing the same rules and the two drifting.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR e IN (SELECT e.ts_entry_id
              FROM oc_ts_entry     e
              JOIN oc_ts_week      w  ON w.ts_week_id = e.ts_week_id
              JOIN oc_time_allocation al
                ON al.employee_id = w.employee_id
               AND al.project_id  = e.project_id
               AND al.status      = 'Active'
               AND e.entry_date BETWEEN al.start_date
                                    AND NVL(al.end_date, DATE '4712-12-31')
             WHERE e.is_leave = 'N'
               -- Only where the answer would change, so UPDATED_ON does not
               -- move on rows that are already right.
               AND ((al.billing_status = 'Unbilled'
                     AND e.billable_type <> 'Non-billable')
                 OR (al.billing_status = 'Billable'
                     AND e.billable_type = 'Non-billable'
                     AND e.unbilled_reason = 'Non-billable Assignment')))
  LOOP
    -- Touch a column the trigger overwrites anyway; it recomputes both.
    UPDATE oc_ts_entry SET unbilled_reason = unbilled_reason
     WHERE ts_entry_id = e.ts_entry_id;
    v_n := v_n + 1;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_n || ' entry row(s) retagged');
END;
/

PROMPT ============================================================
PROMPT [4/4] Who is now non-billable, and on what
PROMPT ============================================================

COLUMN employee_id FORMAT A11
COLUMN project_number FORMAT A12
COLUMN reason FORMAT A26
SELECT w.employee_id, p.project_number,
       e.billable_type,
       NVL(e.unbilled_reason,'-') AS reason,
       COUNT(*)     AS days,
       SUM(e.hours) AS hours
  FROM oc_ts_entry e
  JOIN oc_ts_week  w ON w.ts_week_id = e.ts_week_id
  JOIN oc_time_project p ON p.project_id = e.project_id
 WHERE e.is_leave = 'N'
   AND e.billable_type = 'Non-billable'
   AND e.entry_date >= TRUNC(SYSDATE, 'MM')
 GROUP BY w.employee_id, p.project_number, e.billable_type, e.unbilled_reason
 ORDER BY w.employee_id, p.project_number;

PROMPT
PROMPT --- and the month's split, which is what the manager screen totals
SELECT p.project_number,
       SUM(CASE WHEN e.billable_type = 'Billable'     AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END) AS billable,
       SUM(CASE WHEN e.billable_type = 'Non-billable' AND e.is_leave = 'N'
                THEN e.hours ELSE 0 END) AS non_billable,
       SUM(CASE WHEN e.is_leave = 'Y' THEN e.hours ELSE 0 END) AS leave_hrs
  FROM oc_ts_entry e
  JOIN oc_time_project p ON p.project_id = e.project_id
 WHERE e.entry_date >= TRUNC(SYSDATE, 'MM')
 GROUP BY p.project_number
 ORDER BY p.project_number;
