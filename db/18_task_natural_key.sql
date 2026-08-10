--==============================================================
-- time/18_task_natural_key.sql
-- O2C Timesheet Module — OC_TIME_TASK needs a natural key
--
-- CORRECTED 10-Aug-2026. What this file first said was wrong, and the wrong
-- version was compiled, so read this before assuming the header below.
--
-- It claimed OC_TIME_TASK had "nothing but the identity primary key". It has a
-- natural key and always did -- 02_time_master.sql creates two:
--
--   UK_OC_TTSK_WBS     (project_id, UPPER(task_code))
--   UK_OC_TTSK_COMMON  (CASE WHEN task_type='COMMON' THEN UPPER(task_code) END)
--
-- Both are CREATE UNIQUE INDEX, not ALTER TABLE ADD CONSTRAINT. Oracle keeps
-- those in USER_INDEXES and NOT in USER_CONSTRAINTS, and the loader's key
-- discovery reads USER_CONSTRAINTS -- so it saw no key on a table that has two.
-- POST sync/task already keys on (project, task code) and says why: "because
-- UK_OC_TTSK_WBS is what the table actually enforces."
--
-- The merge key is therefore NOT this constraint. OC_TIME_SYNC_CONFIG.MERGE_KEY
-- declares 'PROJECT_ID,TASK_CODE' for TASKS, and the loader prefers a declared
-- key over discovery. Matching on FUSION_TASK_ID while the table enforces
-- (project, code) is worse than having no key at all: a row that misses on the
-- fusion id is treated as new and the insert collides, ORA-00001, mid-sync.
--
-- WHAT THIS FILE IS STILL FOR, and why it is kept rather than reverted:
-- FUSION_TASK_ID genuinely is unique -- it is Fusion's PROJ_ELEMENT_ID -- and
-- nothing enforced that. The constraint turns one specific silent corruption
-- into an error: a task that MOVES between projects in Fusion arrives as
-- (new project, same code), misses the merge on (project, code), and inserts.
-- Without this it becomes a second row for one Fusion task, in two projects at
-- once, and the task LOV shows both. With it, the sync fails and says so.
-- Failing is the better outcome; neither is correct handling, and a task that
-- moves project still needs a real answer.
--
-- NULLABLE, deliberately. The COMMON tasks -- Leave, Training, Travel and the
-- rest, seeded by 10_seed.sql -- have no Fusion element behind them and never
-- will. Oracle's unique constraints ignore null rows, so those coexist happily.
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
PROMPT [3/3] Verification — the keys, from BOTH places they can live
PROMPT ============================================================
PROMPT A unique INDEX is not a unique CONSTRAINT. Listing only USER_CONSTRAINTS
PROMPT is what hid UK_OC_TTSK_WBS in the first place, so list both.

COLUMN table_name      FORMAT A22
COLUMN constraint_name FORMAT A24
COLUMN cols            FORMAT A44

-- IN PL/SQL, NOT SQL. USER_IND_EXPRESSIONS.COLUMN_EXPRESSION is a LONG, and a
-- LONG cannot appear inside NVL, LISTAGG, GROUP BY or virtually any SQL
-- expression -- only bare in a SELECT list. Wrapping it in NVL() alongside a
-- VARCHAR2 column is ORA-00932 "inconsistent datatypes: expected LONG got CHAR",
-- which reads like a column mismatch and is really "you may not touch a LONG
-- here at all". PL/SQL assigns a LONG to VARCHAR2(32760) implicitly, so reading
-- it one row at a time works where the set-based query cannot.
--
-- Same family as the SQL-only / PL/SQL-only traps already in CLAUDE.md section 5:
-- check which side of that line a thing lives on before writing the statement.
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_expr VARCHAR2(4000);
  v_cols VARCHAR2(4000);
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('TABLE', 22) || RPAD('KIND', 12) ||
                       RPAD('NAME', 24) || 'COLUMNS');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 96, '-'));

  -- Unique CONSTRAINTS: what the loader's discovery CAN see.
  FOR c IN (
    SELECT c.table_name, c.constraint_name,
           LISTAGG(cc.column_name, ', ')
             WITHIN GROUP (ORDER BY cc.position) AS cols
      FROM user_constraints c
      JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
     WHERE c.constraint_type = 'U'
       AND c.table_name IN ('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                            'OC_TIME_ALLOCATION','OC_TIME_ABSENCE',
                            'OC_TIME_CALENDAR')
     GROUP BY c.table_name, c.constraint_name
     ORDER BY c.table_name, c.constraint_name)
  LOOP
    DBMS_OUTPUT.PUT_LINE(RPAD(c.table_name, 22) || RPAD('CONSTRAINT', 12) ||
                         RPAD(c.constraint_name, 24) || c.cols);
  END LOOP;

  -- Unique INDEXES with no constraint behind them: what it CANNOT.
  FOR i IN (
    SELECT i.table_name, i.index_name
      FROM user_indexes i
     WHERE i.uniqueness = 'UNIQUE'
       AND i.table_name IN ('OC_TIME_WORKER','OC_TIME_PROJECT','OC_TIME_TASK',
                            'OC_TIME_ALLOCATION','OC_TIME_ABSENCE',
                            'OC_TIME_CALENDAR')
       AND NOT EXISTS (SELECT 1 FROM user_constraints c2
                        WHERE c2.index_name = i.index_name)
     ORDER BY i.table_name, i.index_name)
  LOOP
    v_cols := NULL;
    FOR ic IN (SELECT column_name, column_position
                 FROM user_ind_columns
                WHERE index_name = i.index_name
                ORDER BY column_position)
    LOOP
      v_expr := NULL;
      -- A function-based column is stored as SYS_NCnnnnn$; the real expression
      -- is only in USER_IND_EXPRESSIONS, as a LONG.
      IF ic.column_name LIKE 'SYS\_NC%' ESCAPE '' THEN
        BEGIN
          SELECT column_expression INTO v_expr      -- LONG -> VARCHAR2, legal here
            FROM user_ind_expressions
           WHERE index_name = i.index_name
             AND column_position = ic.column_position;
        EXCEPTION WHEN NO_DATA_FOUND THEN v_expr := NULL;
        END;
      END IF;
      v_cols := v_cols || ', ' || NVL(v_expr, ic.column_name);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(RPAD(i.table_name, 22) || RPAD('INDEX', 12) ||
                         RPAD(i.index_name, 24) || LTRIM(v_cols, ', '));
  END LOOP;
END;
/

PROMPT
PROMPT Every row marked INDEX is a key the loader's discovery CANNOT see. If a
PROMPT feed targets one of those tables, its config row needs MERGE_KEY set
PROMPT explicitly -- discovery will either find nothing or find the wrong key.
