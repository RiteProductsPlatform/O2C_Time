--==============================================================
-- time/18_task_natural_key.sql
-- O2C Timesheet Module — OC_TIME_TASK needs a natural key
--
-- Found by testing the loader, which is the point of testing it: every other
-- load target has a natural unique key and OC_TIME_TASK has none.
--
--   OC_TIME_WORKER      UK (employee_id)
--   OC_TIME_PROJECT     UK (project_number)
--   OC_TIME_ALLOCATION  UK (project_id, employee_id, start_date)
--   OC_TIME_ABSENCE     UK (employee_id, absence_date, absence_type)
--   OC_TIME_CALENDAR    UK (layer, scope_key, cal_date)
--   OC_TIME_TASK        -- nothing but the identity primary key
--
-- An identity key matches nothing in an incoming feed, so with no natural key
-- there is no way to tell "this task again" from "a new task". The loader
-- refuses rather than guess -- correctly, because the alternative is a plain
-- insert that duplicates all 624 tasks on every single sync, quietly, until
-- the task LOV is unusable.
--
-- FUSION_TASK_ID is the key: it is Fusion's own PROJ_ELEMENT_ID, unique across
-- projects, and it is exactly what the extract now emits under that name.
-- (PROJECT_ID, TASK_CODE) would also be unique but depends on the foreign key
-- having resolved first, which makes the merge's matching depend on the merge's
-- own lookup. FUSION_TASK_ID stands on its own.
--
-- NULLABLE, deliberately. The COMMON tasks -- Leave, Training, Travel and the
-- rest, seeded by 10_seed.sql -- have no Fusion element behind them and never
-- will. Oracle's unique constraints ignore null rows, so those coexist happily
-- while every synced task is still matched exactly once.
--
-- Idempotent. Depends on: time/02, time/17
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] Any duplicates already there?
PROMPT ============================================================

-- Adding the constraint fails on existing duplicates, and the failure would be
-- a bare ORA-02299 naming the index rather than the rows. Report first.
DECLARE
  v_dup NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_dup FROM (
    SELECT fusion_task_id FROM oc_time_task
     WHERE fusion_task_id IS NOT NULL
     GROUP BY fusion_task_id HAVING COUNT(*) > 1);

  IF v_dup = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No duplicate FUSION_TASK_ID. Safe to constrain.');
  ELSE
    DBMS_OUTPUT.PUT_LINE(v_dup || ' duplicated FUSION_TASK_ID value(s) exist.');
    DBMS_OUTPUT.PUT_LINE('These are almost certainly from a load that ran '
                      || 'before this key existed. Review them, keep one row '
                      || 'each, then re-run:');
    FOR r IN (SELECT fusion_task_id, COUNT(*) c FROM oc_time_task
               WHERE fusion_task_id IS NOT NULL
               GROUP BY fusion_task_id HAVING COUNT(*) > 1
               FETCH FIRST 10 ROWS ONLY)
    LOOP
      DBMS_OUTPUT.PUT_LINE('   ' || r.fusion_task_id || '  x' || r.c);
    END LOOP;
  END IF;
END;
/

PROMPT ============================================================
PROMPT [2/3] The constraint
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE
    'ALTER TABLE oc_time_task ADD CONSTRAINT uk_oc_ttsk_fusion '
    || 'UNIQUE (fusion_task_id)';
  DBMS_OUTPUT.PUT_LINE('UK_OC_TTSK_FUSION created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE IN (-2261, -2264) THEN            -- already exists, either name
    DBMS_OUTPUT.PUT_LINE('UK_OC_TTSK_FUSION already exists - skipped.');
  ELSIF SQLCODE = -2299 THEN
    DBMS_OUTPUT.PUT_LINE('CANNOT ADD: duplicate FUSION_TASK_ID rows exist. '
                      || 'See the list above, clean them, then re-run.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [3/3] Verification — every load target now has a natural key
PROMPT ============================================================

COLUMN table_name      FORMAT A22
COLUMN constraint_name FORMAT A24
COLUMN cols            FORMAT A44

SELECT c.table_name, c.constraint_name,
       LISTAGG(cc.column_name, ', ')
         WITHIN GROUP (ORDER BY cc.position) AS cols
  FROM user_constraints c
  JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
 WHERE c.constraint_type = 'U'
   AND c.table_name IN ('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                        'OC_TIME_ALLOCATION','OC_TIME_ABSENCE','OC_TIME_CALENDAR')
 GROUP BY c.table_name, c.constraint_name
 ORDER BY c.table_name;

PROMPT
PROMPT Expect all six tables listed. A target missing from this list cannot be
PROMPT merged into and the loader will refuse it by design.
