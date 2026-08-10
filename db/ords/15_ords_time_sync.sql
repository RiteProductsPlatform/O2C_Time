--==============================================================
-- time/ords/15_ords_time_sync.sql
-- O2C Timesheet Module — the REST surface OIC actually needs
--
-- OC_TIME_SYNC_CONFIG and OC_TIME_LOAD_XML both existed with NO WAY TO REACH
-- THEM. The design in 16_oic_sync_config.sql reads:
--
--   INT 001  schedule -> read this config -> for each row, call INT 002
--   INT 002  REST trigger -> run the BIP report -> hand (TARGET_TABLE, raw XML)
--                         to OC_TIME_LOAD_XML -> write LASTSYNC_DATE back
--
-- INT 001 had nothing to read the config from and INT 002 had nowhere to send
-- the XML. The per-entity sync/worker, sync/project handlers in module 13 are
-- the OLDER JSON path and key differently; they are not this.
--
-- A SEPARATE MODULE, not more templates on oc.time.admin. Every ORDS file here
-- opens with DELETE_MODULE and redefines its own module wholesale, so templates
-- added to oc.time.admin from this file would be silently erased the next time
-- 13 is run. Two files owning one module is a trap, not a saving.
--
-- Idempotent. Depends on: time/16
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/3] Module oc.time.sync
PROMPT ============================================================

BEGIN
  ORDS.DELETE_MODULE(p_module_name => 'oc.time.sync');
EXCEPTION WHEN OTHERS THEN NULL;   -- not defined yet
END;
/

BEGIN
  ORDS.DEFINE_MODULE(
    p_module_name    => 'oc.time.sync',
    p_base_path      => '/oc/time/sync/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'Master-data sync surface for OIC (INT 001 / INT 002).');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [2/3] GET config — what INT 001 loops over
PROMPT ============================================================

-- LASTSYNC_DATE IS EMITTED AS 'YYYY-MM-DD' TEXT, deliberately, and this is the
-- one thing in this file most likely to be "tidied" into a real date column.
--
-- It is fed straight into the BIP report's P_LAST_SYNC parameter, and the SQL
-- there is TO_DATE(:P_LAST_SYNC,'YYYY-MM-DD'). An ISO timestamp --
-- 2026-08-10T00:00:00.000Z, which is what a JSON date column normally becomes
-- -- raises ORA-01861, "literal does not match format string". Formatting here
-- means OIC maps the field through untouched and cannot get it wrong.
--
-- A feed that has never run comes back as JSON null, and that is correct --
-- but note the NVL below CANNOT produce an empty string, because in Oracle ''
-- IS NULL. Measured on the live endpoint: "lastsyncdate": null.
--
-- JSON null is fine and is what OIC should map: it arrives at BIP as an unset
-- parameter, BIP substitutes defaultValue="", and the report's
-- NVL(..., DATE '1900-01-01') turns that into a full load, which is right for a
-- feed that has never run. What must NEVER be emitted is the literal STRING
-- "null", which would reach TO_DATE and raise ORA-01861 on the first sync of
-- every feed. Quoting the column, or wrapping it in a JSON string function,
-- would do exactly that.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.sync', p_pattern => 'config');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.sync', p_pattern => 'config', p_method => 'GET',
    p_source_type => ORDS.source_type_collection_feed,
    p_source => q'~
      SELECT bip_report_name                          AS "reportName",
             bip_report_path                          AS "reportPath",
             target_table                             AS "targetTable",
             NVL(TO_CHAR(lastsync_date,'YYYY-MM-DD'), '') AS "lastSyncDate",
             -- P_EFFECTIVE_DATE, COMPUTED HERE RATHER THAN IN THE MAPPER.
             --
             -- The two schedules need different as-of dates and the difference
             -- is not cosmetic. O2C_Time_OIC_Build_Guide section 4: "Assign
             -- effectiveDate = the 1st of next month. Not today. The monthly
             -- run builds next month, so the HCM as-of date must be inside next
             -- month or you populate from THIS month's allocations." The BRD
             -- agrees -- the monthly program "populates hours for the next
             -- month based on the allocation for the next month".
             --
             -- Getting it wrong builds September from August's allocations and
             -- looks entirely normal, so it is not a mistake anyone catches by
             -- reading the output.
             --
             -- In the database because ADD_MONTHS handles the December -> January
             -- rollover and month lengths correctly, and hand-rolled date
             -- arithmetic in an OIC mapper is exactly where that breaks. OIC
             -- maps this field straight through to the parameter.
             CASE WHEN :scheduleTag = 'Monthly'
                  THEN TO_CHAR(ADD_MONTHS(TRUNC(SYSDATE,'MM'), 1), 'YYYY-MM-DD')
                  ELSE TO_CHAR(TRUNC(SYSDATE), 'YYYY-MM-DD')
             END                                      AS "effectiveDate",
             -- The period the monthly orchestrator then populates, so OIC does
             -- not have to work out which OC_TIME_PERIOD row "next month" is.
             -- Null on the daily run, which calls jobs/daily instead.
             CASE WHEN :scheduleTag = 'Monthly'
                  THEN (SELECT MAX(p.period_id) FROM oc_time_period p
                         WHERE p.start_date = ADD_MONTHS(TRUNC(SYSDATE,'MM'), 1))
             END                                      AS "targetPeriodId",
             sync_mode                                AS "syncMode",
             schedule_tag                             AS "scheduleTag",
             run_order                                AS "runOrder",
             sync_status                              AS "syncStatus",
             purpose                                  AS "purpose"
        FROM oc_time_sync_config
       WHERE enabled_flag = 'Y'
         -- Both schedules pick up the 'Both' rows. A missing tag returns the
         -- whole enabled set, which is the right default for a manual run.
         AND (:scheduleTag IS NULL
              OR schedule_tag = :scheduleTag
              OR schedule_tag = 'Both')
       ORDER BY run_order, bip_report_name
    ~');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [3/3] POST load/:reportName — where INT 002 sends the XML
PROMPT ============================================================

-- THE XML IS THE REQUEST BODY, not a field inside a JSON envelope.
--
-- A BIP extract is megabytes of XML. Putting it in a JSON string means every
-- quote and newline escaped by OIC and unescaped here, for no gain, and JSON
-- string binds are size-capped in ways the raw body is not. Posting the report
-- output verbatim as application/xml means OIC forwards what BIP returned
-- without touching it -- fewer places for it to be corrupted, and nothing to
-- get wrong in a mapper.
--
-- TARGET_TABLE is looked up from the config by report name rather than accepted
-- from the caller. The loader validates the table against the config anyway and
-- refuses anything else -- it builds dynamic SQL, so an unchecked table name is
-- an injection point -- but not accepting it at all is simpler and leaves the
-- config the single source of truth.
BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.sync',
                       p_pattern     => 'load/:reportName');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.sync', p_pattern => 'load/:reportName',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
DECLARE
  v_tab     VARCHAR2(30);
  v_clob    CLOB;
  v_read    NUMBER;
  v_merged  NUMBER;
  v_status  VARCHAR2(20);
  v_msg     VARCHAR2(2000);
BEGIN
  OWA_UTIL.MIME_HEADER('application/json', FALSE);
  OWA_UTIL.HTTP_HEADER_CLOSE;

  SELECT MAX(target_table) INTO v_tab
    FROM oc_time_sync_config
   WHERE bip_report_name = :reportName AND enabled_flag = 'Y';

  IF v_tab IS NULL THEN
    -- Not 500. An unknown or disabled report is the caller naming something
    -- wrong, and it must be distinguishable from the load itself failing.
    :status_code := 404;
    HTP.P('{"status":"Failed","message":"No enabled config row for report '
       || REPLACE(:reportName, '"', '') || '. Check OC_TIME_SYNC_CONFIG."}');
    RETURN;
  END IF;

  -- :body_text, NOT :body.
  --
  -- Measured against the live SIT endpoint 11-Aug-2026: :body arrives EMPTY for
  -- this handler under every content type tried -- application/xml, text/xml,
  -- text/plain, application/octet-stream. The load reported "The report
  -- returned no XML at all" and a 422 each time, which reads like the caller
  -- sent nothing, so the fault looks like OIC's rather than the handler's.
  --
  -- :body_text is ORDS's CLOB bind for a text payload and it is the right one
  -- here anyway: BIP returns XML, XML is text, and going through a BLOB meant a
  -- DBMS_LOB.CONVERTTOCLOB and a character-set decision that nothing needed.
  -- The conversion is gone with it.
  v_clob := :body_text;

  oc_time_load_xml(
    p_table_name  => v_tab,
    p_xml         => v_clob,
    p_report_name => :reportName,
    p_actor       => 'OIC',
    o_rows_read   => v_read,
    o_rows_merged => v_merged,
    o_status      => v_status,
    o_message     => v_msg);

  -- 200 on Success, 422 otherwise. A load that read the XML and refused it is
  -- not a server error, and OIC must be able to tell "retry this" from "this
  -- will never work" without parsing prose.
  :status_code := CASE WHEN v_status = 'Success' THEN 200 ELSE 422 END;

  HTP.P('{"reportName":"'  || :reportName            || '"'
     || ',"targetTable":"' || v_tab                  || '"'
     || ',"status":"'      || v_status               || '"'
     || ',"rowsRead":'     || NVL(v_read, 0)
     || ',"rowsMerged":'   || NVL(v_merged, 0)
     || ',"message":"'     || REPLACE(REPLACE(NVL(v_msg, ''), '\', '\\'), '"', '\"')
     || '"}');

EXCEPTION
  WHEN OTHERS THEN
    -- SQLERRM into a local first: it cannot be referenced inside a SQL
    -- statement, and the concatenation below is close enough to one that this
    -- has already cost time elsewhere in this schema.
    DECLARE
      v_err VARCHAR2(500) := SUBSTR(SQLERRM, 1, 400);
    BEGIN
      :status_code := 500;
      HTP.P('{"status":"Failed","message":"'
         || REPLACE(REPLACE(v_err, '\', '\\'), '"', '\"') || '"}');
    END;
END;
    ~');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT Verification
PROMPT ============================================================

COLUMN name    FORMAT A16
COLUMN pattern FORMAT A22
COLUMN method  FORMAT A8

SELECT m.name, t.uri_template AS pattern, h.method
  FROM user_ords_modules m
  JOIN user_ords_templates t ON t.module_id = m.id
  JOIN user_ords_handlers  h ON h.template_id = t.id
 WHERE m.name = 'oc.time.sync'
 ORDER BY t.uri_template, h.method;

PROMPT
PROMPT Expect two rows: GET config, POST load/:reportName.
PROMPT
PROMPT   GET  .../oc/time/sync/config?scheduleTag=Daily
PROMPT   POST .../oc/time/sync/load/WORKERS      body = the BIP XML, as-is
PROMPT
PROMPT KEY NAMES ARE LOWERCASE. Measured on the live endpoint 11-Aug-2026:
PROMPT ORDS returns reportname / reportpath / targettable / lastsyncdate /
PROMPT effectivedate / targetperiodid -- NOT the camelCase in the SELECT above.
PROMPT A mapper written against lastSyncDate resolves to nothing, silently.
PROMPT
PROMPT INT 002 passes BOTH BIP parameters, and both come from this response:
PROMPT
PROMPT   P_LAST_SYNC      <- lastsyncdate    (JSON null on a feed that never ran)
PROMPT   P_EFFECTIVE_DATE <- effectivedate   (1st of next month on Monthly,
PROMPT                                        today on Daily)
PROMPT
PROMPT Do NOT feed lastSyncDate into P_EFFECTIVE_DATE. They answer different
PROMPT questions -- "what changed since" versus "as of when" -- and sharing a
PROMPT value reads the workforce as it stood at the last sync: stale attributes
PROMPT and anyone hired since simply missing.
PROMPT
PROMPT Monthly also gets targetPeriodId, for
PROMPT   POST /oc/time/admin/jobs/populate/{targetPeriodId}   (empty body)
PROMPT A NULL targetPeriodId means next month has no OC_TIME_PERIOD row yet --
PROMPT create the period before the monthly run, or it has nothing to build.
