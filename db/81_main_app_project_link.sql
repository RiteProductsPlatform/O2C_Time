--==============================================================
-- time/81_main_app_project_link.sql
-- O2C Timesheet Module — where the revenue model comes from
--
-- REVENUE_MODEL has been NULL on every synced project since the module was
-- built, and it is not cosmetic: V_OC_TS_LLC selects on
-- revenue_model = 'FCP' AND leave_loss_flag = 'Y', so leave-loss coverage
-- (PROC-006 / RULE-014) has never had a project to fire on. Fusion PPM does
-- not carry the commercial model -- it is a contract fact, and it lives in the
-- main O2C application, one level down from the project:
--
--     oc_project ──< oc_rate_card.REVENUE_MODEL
--
-- Same database, different schema, so this reads O2C_DEV directly through a
-- synonym rather than over REST. The pattern is db/30's, including the
-- reachability probe that prints the grant it needs instead of failing with
-- ORA-00942 and leaving somebody to work out why.
--
-- THE JOIN IS BY NAME, AND THAT IS THE WEAK PART. Project numbers do not
-- match and were never going to: ours are Fusion's (444, 555, PCS10034),
-- theirs are the main app's own (PRJ-2026-32, -33, -34). What matches is
-- PROJECT_NAME, because the projects were created on both sides with the same
-- name on purpose. Rename either side and the link breaks silently.
--
-- So the name is used ONCE. MAIN_PROJECT_ID is stamped on the first match and
-- every later run reads that instead -- the column has existed since
-- 02_time_master.sql:440 with no populator, and this is it. It is also what
-- the accrual and OTL pushes need, and the reason they cannot be built yet.
--
-- THE TRANSLATION IS LOAD-BEARING, not tidying:
--
--     main app        here      why it matters
--     Labor / T&M     T&M
--     Capacity        FCP       <-- leave-loss gates on 'FCP'
--     Milestone       Milestone
--     Volume          Volume    no local meaning yet; carried through as-is
--
-- Copy 'Capacity' across verbatim and leave-loss stays silently switched off
-- while every screen shows a revenue model that looks right. Same shape as the
-- Billable/Unbilled mismatch already recorded against the allocation loader:
-- two vocabularies for one idea, and the wrong one fails quietly.
--
-- 555 is the Capacity project on this pod, so it is the one FCP project and
-- the only place leave-loss coverage will ever be testable.
--
-- WHICH RATE CARD. A project can hold several -- Draft, PendingL1, PendingL2,
-- Approved, Rejected, Cancelled, Superseded, across versions. Only Approved is
-- a commercial fact; the rest are somebody's work in progress. Highest
-- VERSION_NO among the Approved ones, and if a project has none, REVENUE_MODEL
-- is left alone rather than guessed at.
--
-- Idempotent. Depends on: time/02.
-- Needs, as O2C_DEV:  GRANT SELECT ON oc_project   TO o2c_time;
--                     GRANT SELECT ON oc_rate_card TO o2c_time;
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tab_columns
   WHERE table_name = 'OC_TIME_PROJECT' AND column_name = 'MAIN_PROJECT_ID';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      || ', where OC_TIME_PROJECT.MAIN_PROJECT_ID does not exist.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/5] Can we see the main application at all
PROMPT ============================================================

-- Named synonyms rather than schema-qualified references throughout, so the
-- grant is checked once here instead of failing halfway through a later
-- statement with ORA-00942 and no indication of which object.
DECLARE
  FUNCTION reachable(p_obj VARCHAR2) RETURN BOOLEAN IS
    v_x NUMBER;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (SELECT 1 FROM ' || p_obj
                   || ' WHERE ROWNUM = 1)' INTO v_x;
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
  END;

  PROCEDURE syn(p_name VARCHAR2, p_for VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE SYNONYM ' || p_name || ' FOR ' || p_for;
    DBMS_OUTPUT.PUT_LINE('  synonym ' || p_name || ' -> ' || p_for);
  END;
BEGIN
  IF reachable('o2c_dev.oc_project') AND reachable('o2c_dev.oc_rate_card') THEN
    syn('oc_main_project_src',   'o2c_dev.oc_project');
    syn('oc_main_ratecard_src',  'o2c_dev.oc_rate_card');
    DBMS_OUTPUT.PUT_LINE('  Main application is readable.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  CANNOT READ THE MAIN APPLICATION. Run these as O2C_DEV');
    DBMS_OUTPUT.PUT_LINE('  and then re-run this script:');
    DBMS_OUTPUT.PUT_LINE('    GRANT SELECT ON oc_project   TO o2c_time;');
    DBMS_OUTPUT.PUT_LINE('    GRANT SELECT ON oc_rate_card TO o2c_time;');
    RAISE_APPLICATION_ERROR(-20098,
      'o2c_dev.oc_project / oc_rate_card are not readable from '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || '. Nothing was changed.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [2/5] What matches, before anything is written
PROMPT ============================================================

COLUMN ours FORMAT A34
COLUMN theirs FORMAT A34
COLUMN model FORMAT A14
SELECT t.project_number || '  ' || t.project_name        AS ours,
       NVL(m.project_number || '  ' || m.project_name,
           '(no match on name)')                          AS theirs,
       NVL(rc.revenue_model, '(no approved card)')        AS model,
       NVL(rc.status,'-')                                 AS card_status,
       NVL(TO_CHAR(rc.version_no),'-')                    AS ver
  FROM oc_time_project t
  LEFT JOIN oc_main_project_src m
         ON UPPER(TRIM(m.project_name)) = UPPER(TRIM(t.project_name))
  LEFT JOIN (SELECT r.project_id, r.revenue_model, r.status, r.version_no,
                    ROW_NUMBER() OVER (PARTITION BY r.project_id
                                       ORDER BY r.version_no DESC) AS rn
               FROM oc_main_ratecard_src r
              WHERE r.status = 'Approved') rc
         ON rc.project_id = m.project_id AND rc.rn = 1
 WHERE t.status = 'Active'
   AND EXISTS (SELECT 1 FROM oc_time_allocation al
                WHERE al.project_id = t.project_id AND al.status = 'Active')
 ORDER BY t.project_number;

PROMPT
PROMPT Only projects somebody is allocated to are listed - the other 40-odd
PROMPT carry no time and would be noise. "(no match on name)" means the two
PROMPT names differ; fix the name on one side rather than the join.

PROMPT ============================================================
PROMPT [3/5] Stamp MAIN_PROJECT_ID
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  UPDATE oc_time_project t
     SET t.main_project_id =
           (SELECT MIN(m.project_id) FROM oc_main_project_src m
             WHERE UPPER(TRIM(m.project_name)) = UPPER(TRIM(t.project_name))),
         t.updated_by = 'MAIN_LINK_81',
         t.updated_on = SYSTIMESTAMP
   WHERE t.main_project_id IS NULL
     -- MIN() rather than a bare scalar subquery: two main-app projects sharing
     -- a name would raise TOO_MANY_ROWS and strand the whole statement. The
     -- ambiguity is reported below rather than allowed to stop the run.
     AND EXISTS (SELECT 1 FROM oc_main_project_src m
                  WHERE UPPER(TRIM(m.project_name)) = UPPER(TRIM(t.project_name)));
  v_n := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('  ' || v_n || ' project(s) linked to the main application.');
END;
/

-- Ambiguity is worth seeing even when it changed nothing: two projects with
-- one name means the next rename picks the wrong one.
SELECT UPPER(TRIM(project_name)) AS shared_name, COUNT(*) AS main_app_rows
  FROM oc_main_project_src
 GROUP BY UPPER(TRIM(project_name))
HAVING COUNT(*) > 1;

PROMPT
PROMPT No rows above means every name is unique in the main application.

PROMPT ============================================================
PROMPT [4/5] Revenue model and the leave-loss flag
PROMPT ============================================================

DECLARE
  v_m NUMBER; v_l NUMBER;
BEGIN
  UPDATE oc_time_project t
     SET t.revenue_model =
           (SELECT CASE rc.revenue_model
                     WHEN 'Labor / T&M' THEN 'T&M'
                     WHEN 'Capacity'    THEN 'FCP'
                     ELSE rc.revenue_model
                   END
              FROM (SELECT r.project_id, r.revenue_model,
                           ROW_NUMBER() OVER (PARTITION BY r.project_id
                                              ORDER BY r.version_no DESC) AS rn
                      FROM oc_main_ratecard_src r
                     WHERE r.status = 'Approved') rc
             WHERE rc.project_id = t.main_project_id AND rc.rn = 1),
         t.updated_by = 'MAIN_LINK_81',
         t.updated_on = SYSTIMESTAMP
   WHERE t.main_project_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM oc_main_ratecard_src r
                  WHERE r.project_id = t.main_project_id
                    AND r.status = 'Approved');
  v_m := SQL%ROWCOUNT;

  -- LEAVE_LOSS_FLAG follows the model, and only FCP can carry it. Set rather
  -- than merely defaulted, because a project that stops being Capacity must
  -- stop being subject to leave-loss too -- otherwise the flag outlives the
  -- reason for it and PROC-006 keeps running on a T&M project.
  UPDATE oc_time_project t
     SET t.leave_loss_flag = CASE WHEN t.revenue_model = 'FCP' THEN 'Y' ELSE 'N' END,
         t.updated_by = 'MAIN_LINK_81',
         t.updated_on = SYSTIMESTAMP
   WHERE t.main_project_id IS NOT NULL
     AND t.leave_loss_flag <> CASE WHEN t.revenue_model = 'FCP' THEN 'Y' ELSE 'N' END;
  v_l := SQL%ROWCOUNT;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('  ' || v_m || ' revenue model(s) set, '
                    || v_l || ' leave-loss flag(s) changed.');
END;
/

PROMPT ============================================================
PROMPT [5/5] Verification
PROMPT ============================================================

COLUMN project_number FORMAT A12
COLUMN project_name FORMAT A32
COLUMN revenue_model FORMAT A12
SELECT t.project_number, t.project_name,
       NVL(TO_CHAR(t.main_project_id),'(unlinked)') AS main_id,
       NVL(t.revenue_model,'(none)')                AS revenue_model,
       t.leave_loss_flag
  FROM oc_time_project t
 WHERE t.status = 'Active'
   AND EXISTS (SELECT 1 FROM oc_time_allocation al
                WHERE al.project_id = t.project_id AND al.status = 'Active')
 ORDER BY t.project_number;

PROMPT
PROMPT 444 should read T&M, 555 FCP with leave-loss Y, PCS10034 Milestone.
PROMPT 555 being the only FCP is expected - it is the one Capacity project, and
PROMPT therefore the only one leave-loss coverage can be tested against.

SELECT COUNT(*) AS fcp_projects_now_eligible
  FROM oc_time_project
 WHERE status = 'Active' AND revenue_model = 'FCP' AND leave_loss_flag = 'Y';

PROMPT
PROMPT V_OC_TS_LLC selects exactly this set. It has always returned nothing
PROMPT because REVENUE_MODEL was NULL everywhere; a non-zero count here is what
PROMPT makes PROC-006 reachable for the first time.
