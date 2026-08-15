--==============================================================
-- time/46_jobs_daily_post_load.sql
-- O2C Timesheet Module — POST jobs/daily does the whole daily job
--
-- OIC does not have a stored-procedure node to repoint. It loops
-- OC_TIME_SYNC_CONFIG calling the load endpoint per report, then posts to
-- jobs/daily -- it reaches this database only over ORDS. So the daily job is
-- defined by what that HANDLER runs, and that is the only thing to change.
--
-- The handler called oc_time_pkg.populate_daily directly. It now calls
-- oc_time_daily_post_load, which is period health -> expire allocations ->
-- populate -> leave sync, in that order. Nothing changes in OIC: same URL,
-- same body, same {"jobRunId":n} coming back.
--
-- SCOPED CALLS STILL BEHAVE AS THEY DID. A scopeKey means "just this scope",
-- and expiring every allocation in the schema or reconciling a whole month of
-- leave is not what a scoped caller asked for. Only an unscoped call -- which
-- is what OIC and the Sync Status page both send -- runs the full chain.
--
-- Uses q'~...~' rather than q'[...]'. The existing handler uses the bracket
-- form and gets away with it; anything containing a JSON path or a ]' would
-- terminate the literal early, and CLAUDE.md section 5 records seven handlers
-- broken exactly that way.
--
-- Idempotent. Depends on: time/45
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/2] POST jobs/daily
PROMPT ============================================================

BEGIN
  ORDS.DEFINE_TEMPLATE(p_module_name => 'oc.time.admin', p_pattern => 'jobs/daily');
  ORDS.DEFINE_HANDLER(
    p_module_name => 'oc.time.admin', p_pattern => 'jobs/daily', p_method => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source => q'~
      DECLARE
        v_job NUMBER;
        v_sum VARCHAR2(4000);
      BEGIN
        IF :scopeKey IS NULL THEN
          -- The full daily job. Both real callers land here: OIC after the
          -- config-driven load loop, and the Sync Status page's Run button,
          -- which sends scopeKey null.
          oc_time_daily_post_load(
            NVL(TO_DATE(:actionDate,'YYYY-MM-DD'), TRUNC(SYSDATE)),
            NVL(:actor,'VBCS_USER'), v_sum, v_job);
        ELSE
          -- Scoped: populate only, exactly as before. Expiring every
          -- allocation in the schema off the back of a request about one
          -- scope would be a side effect nobody asked for.
          v_job := oc_time_pkg.populate_daily(
                     NVL(TO_DATE(:actionDate,'YYYY-MM-DD'), TRUNC(SYSDATE)),
                     :scopeKey, NVL(:actor,'VBCS_USER'));
          v_sum := 'Scoped populate only (scopeKey=' || :scopeKey || ')';
        END IF;

        :status_code := 200;
        -- jobRunId stays first and stays named the same: OIC and the page
        -- both read it, and a post-load step is no reason to break them.
        HTP.P('{"jobRunId":' || NVL(v_job, 0)
           || ',"summary":"' || REPLACE(NVL(v_sum,' '), '"', '\"') || '"}');
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        :status_code := CASE WHEN SQLCODE BETWEEN -20033 AND -20001
                             THEN 400 ELSE 500 END;
        HTP.P('{"error":"' || REPLACE(SQLERRM,'"','\"') || '"}');
      END;
    ~');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('POST jobs/daily now runs the full post-load chain');
END;
/

PROMPT ============================================================
PROMPT [2/2] Verification
PROMPT ============================================================

COLUMN uri_template FORMAT A24
COLUMN method       FORMAT A8
SELECT t.uri_template, h.method,
       CASE WHEN DBMS_LOB.INSTR(h.source, 'oc_time_daily_post_load') > 0
            THEN 'post-load chain' ELSE 'populate only' END AS runs
  FROM user_ords_templates t
  JOIN user_ords_handlers  h ON h.template_id = t.id
 WHERE t.uri_template IN ('jobs/daily','jobs/populate/:periodId')
 ORDER BY t.uri_template, h.method;

PROMPT
PROMPT jobs/daily must read 'post-load chain'. jobs/populate/:periodId is the
PROMPT MONTHLY job and is deliberately untouched -- it builds a whole future
PROMPT month from current allocation, where retracting leave against dates that
PROMPT have not happened yet would mean nothing.

PROMPT
PROMPT --- call it the way OIC does
DECLARE
  v_sum VARCHAR2(4000);
  v_job NUMBER;
BEGIN
  oc_time_daily_post_load(TRUNC(SYSDATE), 'VERIFY-46', v_sum, v_job);
  DBMS_OUTPUT.PUT_LINE('jobRunId ' || NVL(v_job,0));
  DBMS_OUTPUT.PUT_LINE(v_sum);
END;
/

PROMPT
PROMPT ============================================================
PROMPT NOTHING TO DO IN OIC
PROMPT ============================================================
PROMPT
PROMPT No node to add, no config row, no schedule change. The daily flow keeps
PROMPT looping OC_TIME_SYNC_CONFIG and keeps posting to jobs/daily; the
PROMPT endpoint simply does more than it did.
PROMPT
PROMPT Worth watching on the first real run: the response now carries a
PROMPT "summary" alongside jobRunId, and on failure it names the step that
PROMPT broke rather than only the ORA number.
