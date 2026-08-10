--==============================================================
-- time/19_sync_change_capture.sql
-- O2C Timesheet Module — keep the before-image the sync would otherwise destroy
--
-- WHY THIS HAS TO EXIST BEFORE ANY ADJUSTMENT RULE DOES
--
-- OC_TIME_LOAD_XML merges master data with a plain UPDATE SET t.col = s.col.
-- The moment the daily sync runs, the PREVIOUS project, task, billable type and
-- allocation percentage are gone -- overwritten, with nothing recording that
-- they were ever different.
--
-- The requirement is that a master-data change becomes a Reversal (subtract the
-- hours from the old project/task) and an Adjustment (add them to the new),
-- posted into the next open period. That is impossible to compute afterwards:
-- by the time anything looks, only the NEW value exists. The old one has to be
-- captured at the moment of the merge or it is not recoverable at all.
--
-- So this file is deliberately only the CAPTURE half. It records what changed,
-- from what, to what, and leaves ADJUSTMENT_STATUS = 'Pending'. It raises no
-- adjustment and applies no rule, because the flag/scenario workbook is still
-- out for functional validation and the rules are not settled. Capture is
-- unambiguous and blocks everything downstream; generation is not and does not.
--
-- OC_TS_AUDIT already models the timesheet side of this (OLD_/NEW_ project,
-- task, hours, bill type, and a CHANGE_TYPE that already includes 'Adjustment'
-- and 'Reversal'). This is the master-data side, which nothing fed.
--
-- Idempotent. Depends on: time/02, time/04, time/06, time/16
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/4] OC_TIME_SYNC_CHANGE — the before-image
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_time_sync_change (
      CHANGE_ID       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      REPORT_NAME     VARCHAR2(60 CHAR)  NOT NULL,
      TARGET_TABLE    VARCHAR2(30 CHAR)  NOT NULL,
      -- The merge key's values, concatenated, exactly as the loader matched on
      -- them. Text because the key differs per table -- (project, task code)
      -- here, (project, employee, start date) there -- and a typed column set
      -- would have to be the union of every table's key.
      ROW_KEY         VARCHAR2(400 CHAR) NOT NULL,
      CHANGE_TYPE     VARCHAR2(10 CHAR)  NOT NULL,
      -- The whole row, both sides, as JSON. NOT one row per changed column.
      --
      -- Per-column rows read nicely and are wrong here: an adjustment needs the
      -- row as a COHERENT WHOLE -- project AND task AND billable type AND dates
      -- as they stood together -- and reassembling that from scattered column
      -- rows means trusting that they all came from one merge. The JSON is the
      -- state, and V_OC_TIME_SYNC_CHANGE_COL below splits it per column for
      -- anyone who wants to read it that way.
      OLD_ROW         CLOB,
      NEW_ROW         CLOB,
      -- Pending until something acts on it. NOTHING sets this to Raised yet --
      -- the generation rules are not settled. A queue that is never drained is
      -- visible; a change that was never recorded is not.
      ADJUSTMENT_STATUS VARCHAR2(20 CHAR) DEFAULT 'Pending' NOT NULL,
      ADJUSTMENT_ID   NUMBER,
      DECIDED_BY      VARCHAR2(100 CHAR),
      DECIDED_ON      TIMESTAMP,
      DECISION_NOTE   VARCHAR2(1000 CHAR),
      SYNC_JOB_RUN_ID NUMBER,
      CREATED_BY      VARCHAR2(100 CHAR) DEFAULT 'SYSTEM'   NOT NULL,
      CREATED_ON      TIMESTAMP          DEFAULT SYSTIMESTAMP NOT NULL,
      UPDATED_BY      VARCHAR2(100 CHAR),
      UPDATED_ON      TIMESTAMP,
      CONSTRAINT chk_oc_tsch_type CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
      CONSTRAINT chk_oc_tsch_adjst   CHECK (adjustment_status IN
        ('Pending','Raised','NotRequired','Ignored'))
    )
  ~';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CHANGE created.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_CHANGE already exists - skipped.');
  ELSE RAISE; END IF;
END;
/

-- The queue read pattern: everything still Pending, oldest first.
BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsch_pending ON oc_time_sync_change '
                 || '(adjustment_status, created_on)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX ix_oc_tsch_row ON oc_time_sync_change '
                 || '(target_table, row_key)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/4] CAPTURE_CHANGES on the sync config
PROMPT ============================================================

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_config ADD '
                 || '(capture_changes CHAR(1) DEFAULT ''Y'' NOT NULL)';
  DBMS_OUTPUT.PUT_LINE('CAPTURE_CHANGES added.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1430 THEN
    DBMS_OUTPUT.PUT_LINE('CAPTURE_CHANGES already present - skipped.');
  ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE q'~ALTER TABLE oc_time_sync_config ADD CONSTRAINT
    chk_oc_tsc_capture CHECK (capture_changes IN ('Y','N'))~';
EXCEPTION WHEN OTHERS THEN IF SQLCODE IN (-2264, -2261) THEN NULL; ELSE RAISE; END IF;
END;
/

-- ON for everything, by instruction: costing and accrual are derived from all
-- of it, so there is no feed whose changes are safely ignorable. CALENDAR and
-- SHIFTS included -- a changed working day moves the hours a default produces.
UPDATE oc_time_sync_config SET capture_changes = 'Y' WHERE capture_changes IS NULL;
COMMIT;

PROMPT ============================================================
PROMPT [2b/4] OC_TIME_SYNC_FAILED.JOB_RUN_ID must accept NULL
PROMPT ============================================================

-- A failure that happened OUTSIDE a scheduled job is still a failure, and until
-- now it could not be recorded: JOB_RUN_ID was NOT NULL, so every attempt to
-- log one raised ORA-01400 -- from inside an exception handler, which then
-- reported the logging table's constraint instead of whatever had actually gone
-- wrong. Measured on the live endpoint: a CALENDAR load came back "Load into
-- OC_TIME_CALENDAR failed: ORA-01400 ... OC_TIME_SYNC_FAILED.JOB_RUN_ID" and
-- the real cause was simply gone.
--
-- The foreign key stays and still validates a job id when one is given; it just
-- no longer insists there is one. ON DELETE CASCADE cannot reach rows with a
-- null parent, which is correct -- they belong to no job to be cascaded from.
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE oc_time_sync_failed MODIFY (job_run_id NULL)';
  DBMS_OUTPUT.PUT_LINE('OC_TIME_SYNC_FAILED.JOB_RUN_ID is now nullable.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1451 THEN            -- already nullable
    DBMS_OUTPUT.PUT_LINE('JOB_RUN_ID already nullable - skipped.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [3/4] Append-only: an audit that can be edited is not one
PROMPT ============================================================

-- OC_TS_AUDIT and OC_TS_APPROVAL are the evidence trail for who approved what
-- and what was changed. Nothing prevented an UPDATE or a DELETE on either.
--
-- These are BEFORE statement-level triggers, so they refuse the operation
-- outright rather than logging it and letting it through. -20026 continues the
-- module's -20001..-20025 range; ORDS maps that band to 400 with the message
-- passed through, so a caller sees the reason rather than a 500.
DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(30);
  v t_tab := t_tab('OC_TS_AUDIT', 'OC_TS_APPROVAL');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    EXECUTE IMMEDIATE
      'CREATE OR REPLACE TRIGGER trg_' || LOWER(v(i)) || '_append_only ' ||
      'BEFORE UPDATE OR DELETE ON ' || v(i) || ' ' ||
      'BEGIN ' ||
      '  RAISE_APPLICATION_ERROR(-20026, ''' || v(i) ||
      ' is append-only. A correction is a NEW row, never an edit to an '     ||
      'existing one -- the point of the trail is that it cannot be rewritten.''); ' ||
      'END;';
    DBMS_OUTPUT.PUT_LINE('append-only trigger on ' || v(i));
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [4/4] The two genuine WHO gaps
PROMPT ============================================================

-- Audited 10-Aug-2026: 15 of 25 tables carry the full CREATED_BY/CREATED_ON/
-- UPDATED_BY/UPDATED_ON set. Most of the rest are EVENT tables where the row is
-- the event and the actor is already named -- OC_TS_APPROVAL has ACTOR_EMP_ID
-- and ACTION_ON, OC_TS_ADJUSTMENT has APPLIED_BY/ON, OC_TIME_SYNC_JOB has
-- TRIGGERED_BY. Adding generic columns there would duplicate what is recorded.
--
-- These two are different: both are mutable and neither says who touched them.
DECLARE
  TYPE t_col IS RECORD (tab VARCHAR2(40), spec VARCHAR2(120));
  TYPE t_tab IS TABLE OF t_col;
  v t_tab := t_tab(
    -- PROCESSED_FLAG / PULLED_ON / BATCH_ID are updated by the CONSUMER, and
    -- nothing recorded which consumer or when it claimed the row.
    t_col('XX_O2C_TIMESHEET_ACCRUAL_IF',
          'UPDATED_BY VARCHAR2(100 CHAR), UPDATED_ON TIMESTAMP'),
    -- A session row is created for a person at sign-in; without CREATED_BY
    -- there is no record of which path issued the token.
    t_col('OC_TIME_SESSION', 'CREATED_BY VARCHAR2(100 CHAR)'));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE ' || v(i).tab || ' ADD (' || v(i).spec || ')';
      DBMS_OUTPUT.PUT_LINE('added to ' || v(i).tab || ': ' || v(i).spec);
    EXCEPTION WHEN OTHERS THEN
      IF SQLCODE = -1430 THEN
        DBMS_OUTPUT.PUT_LINE(v(i).tab || ' already has them - skipped.');
      ELSE RAISE; END IF;
    END;
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT Views
PROMPT ============================================================

-- The queue, for whoever builds the generation step.
CREATE OR REPLACE VIEW v_oc_time_sync_change_queue AS
SELECT c.change_id, c.report_name, c.target_table, c.row_key, c.change_type,
       c.old_row, c.new_row, c.adjustment_status, c.created_on,
       cfg.run_order, cfg.purpose
  FROM oc_time_sync_change c
  LEFT JOIN oc_time_sync_config cfg ON cfg.bip_report_name = c.report_name
 WHERE c.adjustment_status = 'Pending'
 ORDER BY c.created_on, c.change_id;

-- Column-level, derived rather than stored. JSON_TABLE over the two documents
-- so "what actually differed" is a query, not a second write path that could
-- disagree with the first.
CREATE OR REPLACE VIEW v_oc_time_sync_change_col AS
SELECT c.change_id, c.report_name, c.target_table, c.row_key, c.change_type,
       n.col_name,
       o.old_val, n.new_val, c.adjustment_status, c.created_on
  FROM oc_time_sync_change c,
       JSON_TABLE(c.new_row, '$[*]'
         COLUMNS (col_name  VARCHAR2(128) PATH '$.name',
                  new_val   VARCHAR2(4000) PATH '$.value')) n,
       JSON_TABLE(c.old_row, '$[*]'
         COLUMNS (o_name    VARCHAR2(128)  PATH '$.name',
                  old_val   VARCHAR2(4000) PATH '$.value')) o
 WHERE o.o_name = n.col_name
   AND DECODE(o.old_val, n.new_val, 1, 0) = 0;

PROMPT
PROMPT Verification
PROMPT ============================================================

COLUMN object_name FORMAT A34
COLUMN object_type FORMAT A10
COLUMN status      FORMAT A8

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('OC_TIME_SYNC_CHANGE',
                       'V_OC_TIME_SYNC_CHANGE_QUEUE','V_OC_TIME_SYNC_CHANGE_COL',
                       'TRG_OC_TS_AUDIT_APPEND_ONLY','TRG_OC_TS_APPROVAL_APPEND_ONLY')
 ORDER BY object_type, object_name;

PROMPT
PROMPT Nothing drains the queue yet, by design. Every captured change stays
PROMPT Pending until the adjustment rules are settled -- an undrained queue is
PROMPT visible, a change that was never recorded is not.
