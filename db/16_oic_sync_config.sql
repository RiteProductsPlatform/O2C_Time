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
      -- Nullable on purpose. All eleven reports are registered here, including
      -- the four that have nowhere to load and the one that is read live, so
      -- the config is the complete inventory. A missing row is invisible; a
      -- disabled row with a PURPOSE explains itself.
      TARGET_TABLE     VARCHAR2(30 CHAR),
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
      -- ── foreign-key resolution ───────────────────────────────
      -- ORDERING ALONE DOES NOT FIX A FOREIGN KEY, and conflating the two
      -- wastes a day. Loading projects before tasks guarantees the PARENT ROW
      -- EXISTS; it does nothing about the fact that the report sends Fusion's
      -- project id (300000123456789) while OC_TIME_TASK.PROJECT_ID is our own
      -- GENERATED ALWAYS identity (47). Different id spaces, so the value
      -- matches nothing however carefully you sequence the loads.
      --
      -- FK_COLUMN is the local column to fill; FK_LOOKUP_SQL is a scalar
      -- subquery that finds it from something the XML DOES carry. Both null
      -- for entities that need no resolution.
      --
      -- Ordering is still required -- the lookup can only succeed once the
      -- parent is loaded -- so the two work together rather than one replacing
      -- the other.
      FK_COLUMN        VARCHAR2(30 CHAR),
      FK_LOOKUP_SQL    VARCHAR2(1000 CHAR),
      -- The columns the MERGE matches on, comma separated. Optional: when null
      -- the loader discovers the key from the table's primary or unique
      -- CONSTRAINTS.
      --
      -- It is here because discovery cannot see everything. OC_TIME_TASK is
      -- keyed by UK_OC_TTSK_WBS on (PROJECT_ID, UPPER(TASK_CODE)) -- a unique
      -- INDEX, not a constraint, so it never appears in USER_CONSTRAINTS. The
      -- loader found no key at all, and once given one on FUSION_TASK_ID it
      -- matched on that instead, which is a DIFFERENT key from the one the
      -- table enforces: a row can miss on the fusion id, be treated as new,
      -- and then collide on (project, code) with ORA-00001.
      --
      -- POST sync/task already keys on (project, task code) for exactly this
      -- reason. Declaring it makes the two agree instead of each guessing.
      MERGE_KEY        VARCHAR2(200 CHAR),
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
      -- Enabled means "INT 001 will hand this to the loader", and the loader
      -- needs somewhere to put it. Disabled rows may have no target.
      CONSTRAINT chk_oc_tsc_tgt    CHECK (enabled_flag = 'N'
                                          OR target_table IS NOT NULL),
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

-- Already-installed schemas: relax TARGET_TABLE and add the guard. Separate
-- blocks so one already being done does not skip the other.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_config MODIFY (target_table NULL)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1451 THEN NULL;   -- already nullable
  ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_sync_config ADD CONSTRAINT
    chk_oc_tsc_tgt CHECK (enabled_flag = 'N' OR target_table IS NOT NULL)~';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -2264 THEN NULL;   -- constraint name already used
  ELSE RAISE; END IF;
END;
/

-- One ALTER PER COLUMN, not one ALTER adding three.
--
-- A combined ADD is atomic: on a schema where fk_column already exists -- which
-- is every schema that ran the previous version of this file -- Oracle raises
-- ORA-01430 for that one column and adds NONE of them. The guard below then
-- swallows it, the script reports success, and MERGE_KEY silently does not
-- exist. Every TASKS load afterwards falls back to discovery and merges on the
-- wrong key. Per-column, each add fails or succeeds on its own.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(200);
  v t_tab := t_tab(
    'fk_column VARCHAR2(30 CHAR)',
    'fk_lookup_sql VARCHAR2(1000 CHAR)',
    'merge_key VARCHAR2(200 CHAR)');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_config ADD (' || v(i) || ')';
      DBMS_OUTPUT.PUT_LINE('added   ' || v(i));
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;   -- already there
    END;
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [2/4] Seed all eleven reports — six enabled, five off with a reason
PROMPT ============================================================

-- ALL ELEVEN are registered. Six are enabled; five are off and say why in
-- PURPOSE. Leaving them out entirely was the wrong call -- an operator counting
-- eleven data models and six config rows has no way to tell whether the other
-- five are deliberate or forgotten.
DECLARE
  TYPE t_row IS RECORD (nm VARCHAR2(60), pur VARCHAR2(400),
                        tbl VARCHAR2(30), ord NUMBER, sch VARCHAR2(10),
                        en VARCHAR2(1));
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('WORKERS',      'People, their manager, standard day and status (INT-001). '
                       || 'FIRST: everything else has a worker foreign key.',
          'OC_TIME_WORKER',     10, 'Both', 'Y'),
    t_row('PROJECTS',     'Projects that track time and have a manager (INT-002).',
          'OC_TIME_PROJECT',    20, 'Both', 'Y'),
    t_row('TASKS',        'WBS tasks with chargeable/billable flags (INT-002).',
          'OC_TIME_TASK',       30, 'Both', 'Y'),
    t_row('ALLOCATIONS',  'Who may charge to what, and at what percentage (INT-003). '
                       || 'Needs WORKERS and PROJECTS already loaded.',
          'OC_TIME_ALLOCATION', 40, 'Both', 'Y'),
    t_row('CALENDAR',     'Corporate working days and holidays (INT-004/005).',
          'OC_TIME_CALENDAR',   50, 'Both', 'Y'),
    t_row('WORKER_SHIFTS','Per-person per-day shift, the SHIFT calendar layer. '
                       || 'Highest precedence, so a shift day beats a holiday.',
          'OC_TIME_CALENDAR',   60, 'Both', 'Y'),
    -- ── registered, deliberately not scheduled ───────────────
    t_row('ABSENCES',     'OFF: absence is read LIVE per person per date at page '
                       || 'load, not synced (decision 09-Aug-2026). The model is '
                       || 'kept because the leave-loss absentee list still needs '
                       || 'a bulk read. Enable only if that decision changes.',
          'OC_TIME_ABSENCE',    70, 'Both',    'N'),
    t_row('SHIFTS',       'OFF: no target table. A shift dictionary (code, '
                       || 'duration, break) with no date, so it does not fit '
                       || 'OC_TIME_CALENDAR, which is one row per day. '
                       || 'Diagnostic only.',
          NULL,                 80, 'Both',    'N'),
    t_row('WORK_PATTERNS','OFF: no target table. A pattern template keyed on '
                       || 'day-of-cycle, not a calendar date. Fusion has already '
                       || 'resolved it into WORKER_SHIFTS, which is what loads.',
          NULL,                 90, 'Both',    'N'),
    t_row('WORK_SCHEDULES','OFF: no target table. Assigns a schedule to a person '
                       || 'for a DATE RANGE; OC_TIME_CALENDAR is per day. Useful '
                       || 'for explaining why someone has the shift they have.',
          NULL,                100, 'Both',    'N'),
    t_row('EXP_TYPES',    'OFF: reference only. The legal values for expenditure '
                       || 'type. Nothing consumes it yet -- see the POET gap: '
                       || 'OC_TIME_TASK has no EXPENDITURE_TYPE column.',
          NULL,                110, 'Both',    'N'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_sync_config
           (bip_report_name, purpose, bip_report_path, target_table,
            sync_mode, schedule_tag, run_order, enabled_flag)
    SELECT v(i).nm, v(i).pur, '/Custom/O2C_TIME/O2C_' || v(i).nm || '.xdm',
           v(i).tbl, 'INCREMENTAL', v(i).sch, v(i).ord, v(i).en
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_sync_config
                        WHERE bip_report_name = v(i).nm);
  END LOOP;
  -- The two entities whose parent key arrives in the wrong id space. Both
  -- reports already emit PROJECT_NUMBER, and 17_sync_column_gaps.sql gives it
  -- a real column, so the loader decodes it and the lookup can read it.
  UPDATE oc_time_sync_config
     SET fk_column     = 'PROJECT_ID',
         fk_lookup_sql = '(SELECT p.project_id FROM oc_time_project p '
                      || 'WHERE p.project_number = x.PROJECT_NUMBER)'
   WHERE bip_report_name IN ('TASKS','ALLOCATIONS')
     AND fk_column IS NULL;

  -- CALENDAR and WORKER_SHIFTS run on BOTH schedules, not Monthly only.
  --
  -- A holiday added mid-month, a shift reassigned, a working pattern changed --
  -- each moves the hours a default produces for days that have not happened
  -- yet, and on Monthly-only they would not be seen until the next month was
  -- built. By then the days they affect are already populated with the old
  -- calendar, and correcting them is an adjustment rather than a prepopulation.
  --
  -- Cheap to do daily: 142 and 2351 rows, and both are incremental.
  UPDATE oc_time_sync_config
     SET schedule_tag = 'Both'
   WHERE bip_report_name IN ('CALENDAR','WORKER_SHIFTS')
     AND schedule_tag <> 'Both';

  -- Match what UK_OC_TTSK_WBS enforces, not what discovery happens to find.
  UPDATE oc_time_sync_config
     SET merge_key = 'PROJECT_ID,TASK_CODE'
   WHERE bip_report_name = 'TASKS' AND merge_key IS NULL;

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
  v_fkcol    VARCHAR2(30);
  v_fksql    VARCHAR2(1000);
  v_mkey     VARCHAR2(200);
  v_capture  VARCHAR2(1)   := 'N';
  v_keyexpr  VARCHAR2(2000);          -- the merge key, as a printable string
  v_oldj     VARCHAR2(4000);          -- JSON_ARRAY(...) over t.<cols>
  v_newj     VARCHAR2(4000);          -- the same over s.<cols>
  v_cap      CLOB;
BEGIN
  o_rows_read := 0; o_rows_merged := 0; o_status := 'Failed';

  -- ── 2. the name must be one we target ──────────────────────
  v_tab := UPPER(TRIM(p_table_name));
  SELECT COUNT(*) INTO v_ok
    FROM oc_time_sync_config WHERE UPPER(target_table) = v_tab;

  -- The resolution rule, if this feed has one. Read by report name when given,
  -- because two reports can share a table -- CALENDAR and WORKER_SHIFTS both
  -- write OC_TIME_CALENDAR -- and only one of them may need a lookup.
  BEGIN
    SELECT MAX(fk_column), MAX(fk_lookup_sql), MAX(merge_key),
           NVL(MAX(capture_changes), 'N')
      INTO v_fkcol, v_fksql, v_mkey, v_capture
      FROM oc_time_sync_config
     WHERE UPPER(target_table) = v_tab
       AND (p_report_name IS NULL OR bip_report_name = p_report_name);
  EXCEPTION WHEN NO_DATA_FOUND THEN v_fkcol := NULL;
  END;

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
       -- GENERATED ALWAYS columns cannot be written at all (ORA-32795), and
       -- this is not hypothetical: OC_TIME_TASK.TASK_ID and
       -- OC_TIME_PROJECT.PROJECT_ID are local identity keys while the extracts
       -- emit elements of the SAME NAME carrying Fusion's ids. Without this the
       -- merge fails outright -- and if it did not, it would be silently
       -- conflating two different id spaces. Fusion's ids belong in
       -- FUSION_TASK_ID / FUSION_PROJECT_ID; see the alias note above.
       AND t.identity_column = 'NO'
       -- A COLUMN WE RESOLVE IS NEVER READ FROM THE XML. This is the whole
       -- point of the lookup and it was previously defeated by its own guard.
       --
       -- ALLOCATIONS selects Fusion's project id as "pp.project_id AS
       -- project_id" -- the exact name of OC_TIME_ALLOCATION.PROJECT_ID, which
       -- is our LOCAL surrogate foreign key. Without this line the scan below
       -- picks PROJECT_ID up as an ordinary column, and the resolution block
       -- further down then finds it already present and SKIPS ITSELF. Fusion's
       -- 300000337787982 goes straight into the local FK: ORA-02291 if no local
       -- project happens to hold that number, and -- far worse -- a silent
       -- attachment to the WRONG project if one does.
       --
       -- TASKS was safe only by luck: its extract aliases to FUSION_PROJECT_ID,
       -- so PROJECT_ID was absent from the XML and the guard's condition held.
       -- The identity_column test above exists for this same reason; it does
       -- not cover this case because a foreign key is not an identity column.
       AND (v_fkcol IS NULL OR t.column_name <> v_fkcol)
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

  -- Resolve the parent key. Added to the source select and the insert, but NOT
  -- to the XMLTABLE column list -- it is computed from the XML, not read out of
  -- it, and reading it would take Fusion's id straight into a local FK.
  -- Unconditional. The "only if not already present" test that used to wrap
  -- this was the bug described in the scan above: it handed control to whatever
  -- the report happened to name its columns. The scan now excludes v_fkcol
  -- outright, so the resolution is the ONLY thing that can populate it.
  IF v_fkcol IS NOT NULL AND v_fksql IS NOT NULL THEN
    v_src := v_src || ',' || v_fksql || ' AS ' || v_fkcol;
    v_ins := v_ins || ',' || v_fkcol;
    v_val := v_val || ',s.' || v_fkcol;
  END IF;

  -- ZERO ROWS IS SUCCESS, NOT A CONFIGURATION FAULT.
  --
  -- An incremental feed returning nothing is the NORMAL case -- most nights
  -- most reports have no changes -- and it must not be confused with a report
  -- whose aliases do not match the table.
  --
  -- The two look identical to the column scan: it reads ROW[1]/*, and with no
  -- ROW element there is nothing to match, so v_cols is null either way. Told
  -- apart by counting the rows first.
  --
  -- Getting this wrong is self-perpetuating, which is how it hid. A quiet
  -- night reported Failed, the failure path deliberately does NOT advance
  -- LASTSYNC_DATE, so the next run read a stale bookmark and pulled everything
  -- again -- and a full pull always has rows, so it always "worked". The
  -- symptom was a sync that appeared to ignore its delta.
  SELECT COUNT(*) INTO o_rows_read
    FROM XMLTABLE('/DATA_DS/ROWSET/ROW' PASSING XMLTYPE(p_xml));

  IF o_rows_read = 0 THEN
    o_rows_merged := 0;
    o_status      := 'Success';
    o_message     := 'No rows changed since the last sync. Nothing to merge.';

    -- The bookmark still moves. The report was asked what changed and
    -- answered "nothing" -- that answer is as complete as a thousand rows, and
    -- leaving the bookmark behind would re-ask the same question for ever.
    UPDATE oc_time_sync_config
       SET lastsync_date    = TRUNC(SYSDATE),
           sync_status      = 'Success',
           last_run_on      = SYSTIMESTAMP,
           last_rows_read   = 0,
           last_rows_merged = 0,
           last_message     = o_message,
           updated_by       = NVL(p_actor, 'OIC'),
           updated_on       = SYSTIMESTAMP
     WHERE UPPER(target_table) = v_tab
       AND (p_report_name IS NULL OR bip_report_name = p_report_name);
    COMMIT;
    RETURN;
  END IF;

  IF v_cols IS NULL THEN
    o_message := 'The report returned ' || o_rows_read || ' row(s) but no '
              || 'column in ' || v_tab || ' matches any element in them. '
              || 'Check the report''s SELECT aliases against the table.';
    RETURN;
  END IF;

  -- ── 3. the natural key ─────────────────────────────────────
  -- A declared MERGE_KEY wins. Discovery is the fallback, and it can only see
  -- what is in USER_CONSTRAINTS -- a unique INDEX is invisible to it.
  IF v_mkey IS NOT NULL THEN
    FOR k IN (SELECT TRIM(REGEXP_SUBSTR(v_mkey, '[^,]+', 1, LEVEL)) AS column_name
                FROM dual
             CONNECT BY LEVEL <= REGEXP_COUNT(v_mkey, ',') + 1)
    LOOP
      IF INSTR(',' || LTRIM(v_ins, ',') || ',', ',' || k.column_name || ',') = 0 THEN
        o_message := 'MERGE_KEY names ' || k.column_name || ', which is neither '
                  || 'in the XML nor resolved. Check the config against the report.';
        RETURN;
      END IF;
      v_on := v_on || ' AND t.' || k.column_name || ' = s.' || k.column_name;
      v_keyexpr := v_keyexpr || '||''|''||TO_CHAR(s.' || k.column_name || ')';
      v_keycols := v_keycols + 1;
    END LOOP;
  END IF;

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
    EXIT WHEN v_mkey IS NOT NULL;          -- declared key already applied
    v_on := v_on || ' AND t.' || k.column_name || ' = s.' || k.column_name;
    v_keyexpr := v_keyexpr || '||''|''||TO_CHAR(s.' || k.column_name || ')';
    v_keycols := v_keycols + 1;
  END LOOP;
  IF v_set IS NULL THEN v_set := ''; END IF;

  IF v_keycols = 0 THEN
    o_message := 'No primary or unique key on ' || v_tab
              || ' is covered by the XML, so rows cannot be matched. '
              || 'A plain insert would duplicate on the next run.';
    RETURN;
  END IF;

  -- Update everything that is not part of the match.
  --
  -- EXCEPT that a Fusion identifier is never overwritten with nothing. Every
  -- other column is assigned straight from the source, which is correct: a
  -- cleared END_DATE must actually clear. A Fusion id is different in kind --
  -- it is the only thing that can name our row back to Fusion for the OTL push
  -- (INT-007), and Fusion never un-assigns one. So an empty element means the
  -- report did not send it, not that the id was withdrawn.
  --
  -- Without the NVL, <FUSION_TASK_ID></FUSION_TASK_ID> parses to NULL and the
  -- MERGE writes that NULL over a good id. Nothing would raise: the column is
  -- nullable, and UK_OC_TTSK_FUSION permits any number of NULL rows because
  -- Oracle's unique constraints ignore them. The push would simply find nothing
  -- to send, for rows that used to be fine, with no error anywhere.
  --
  -- Matched on the FUSION_% naming rather than a list so a new Fusion id column
  -- is protected the day it is added, not the day someone remembers this.
  FOR c IN (SELECT REGEXP_SUBSTR(LTRIM(v_ins, ','), '[^,]+', 1, LEVEL) AS nm
              FROM dual
           CONNECT BY LEVEL <= REGEXP_COUNT(v_ins, ','))
  LOOP
    IF INSTR(v_on, ' t.' || c.nm || ' = ') = 0 THEN
      -- SUBSTR, not LIKE 'FUSION\_%' ESCAPE '\'. The underscore is LIKE's
      -- single-character wildcard, so it needs a backslash, and a backslash in
      -- a PL/SQL literal is fragile in ways that have nothing to do with
      -- Oracle: it was lost in transit writing this file, leaving ESCAPE ''
      -- -- a zero-length escape character, ORA-06502, raised on EVERY load
      -- rather than on some unlucky column name. SUBSTR has no wildcards, no
      -- escape and no way to be silently corrupted.
      IF SUBSTR(c.nm, 1, 7) = 'FUSION_' THEN
        v_set := v_set || ',t.' || c.nm || ' = NVL(s.' || c.nm || ', t.' || c.nm || ')';
      ELSE
        v_set := v_set || ',t.' || c.nm || ' = s.' || c.nm;
      END IF;
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

  -- o_rows_read was counted above, before the zero-row check.

  -- ── 4. the before-image, BEFORE the merge destroys it ──────
  -- The MERGE below overwrites every non-key column. Once it has run, the
  -- previous project, task, billable type and percentage are gone, and a
  -- Reversal that must "subtract the hours from the OLD project" has nothing
  -- left to name. There is no recovering it afterwards -- only the new value
  -- exists -- so it is captured here or not at all.
  --
  -- Both sides are stored as a JSON array of {name,value}. An array rather than
  -- an object because the reader iterates unknown keys, and a whole row rather
  -- than one record per changed column because an adjustment needs the row as a
  -- coherent whole. V_OC_TIME_SYNC_CHANGE_COL derives the per-column view.
  --
  -- LEFT JOIN, so a genuinely new row is captured as INSERT with a null
  -- OLD_ROW: a new allocation is an addition and needs an Adjustment(+) just as
  -- much as a moved one needs the pair.
  --
  -- Same transaction as the MERGE. If the merge fails, the capture rolls back
  -- with it -- a recorded change that did not happen would be worse than none.
  IF v_capture = 'Y' AND v_keyexpr IS NOT NULL THEN
    FOR c IN (SELECT REGEXP_SUBSTR(LTRIM(v_ins, ','), '[^,]+', 1, LEVEL) AS nm
                FROM dual
             CONNECT BY LEVEL <= REGEXP_COUNT(v_ins, ','))
    LOOP
      v_oldj := v_oldj || ',JSON_OBJECT(''name'' VALUE ''' || c.nm ||
                ''', ''value'' VALUE TO_CHAR(t.' || c.nm || '))';
      v_newj := v_newj || ',JSON_OBJECT(''name'' VALUE ''' || c.nm ||
                ''', ''value'' VALUE TO_CHAR(s.' || c.nm || '))';
    END LOOP;

    v_cap :=
      'INSERT INTO oc_time_sync_change (report_name, target_table, row_key, '
   || '       change_type, old_row, new_row, created_by) '
   || 'SELECT :1, :2, SUBSTR(' || LTRIM(v_keyexpr, '|''') || ', 1, 400), '
   || '       CASE WHEN t.ROWID IS NULL THEN ''INSERT'' ELSE ''UPDATE'' END, '
   || '       CASE WHEN t.ROWID IS NULL THEN NULL ELSE JSON_ARRAY('
   ||            LTRIM(v_oldj, ',') || ' RETURNING CLOB) END, '
   || '       JSON_ARRAY(' || LTRIM(v_newj, ',') || ' RETURNING CLOB), :3 '
   || '  FROM (SELECT ' || LTRIM(v_src, ',')
   || '          FROM XMLTABLE(''/DATA_DS/ROWSET/ROW'' PASSING :4 COLUMNS '
   ||                LTRIM(v_cols, ',') || ') x) s '
   || '  LEFT JOIN ' || v_tab || ' t ON (' || LTRIM(v_on, ' AND') || ') '
   -- Only actual differences. Re-reading an overlapping window is normal and
   -- most rows come back identical; recording those would bury the real
   -- changes under thousands of no-ops every single night.
   -- DBMS_LOB.COMPARE, not <>. Two CLOBs cannot be compared with a relational
   -- operator in SQL; Oracle wants the LOB package, and the failure surfaces at
   -- RUN time from dynamic SQL rather than at compile time.
   || ' WHERE t.ROWID IS NULL '
   || '    OR DBMS_LOB.COMPARE('
   || '         JSON_ARRAY(' || LTRIM(v_oldj, ',') || ' RETURNING CLOB),'
   || '         JSON_ARRAY(' || LTRIM(v_newj, ',') || ' RETURNING CLOB)) != 0';

    BEGIN
      EXECUTE IMMEDIATE v_cap
        USING NVL(p_report_name, v_tab), v_tab, NVL(p_actor, 'OIC'),
              XMLTYPE(p_xml);
    EXCEPTION WHEN OTHERS THEN
      -- Capture must never stop a load. A sync that refuses to run because it
      -- could not write an audit row helps nobody, but a SILENT failure to
      -- capture is exactly what this file exists to prevent -- so it is
      -- recorded where the other sync failures already are.
      --
      -- AND THE LOGGING ITSELF IS GUARDED. Without the inner handler this block
      -- masked the very error it was reporting: OC_TIME_SYNC_FAILED.JOB_RUN_ID
      -- was NOT NULL, the INSERT raised ORA-01400, that escaped, and the load
      -- returned "Load into OC_TIME_CALENDAR failed: ORA-01400 ... JOB_RUN_ID"
      -- -- naming the logging table for a fault in the capture, with the real
      -- cause gone. An error handler that can raise is not one.
      DECLARE
        v_ce VARCHAR2(400) := SUBSTR(SQLERRM, 1, 400);
      BEGIN
        INSERT INTO oc_time_sync_failed
               (job_run_id, entity_type, entity_key, failure_reason, failure_code)
        VALUES (NULL, NVL(p_report_name, v_tab), 'CHANGE_CAPTURE',
                'Before-image capture failed; the merge still ran, so the '
             || 'previous values for this batch are NOT recoverable: ' || v_ce,
                -1);
      EXCEPTION WHEN OTHERS THEN NULL;   -- see below
      END;
    END;
  END IF;

  -- If the lookup resolves nothing at all, the parent almost certainly has not
  -- been loaded yet -- which is a RUN_ORDER problem, not a data problem, and
  -- saying so is worth far more than ORA-02291 or a table of null keys.
  IF v_fkcol IS NOT NULL THEN
    DECLARE
      v_unres NUMBER;
    BEGIN
      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM (SELECT ' || v_fksql || ' AS k FROM XMLTABLE(' ||
        '''/DATA_DS/ROWSET/ROW'' PASSING :1 COLUMNS ' || LTRIM(v_cols, ',') ||
        ') x) WHERE k IS NULL'
        INTO v_unres USING XMLTYPE(p_xml);
      IF v_unres > 0 AND v_unres = o_rows_read THEN
        o_message := 'None of the ' || o_rows_read || ' rows could resolve '
                  || v_fkcol || '. The parent is probably not loaded yet -- '
                  || 'check RUN_ORDER, this feed must run after its parent.';
        RETURN;
      ELSIF v_unres > 0 THEN
        o_message := v_unres || ' row(s) could not resolve ' || v_fkcol || '. ';
      END IF;
    END;
  END IF;

  EXECUTE IMMEDIATE v_sql USING XMLTYPE(p_xml);
  o_rows_merged := SQL%ROWCOUNT;

  -- ── 5. advance the bookmark, IN THIS TRANSACTION ───────────
  -- The header of this file has always said INT 002 "writes the new one back on
  -- success". It never did -- there was no UPDATE anywhere in this procedure.
  -- LASTSYNC_DATE stayed null for ever, so every run passed null as
  -- :P_LAST_SYNC, the report's NVL turned that into 1900, and every
  -- "incremental" sync was silently a full pull. Correct results, wrong volume,
  -- no error, and nothing in the sync status to show it.
  --
  -- HERE rather than in OIC. Before the COMMIT, so the bookmark and the rows it
  -- accounts for land together: if the merge rolls back the bookmark does too.
  -- A writeback from OIC is a second clock that cannot be transactional with
  -- the merge, and the first partial failure separates them permanently.
  --
  -- TRUNC(SYSDATE), not SYSTIMESTAMP. The delta compares
  -- GREATEST(...) > TO_DATE(:P_LAST_SYNC,'YYYY-MM-DD') -- DAY granularity -- so
  -- stamping midnight today makes tomorrow's run re-read everything changed
  -- today. That is deliberate: it over-reads a few rows rather than missing the
  -- ones changed between the report running and the merge finishing. Every row
  -- is a MERGE on the natural key, so re-reading costs nothing and a miss is
  -- permanent.
  UPDATE oc_time_sync_config
     SET lastsync_date    = TRUNC(SYSDATE),
         sync_status      = 'Success',
         last_run_on      = SYSTIMESTAMP,
         last_rows_read   = o_rows_read,
         last_rows_merged = o_rows_merged,
         last_message     = SUBSTR(NVL(o_message, '') || o_rows_merged || ' of '
                                || o_rows_read || ' merged.', 1, 2000),
         updated_by       = NVL(p_actor, 'OIC'),
         updated_on       = SYSTIMESTAMP
   WHERE UPPER(target_table) = v_tab
     AND (p_report_name IS NULL OR bip_report_name = p_report_name);

  COMMIT;

  o_status  := 'Success';
  o_message := NVL(o_message, '') || o_rows_merged || ' of ' || o_rows_read
            || ' row(s) merged into ' || v_tab || '.';

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    o_status  := 'Failed';
    -- The ORA number matters to whoever reads SYNC_STATUS later, so it is kept
    -- rather than replaced with a friendly sentence.
    o_message := SUBSTR('Load into ' || v_tab || ' failed: ' || SQLERRM, 1, 2000);

    -- Status and message, but NOT lastsync_date. The bookmark must not move on
    -- a failure or the rows this run could not merge are never offered again.
    BEGIN
      UPDATE oc_time_sync_config
         SET sync_status  = 'Failed',
             last_run_on  = SYSTIMESTAMP,
             last_message = SUBSTR(o_message, 1, 2000),
             updated_by   = NVL(p_actor, 'OIC'),
             updated_on   = SYSTIMESTAMP
       WHERE UPPER(target_table) = v_tab
         AND (p_report_name IS NULL OR bip_report_name = p_report_name);
      COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    -- Recorded where the other sync failures already live, so one queue shows
    -- everything rather than this path being invisible.
    BEGIN
      DECLARE
        -- SQLCODE IS PL/SQL-ONLY AND CANNOT APPEAR INSIDE A SQL STATEMENT.
        -- Used directly in the VALUES list it is ORA-00984, "column not
        -- allowed here" -- the parser reads it as a column name. Same family as
        -- the SQLERRM trap, and the identical mistake is already commented in
        -- 13_ords_time_admin.sql, which is where this should have been copied
        -- from. SQLERRM on the line above is fine: that is a PL/SQL assignment,
        -- not a SQL statement.
        v_code NUMBER := SQLCODE;
      BEGIN
        INSERT INTO oc_time_sync_failed
               (job_run_id, entity_type, entity_key, failure_reason, failure_code)
        VALUES (NULL, NVL(p_report_name, v_tab), v_tab,
                SUBSTR(o_message, 1, 1000), v_code);
        COMMIT;
      END;
    EXCEPTION WHEN OTHERS THEN NULL;   -- never let logging mask the real error
    END;
END oc_time_load_xml;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [3b/4] The two queue views — what INT 001 selects from
PROMPT ============================================================

-- OIC reads a view, not the table. Everything the orchestrator would otherwise
-- have to get right in a mapper is settled here instead:
--
--   * ENABLED_FLAG and SCHEDULE_TAG filtered, so the disabled rows and the ones
--     that do not belong to this schedule never reach the loop at all
--   * ORDER BY RUN_ORDER, because OC_TIME_ALLOCATION has foreign keys to both
--     worker and project. Out of order, allocations land in OC_TIME_SYNC_FAILED
--     instead of the table and the run still reports success
--   * LAST_SYNC_DATE as 'YYYY-MM-DD' TEXT. As a DATE it reaches BIP as an ISO
--     timestamp and TO_DATE(:P_LAST_SYNC,'YYYY-MM-DD') raises ORA-01861
--   * EFFECTIVE_DATE computed, which is why there are TWO views rather than one
--     with a filter. It cannot be derived from the row: most rows are tagged
--     'Both' and the answer depends on WHICH SCHEDULE IS RUNNING, not on the
--     feed. Daily wants today; monthly wants next month.
--
-- ADD_MONTHS handles the December -> January rollover and month lengths. A
-- hand-rolled equivalent in an OIC mapper is exactly where that breaks.

CREATE OR REPLACE VIEW v_oc_time_sync_daily AS
SELECT bip_report_name, bip_report_path, target_table,
       -- '1900-01-01', NOT an empty string. Oracle cannot produce an empty
       -- string: '' IS NULL, so NVL(..., '') returns NULL and the column comes
       -- back null for every feed that has never run.
       --
       -- Over REST that was harmless -- JSON null, which BIP turns into its
       -- empty default and the report's own NVL turns into a full load. The
       -- DATABASE ADAPTER is stricter: it rejects a null in a key column
       -- outright, and four of the six feeds are null on a fresh schema. The
       -- whole orchestrator failed on the first row it read.
       --
       -- 1900-01-01 is the same value the report's NVL would have produced, so
       -- the meaning is unchanged -- it is simply stated rather than implied.
       NVL(TO_CHAR(lastsync_date, 'YYYY-MM-DD'), '1900-01-01') AS last_sync_date,
       TO_CHAR(TRUNC(SYSDATE), 'YYYY-MM-DD')              AS effective_date,
       run_order, sync_mode, sync_status, purpose
  FROM oc_time_sync_config
 WHERE enabled_flag = 'Y'
   AND schedule_tag IN ('Daily', 'Both')
 ORDER BY run_order, bip_report_name;

-- The monthly view also carries the period to populate afterwards, so the
-- orchestrator never has to work out which OC_TIME_PERIOD row "next month" is.
-- NULL means it does not exist yet -- a real precondition, not a data quirk:
-- with no period row the monthly run has nothing to build.
CREATE OR REPLACE VIEW v_oc_time_sync_monthly AS
SELECT c.bip_report_name, c.bip_report_path, c.target_table,
       -- ALWAYS 1900-01-01 -- the bookmark is deliberately NOT read here.
       --
       -- The delta predicate is ANDed onto the as-of filter, so a monthly run
       -- carrying a bookmark asks BIP for
       --
       --   allocations in force on 1-Sep AND changed since 11-Aug
       --
       -- An allocation created in June, effective 1-Sep onward, satisfies the
       -- first and fails the second. It is dropped -- and it is exactly the row
       -- the monthly run exists to fetch. September then populates from
       -- whatever the cache already holds, which the daily runs filled with the
       -- AUGUST as-of picture: everyone on their old projects, job status
       -- Success, nothing in the output that looks wrong.
       --
       -- A delta answers "what changed since". Once the as-of date moves to a
       -- future point the question is "what is true then", and that answer
       -- includes rows last touched months ago. Both filters cannot apply.
       --
       -- A LITERAL, not NULL, and not the daily view's NVL. The database
       -- adapter rejects a null in a key column outright -- see the note on
       -- V_OC_TIME_SYNC_DAILY -- so the full-pull sentinel has to be stated.
       -- 1900-01-01 is what the report's own NVL would have produced anyway.
       --
       -- Cost is not the objection it appears. Measured 11-Aug: a re-merge
       -- changing nothing runs in 4.9s against 17s for a cold build, because
       -- MERGE finds the rows already there. ALLOCATIONS is 1,595 rows.
       '1900-01-01'                                       AS last_sync_date,
       TO_CHAR(ADD_MONTHS(TRUNC(SYSDATE,'MM'), 1), 'YYYY-MM-DD')
                                                          AS effective_date,
       (SELECT MAX(p.period_id) FROM oc_time_period p
         WHERE p.start_date = ADD_MONTHS(TRUNC(SYSDATE,'MM'), 1))
                                                          AS target_period_id,
       c.run_order, c.sync_mode, c.sync_status, c.purpose
  FROM oc_time_sync_config c
 WHERE c.enabled_flag = 'Y'
   AND c.schedule_tag IN ('Monthly', 'Both')
 ORDER BY c.run_order, c.bip_report_name;

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

SELECT run_order, bip_report_name, enabled_flag,
       NVL(target_table,'(none)') AS target_table, schedule_tag, sync_mode
  FROM oc_time_sync_config
 ORDER BY run_order;

PROMPT (INT 001 must filter on ENABLED_FLAG = 'Y' and ORDER BY RUN_ORDER.)

PROMPT
PROMPT --- how each feed is matched -------------------------------
COLUMN matched_on FORMAT A34

-- Worth showing plainly: '(discovered)' means the loader will go looking in
-- USER_CONSTRAINTS, which cannot see a unique INDEX. OC_TIME_TASK is keyed by
-- one, so TASKS must read PROJECT_ID,TASK_CODE here and not '(discovered)'.
SELECT bip_report_name,
       NVL(target_table,'(none)')     AS target_table,
       NVL(merge_key,'(discovered)')  AS matched_on,
       NVL(fk_column,'-')             AS fk_column
  FROM oc_time_sync_config
 WHERE enabled_flag = 'Y'
 ORDER BY run_order;

PROMPT Done. INT 001 reads OC_TIME_SYNC_CONFIG; INT 002 calls OC_TIME_LOAD_XML.
