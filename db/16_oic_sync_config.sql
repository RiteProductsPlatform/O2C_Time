--==============================================================
-- time/16_oic_sync_config.sql
-- O2C Timesheet Module — OIC config table + the generic XML loader
--
-- Implements the two-integration design:
--
--   INT 001  schedule -> read this config -> for each row, call INT 002
--   INT 002  REST trigger -> run the BIP report at BIP_REPORT_PATH
--                         -> hand (TARGET_TABLE, raw XML) to OC_TIME_LOAD_XML
--                         -> write LASTSYNC_DATE / SYNC_STATUS back here
--
-- So OIC carries no mapping and no SQL. It knows a report path, a table name
-- and a date. Everything about what the columns are and how a row is matched
-- lives here, next to the tables it writes.
--
-- Idempotent. Depends on: time/01, time/02, time/06 (OC_TIME_SYNC_JOB/FAILED)
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] OC_TIME_SYNC_CONFIG — what INT 001 loops over
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_sync_config (
      CONFIG_ID        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      BIP_REPORT_NAME  VARCHAR2(60 CHAR)  NOT NULL,
      PURPOSE          VARCHAR2(400 CHAR),
      BIP_REPORT_PATH  VARCHAR2(400 CHAR) NOT NULL,
      TARGET_TABLE     VARCHAR2(30 CHAR)  NOT NULL,
      -- LASTSYNC_DATE is BOTH the bookmark and the parameter: INT 002 sends it
      -- to the report as :P_LAST_SYNC and writes the new one back on success.
      -- Advanced only on Success -- a Partial must not move it, or the rows
      -- that failed are never seen again.
      LASTSYNC_DATE    DATE,
      SYNC_MODE        VARCHAR2(12 CHAR) DEFAULT 'INCREMENTAL' NOT NULL,
      SYNC_STATUS      VARCHAR2(12 CHAR) DEFAULT 'Ready' NOT NULL,
      -- Daily / Monthly / Both. INT 001 runs on both schedules and filters.
      SCHEDULE_TAG     VARCHAR2(10 CHAR) DEFAULT 'Both' NOT NULL,
      -- ORDER IS NOT COSMETIC. OC_TIME_ALLOCATION has foreign keys to both
      -- worker and project, so an allocation whose worker has not loaded lands
      -- in OC_TIME_SYNC_FAILED instead of the table. INT 001 must ORDER BY
      -- this and process serially, not fan out.
      RUN_ORDER        NUMBER(3) DEFAULT 100 NOT NULL,
      ENABLED_FLAG     CHAR(1) DEFAULT 'Y' NOT NULL,
      -- ── last run, for the operator ───────────────────────────
      LAST_RUN_ON      TIMESTAMP,
      LAST_ROWS_READ   NUMBER(10),
      LAST_ROWS_MERGED NUMBER(10),
      LAST_ROWS_FAILED NUMBER(10),
      LAST_MESSAGE     VARCHAR2(2000 CHAR),
      LAST_JOB_RUN_ID  NUMBER,
      CREATED_BY       VARCHAR2(100) DEFAULT 'SYSTEM' NOT NULL,
      CREATED_ON       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY       VARCHAR2(100),
      UPDATED_ON       TIMESTAMP,
      CONSTRAINT chk_oc_tsc_mode   CHECK (sync_mode   IN ('FULL','INCREMENTAL')),
      CONSTRAINT chk_oc_tsc_status CHECK (sync_status IN
        ('Ready','Running','Success','Partial','Failed')),
      CONSTRAINT chk_oc_tsc_sched  CHECK (schedule_tag IN ('Daily','Monthly','Both')),
      CONSTRAINT chk_oc_tsc_enab   CHECK (enabled_flag IN ('Y','N')),
      CONSTRAINT uk_oc_tsc_name    UNIQUE (bip_report_name)
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CONFIG created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CONFIG already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/4] Seed the six loadable extracts
PROMPT ============================================================

-- Only the six that HAVE a target table. SHIFTS, WORK_PATTERNS, WORK_SCHEDULES
-- and EXP_TYPES are deliberately absent: they have nowhere to load, so putting
-- them in a loader's config would mean OIC calling a procedure that can only
-- fail. They stay as on-demand data models.
DECLARE
  TYPE t_row IS RECORD (nm VARCHAR2(60), pur VARCHAR2(400),
                        tbl VARCHAR2(30), ord NUMBER, sch VARCHAR2(10));
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('WORKERS',      'People, their manager, standard day and status (INT-001). '
                       || 'FIRST: everything else has a worker foreign key.',
          'OC_TIME_WORKER',     10, 'Both'),
    t_row('PROJECTS',     'Projects that track time and have a manager (INT-002).',
          'OC_TIME_PROJECT',    20, 'Both'),
    t_row('TASKS',        'WBS tasks with chargeable/billable flags (INT-002).',
          'OC_TIME_TASK',       30, 'Both'),
    t_row('ALLOCATIONS',  'Who may charge to what, and at what percentage (INT-003). '
                       || 'Needs WORKERS and PROJECTS already loaded.',
          'OC_TIME_ALLOCATION', 40, 'Both'),
    t_row('CALENDAR',     'Corporate working days and holidays (INT-004/005).',
          'OC_TIME_CALENDAR',   50, 'Monthly'),
    t_row('WORKER_SHIFTS','Per-person per-day shift, the SHIFT calendar layer. '
                       || 'Highest precedence, so a shift day beats a holiday.',
          'OC_TIME_CALENDAR',   60, 'Monthly'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_sync_config
           (bip_report_name, purpose, bip_report_path, target_table,
            sync_mode, schedule_tag, run_order)
    SELECT v(i).nm, v(i).pur, '/Custom/O2C_TIME/O2C_' || v(i).nm || '.xdm',
           v(i).tbl, 'INCREMENTAL', v(i).sch, v(i).ord
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_sync_config
                        WHERE bip_report_name = v(i).nm);
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Sync config seeded.');
END;
/

PROMPT ============================================================
PROMPT [3/4] OC_TIME_LOAD_XML — decode the BIP XML and merge it
PROMPT ============================================================

-- INT 002 calls this with a table name and the report's raw XML. It returns
-- counts and a status, so the integration can write SYNC_STATUS back without
-- interpreting anything.
--
-- FIVE THINGS THIS HAS TO GET RIGHT, and four of them fail SILENTLY if wrong.
--
-- 1. THE ROW TAG IS /DATA_DS/ROWSET/ROW.
--    The data models declare a group called G_1 and BIP does NOT use it in the
--    output -- it emits ROWSET/ROW regardless. Decoding G_1 returns zero rows
--    and reports success, which is indistinguishable from "the report found
--    nothing". This is recorded in integration/bip/bip_client.py for the same
--    reason.
--
-- 2. THE TABLE NAME IS VALIDATED AGAINST THE CONFIG, not just against
--    USER_TABLES. This builds dynamic SQL, so an unchecked name is an
--    injection point; restricting it to tables the config actually targets is
--    both the security check and a typo check.
--
-- 3. IT MERGES, IT DOES NOT INSERT. Every target has a natural key and the
--    whole design re-reads overlapping windows, so a plain INSERT would fail
--    with ORA-00001 on the second run of anything. The key is read from the
--    table's own primary or unique constraint rather than configured, so it
--    cannot drift from the table it protects.
--
-- 4. ONLY COLUMNS PRESENT IN BOTH THE XML AND THE TABLE ARE TOUCHED. A report
--    carrying an extra element must not error, and a table column the report
--    does not send must keep its value rather than be nulled.
--
--    WHICH MAKES THE ALIAS THE CONTRACT: the report's SELECT alias must equal
--    the table's column name, exactly. There is no mapping layer, by design --
--    a mapping table would be a third place for the same fact to be wrong.
--
--    MEASURED 10-Aug-2026 AGAINST THE CURRENT EXTRACTS, AND IT DOES NOT HOLD:
--
--      WORKERS        11/12 columns match  -> loads
--      PROJECTS        6/11               -> loads, but silently without
--                                            TIME_ENTRY_ENABLED, START/END_DATE
--      TASKS           4/12               -> loads, but WITHOUT BILLABLE_FLAG,
--                                            which the billable+chargeable rule
--                                            depends on entirely
--      ALLOCATIONS     7/9                -> loads
--      ABSENCES        4/6                -> loads, but DURATION_HOURS is
--                                            dropped, so every absence arrives
--                                            with zero hours
--      CALENDAR        5/7                -> BLOCKED: CALENDAR_DATE is not
--                                            CAL_DATE, so the key is uncovered
--      WORKER_SHIFTS   3/7                -> BLOCKED: CALENDAR_DATE and
--                                            EMPLOYEE_ID are not CAL_DATE and
--                                            SCOPE_KEY
--
--    The two BLOCKED ones fail loudly here, which is right. The dangerous ones
--    are TASKS and ABSENCES: they load, report success, and are wrong. Fix by
--    renaming the aliases in integration/bip/extracts.py to the table's column
--    names and redeploying the models -- mechanical, and it also collapses the
--    extract-versus-loader contract clash in the OIC design document into a
--    single canonical name per field.
--
-- 5. APP-OWNED COLUMNS ARE NEVER OVERWRITTEN. APP_ROLE is the obvious one --
--    it is the module's own, not Fusion's, and a sync that reset it would lock
--    people out of their own menus.
CREATE OR REPLACE PROCEDURE oc_time_load_xml(
  p_table_name  IN  VARCHAR2,
  p_xml         IN  CLOB,
  p_report_name IN  VARCHAR2 DEFAULT NULL,
  p_actor       IN  VARCHAR2 DEFAULT 'OIC',
  o_rows_read   OUT NUMBER,
  o_rows_merged OUT NUMBER,
  o_status      OUT VARCHAR2,
  o_message     OUT VARCHAR2)
AS
  -- Columns the module owns. Fusion has no opinion on these and a sync that
  -- wrote them would undo local decisions.
  c_never CONSTANT VARCHAR2(200) :=
    ',APP_ROLE,CREATED_BY,CREATED_ON,UPDATED_BY,UPDATED_ON,SYNC_JOB_RUN_ID,';

  v_tab      VARCHAR2(30);
  v_ok       NUMBER;
  v_cols     VARCHAR2(4000);   -- XMLTABLE column clause
  v_src      VARCHAR2(4000);   -- s.COL list
  v_set      VARCHAR2(4000);   -- UPDATE SET list
  v_ins      VARCHAR2(4000);   -- INSERT column list
  v_val      VARCHAR2(4000);   -- INSERT value list
  v_on       VARCHAR2(1000);   -- MERGE ON clause
  v_sql      CLOB;
  v_keycols  NUMBER := 0;
BEGIN
  o_rows_read := 0; o_rows_merged := 0; o_status := 'Failed';

  -- ── 2. the name must be one we target ──────────────────────
  v_tab := UPPER(TRIM(p_table_name));
  SELECT COUNT(*) INTO v_ok
    FROM oc_time_sync_config WHERE UPPER(target_table) = v_tab;
  IF v_ok = 0 THEN
    o_message := 'Table ' || v_tab || ' is not a target in OC_TIME_SYNC_CONFIG. '
              || 'Refusing to build SQL against it.';
    RETURN;
  END IF;

  IF p_xml IS NULL OR DBMS_LOB.GETLENGTH(p_xml) = 0 THEN
    o_message := 'The report returned no XML at all.';
    RETURN;
  END IF;

  -- ── 4. columns in BOTH the XML and the table ───────────────
  -- The XML side is read from the first ROW, so an element the report stops
  -- sending simply drops out instead of erroring.
  FOR c IN (
    SELECT t.column_name, t.data_type
      FROM user_tab_columns t
     WHERE t.table_name = v_tab
       AND INSTR(c_never, ',' || t.column_name || ',') = 0
       AND EXISTS (
             SELECT 1
               FROM XMLTABLE('/DATA_DS/ROWSET/ROW[1]/*'
                             PASSING XMLTYPE(p_xml)
                             COLUMNS nm VARCHAR2(128) PATH 'name()') x
              WHERE x.nm = t.column_name)
     ORDER BY t.column_id)
  LOOP
    -- Everything is read as a string and converted on the way in. BIP emits
    -- dates as YYYY-MM-DD text; letting Oracle guess would depend on NLS.
    v_cols := v_cols || ',' || c.column_name || ' VARCHAR2(4000) PATH ''' || c.column_name || '''';
    v_src  := v_src  || ',' ||
      CASE
        WHEN c.data_type = 'DATE'   THEN 'TO_DATE(x.' || c.column_name || ',''YYYY-MM-DD'')'
        WHEN c.data_type = 'NUMBER' THEN 'TO_NUMBER(x.' || c.column_name ||
                                         ' DEFAULT NULL ON CONVERSION ERROR)'
        ELSE 'x.' || c.column_name
      END || ' AS ' || c.column_name;
    v_ins  := v_ins  || ',' || c.column_name;
    v_val  := v_val  || ',s.' || c.column_name;
  END LOOP;

  IF v_cols IS NULL THEN
    o_message := 'No column in ' || v_tab || ' matches any element in the XML. '
              || 'Check the report''s SELECT aliases against the table.';
    RETURN;
  END IF;

  -- ── 3. the natural key, from the table itself ──────────────
  FOR k IN (
    SELECT cc.column_name
      FROM user_constraints c
      JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name
     WHERE c.table_name = v_tab
       AND c.constraint_type IN ('P','U')
       -- The identity primary key is not a natural key and matches nothing in
       -- a feed. Prefer a constraint whose columns the XML actually carries.
       AND NOT EXISTS (SELECT 1 FROM user_tab_columns g
                        WHERE g.table_name = v_tab
                          AND g.column_name = cc.column_name
                          AND g.identity_column = 'YES')
       AND INSTR(',' || LTRIM(v_ins, ',') || ',',
                 ',' || cc.column_name || ',') > 0
     ORDER BY c.constraint_type, c.constraint_name, cc.position)
  LOOP
    v_on := v_on || ' AND t.' || k.column_name || ' = s.' || k.column_name;
    v_keycols := v_keycols + 1;
    IF v_set IS NULL THEN v_set := ''; END IF;
  END LOOP;

  IF v_keycols = 0 THEN
    o_message := 'No primary or unique key on ' || v_tab
              || ' is covered by the XML, so rows cannot be matched. '
              || 'A plain insert would duplicate on the next run.';
    RETURN;
  END IF;

  -- Update everything that is not part of the match.
  FOR c IN (SELECT REGEXP_SUBSTR(LTRIM(v_ins, ','), '[^,]+', 1, LEVEL) AS nm
              FROM dual
           CONNECT BY LEVEL <= REGEXP_COUNT(v_ins, ','))
  LOOP
    IF INSTR(v_on, ' t.' || c.nm || ' = ') = 0 THEN
      v_set := v_set || ',t.' || c.nm || ' = s.' || c.nm;
    END IF;
  END LOOP;

  v_sql :=
    'MERGE INTO ' || v_tab || ' t USING (' ||
      'SELECT ' || LTRIM(v_src, ',') ||
      '  FROM XMLTABLE(''/DATA_DS/ROWSET/ROW'' PASSING :1 COLUMNS ' ||
           LTRIM(v_cols, ',') || ') x) s' ||
    ' ON (' || LTRIM(v_on, ' AND') || ')' ||
    CASE WHEN v_set IS NOT NULL AND LENGTH(v_set) > 0
         THEN ' WHEN MATCHED THEN UPDATE SET ' || LTRIM(v_set, ',') ELSE '' END ||
    ' WHEN NOT MATCHED THEN INSERT (' || LTRIM(v_ins, ',') ||
    ') VALUES (' || LTRIM(v_val, ',') || ')';

  SELECT COUNT(*) INTO o_rows_read
    FROM XMLTABLE('/DATA_DS/ROWSET/ROW' PASSING XMLTYPE(p_xml));

  EXECUTE IMMEDIATE v_sql USING XMLTYPE(p_xml);
  o_rows_merged := SQL%ROWCOUNT;
  COMMIT;

  o_status  := 'Success';
  o_message := o_rows_merged || ' of ' || o_rows_read || ' row(s) merged into '
            || v_tab || '.';

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    o_status  := 'Failed';
    -- The ORA number matters to whoever reads SYNC_STATUS later, so it is kept
    -- rather than replaced with a friendly sentence.
    o_message := SUBSTR('Load into ' || v_tab || ' failed: ' || SQLERRM, 1, 2000);
    -- Recorded where the other sync failures already live, so one queue shows
    -- everything rather than this path being invisible.
    BEGIN
      INSERT INTO oc_time_sync_failed
             (job_run_id, entity_type, entity_key, failure_reason, failure_code)
      VALUES (NULL, NVL(p_report_name, v_tab), v_tab,
              SUBSTR(o_message, 1, 1000), SQLCODE);
      COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;   -- never let logging mask the real error
    END;
END oc_time_load_xml;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN object_name FORMAT A26
COLUMN object_type FORMAT A10
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_SYNC_CONFIG','OC_TIME_LOAD_XML')
 ORDER BY object_type;

COLUMN bip_report_name FORMAT A16
COLUMN target_table    FORMAT A22
COLUMN bip_report_path FORMAT A40

SELECT run_order, bip_report_name, target_table, schedule_tag, sync_mode
  FROM oc_time_sync_config
 ORDER BY run_order;

PROMPT Done. INT 001 reads OC_TIME_SYNC_CONFIG; INT 002 calls OC_TIME_LOAD_XML.
