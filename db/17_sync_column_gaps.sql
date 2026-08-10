--==============================================================
-- time/17_sync_column_gaps.sql
-- O2C Timesheet Module — the columns the extracts send with nowhere to land
--
-- Measured against real BIP output on 10-Aug-2026: after the alias rename, six
-- reports still emit elements that no target column matches, so the loader
-- silently drops them. Dropping is the right default -- a report carrying an
-- extra element must not error -- but three of these are not droppable:
--
--   TIME_ENTRY_ENABLED  decides whether a project is visible to time entry at
--                       all. Without it every project looks enterable.
--   EXPENDITURE_TYPE    POET's E. Recorded in CLAUDE.md as the reason the OTL
--                       push cannot be built.
--   EXPENDITURE_ORG     POET's O, same note. The costing unit the work books
--                       to, which is NOT the legal employer.
--
-- The rest are added because they are already being extracted and verified, so
-- the only thing standing between them and being useful is a column. Adding one
-- is cheaper than re-deriving the data later.
--
-- ADDITIVE ONLY. Every statement is ALTER TABLE ADD, guarded on ORA-01430
-- (column already exists), so this is safe to re-run and cannot lose data.
--
-- Idempotent. Depends on: time/02, time/03
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/2] Add the missing columns
PROMPT ============================================================

DECLARE
  TYPE t_col IS RECORD (tab VARCHAR2(30), col VARCHAR2(30), spec VARCHAR2(80));
  TYPE t_tab IS TABLE OF t_col;
  v_added NUMBER := 0;
  v_skip  NUMBER := 0;

  v t_tab := t_tab(
    -- POET's O, resource-wise. Deliberately separate from LEGAL_EMPLOYER:
    -- the employer is who employs the person, the expenditure org is the unit
    -- that incurs the cost, and reading one for the other sends cost to the
    -- wrong place while looking entirely plausible.
    t_col('OC_TIME_WORKER',     'EXPENDITURE_ORG',    'VARCHAR2(240 CHAR)'),

    t_col('OC_TIME_PROJECT',    'ORGANIZATION',       'VARCHAR2(240 CHAR)'),
    -- TrackTimeFlag on the Fusion project team. A project with this unset is
    -- INVISIBLE to time entry, so without the column the module cannot tell.
    t_col('OC_TIME_PROJECT',    'TIME_ENTRY_ENABLED', 'CHAR(1)'),

    -- Fusion's project id on the task, so the task can be tied back to its
    -- project without a name match. The FK PROJECT_ID stays local.
    t_col('OC_TIME_TASK',       'FUSION_PROJECT_ID',  'VARCHAR2(50 CHAR)'),
    t_col('OC_TIME_TASK',       'PROJECT_NUMBER',     'VARCHAR2(60 CHAR)'),
    t_col('OC_TIME_TASK',       'WBS_LEVEL',          'NUMBER(3)'),
    t_col('OC_TIME_TASK',       'PARENT_TASK_ID',     'VARCHAR2(50 CHAR)'),
    t_col('OC_TIME_TASK',       'START_DATE',         'DATE'),
    t_col('OC_TIME_TASK',       'END_DATE',           'DATE'),
    -- POET's E.
    t_col('OC_TIME_TASK',       'EXPENDITURE_TYPE',   'VARCHAR2(80 CHAR)'),

    -- Fusion's own project id on the allocation. OC_TIME_ALLOCATION.PROJECT_ID
    -- is OUR identity surrogate and cannot be sent to OTL; this is what names
    -- the project back to Fusion for the INT-007 push.
    --
    -- The ALLOCATIONS extract used to alias Fusion's id as PROJECT_ID -- the
    -- local FK's own name -- so the loader took it as an ordinary column and
    -- skipped the FK resolution that exists to prevent exactly that. Alias is
    -- now FUSION_PROJECT_ID (extracts.py) and this is where it lands.
    t_col('OC_TIME_ALLOCATION', 'FUSION_PROJECT_ID',  'VARCHAR2(50 CHAR)'),
    t_col('OC_TIME_ALLOCATION', 'PROJECT_NUMBER',     'VARCHAR2(60 CHAR)'),
    t_col('OC_TIME_ALLOCATION', 'TRACK_TIME_FLAG',    'CHAR(1)'),

    -- Fusion's own absence status, distinct from APPROVAL_STATUS: the pod
    -- returns absenceStatusCd SUBMITTED for a leave its own screen shows as
    -- Completed, so the two are not interchangeable.
    t_col('OC_TIME_ABSENCE',    'ABSENCE_STATUS',     'VARCHAR2(30 CHAR)'),

    t_col('OC_TIME_CALENDAR',   'SHIFT_NAME',         'VARCHAR2(100 CHAR)'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE ' || v(i).tab ||
                        ' ADD (' || v(i).col || ' ' || v(i).spec || ')';
      v_added := v_added + 1;
      DBMS_OUTPUT.PUT_LINE('added   ' || RPAD(v(i).tab, 22) || v(i).col);
    EXCEPTION WHEN OTHERS THEN
      -- ORA-01430: column being added already exists. Anything else is real.
      IF SQLCODE = -1430 THEN
        v_skip := v_skip + 1;
      ELSE
        DBMS_OUTPUT.PUT_LINE('FAILED  ' || v(i).tab || '.' || v(i).col ||
                             ' - ' || SUBSTR(SQLERRM, 1, 120));
        RAISE;
      END IF;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(v_added || ' column(s) added, ' || v_skip ||
                       ' already present.');
END;
/

-- Domain guards, added separately so a re-run that skipped the column still
-- gets its constraint. Y/N because that is what Fusion sends and what every
-- other flag in this schema uses.
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_project ADD CONSTRAINT
    chk_oc_tp_timeentry CHECK (time_entry_enabled IN ('Y','N'))~';
EXCEPTION WHEN OTHERS THEN IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_allocation ADD CONSTRAINT
    chk_oc_ta_tracktime CHECK (track_time_flag IN ('Y','N'))~';
EXCEPTION WHEN OTHERS THEN IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/2] Verification — what still has nowhere to land
PROMPT ============================================================

COLUMN table_name  FORMAT A22
COLUMN column_name FORMAT A22
COLUMN data_type   FORMAT A16

SELECT table_name, column_name, data_type
  FROM user_tab_columns
 WHERE (table_name, column_name) IN (
         ('OC_TIME_WORKER','EXPENDITURE_ORG'),
         ('OC_TIME_PROJECT','ORGANIZATION'),   ('OC_TIME_PROJECT','TIME_ENTRY_ENABLED'),
         ('OC_TIME_TASK','FUSION_PROJECT_ID'), ('OC_TIME_TASK','PROJECT_NUMBER'),
         ('OC_TIME_TASK','WBS_LEVEL'),         ('OC_TIME_TASK','PARENT_TASK_ID'),
         ('OC_TIME_TASK','START_DATE'),        ('OC_TIME_TASK','END_DATE'),
         ('OC_TIME_TASK','EXPENDITURE_TYPE'),
         ('OC_TIME_ALLOCATION','FUSION_PROJECT_ID'),
         ('OC_TIME_ALLOCATION','PROJECT_NUMBER'),
         ('OC_TIME_ALLOCATION','TRACK_TIME_FLAG'),
         ('OC_TIME_ABSENCE','ABSENCE_STATUS'),
         ('OC_TIME_CALENDAR','SHIFT_NAME'))
 ORDER BY table_name, column_name;

PROMPT
PROMPT Expect 15 rows. Anything missing did not get added and the loader will
PROMPT still drop that element without complaining.
