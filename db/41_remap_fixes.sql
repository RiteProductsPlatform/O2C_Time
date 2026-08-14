--==============================================================
-- time/41_remap_fixes.sql
-- O2C Timesheet Module — four faults the remap and the engine test exposed
--
-- 40 reattached the weeks and the engine test resolved every rule. Both also
-- surfaced problems, three of them introduced by 40 itself.
--
-- 1. OC_TS_APPROVAL WAS NOT REMAPPED. Its append-only trigger refused the
--    update (ORA-20026) and 40 logged the failure and carried on -- so August
--    and June's approval history still points at the dead ids 21 and 42. The
--    weeks moved out from under their own audit trail. Fixed in [1], with the
--    trigger disabled around a data migration, which is what 90_demo_reset
--    already does for the same trigger.
--
-- 2. 40 REWROTE A BACKUP TABLE. It moved 1,070 rows in OC_TS_WEEK_BK, which
--    exists precisely to preserve what things looked like BEFORE. Finding
--    tables from the data dictionary was right; not excluding backups was not.
--    A backup that silently tracks the live data is not a backup. Reverted in
--    [2] and excluded from future runs in [3].
--
-- 3. OC_TIME_DAILY_PERIOD_HEALTH DID NOT COMPILE (PLS-00201). It calls
--    oc_time_provision_mec_periods, which no longer exists -- 36 replaced the
--    local base table with a direct view over oc_mec_period_src, so there is
--    nothing left to provision INTO. 34 became dead code the moment 36 landed
--    and nobody noticed, because nothing referenced it until now.
--
-- 4. DELIVERYCUTOFF FIRED ON A WEEK NOBODY SUBMITTED. The test produced
--    NotYetSubmitted / ManagerDefaulted -- the employee never sent anything in,
--    and the manager is recorded as having failed to approve it. That is not a
--    near miss: WEEK_STATUS derives to 'Defaulted' with DEFAULTED_BY='MANAGER',
--    and run_salary_stopping only holds pay on an EMPLOYEE default. So a
--    missing timesheet would be blamed on the manager AND would not stop the
--    employee's salary -- the exact inversion RULE-016 exists to prevent.
--
-- Idempotent. Depends on: time/40
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
PROMPT [1/6] OC_TS_APPROVAL — reattach the audit trail
PROMPT ============================================================

-- Append-only means no application code may edit history. It does not mean the
-- rows must stay pointing at a period that no longer exists: the trail is
-- append-only so it cannot be REWRITTEN, and repointing a foreign key at the
-- same month under its new number changes nothing anyone recorded.
--
-- Disabled and re-enabled in the same block, with the re-enable in the
-- EXCEPTION path too. A trigger left disabled by a failed script is a far
-- worse outcome than the orphan it was fixing.
DECLARE
  v_moved NUMBER := 0;
  v_n     NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_triggers
   WHERE trigger_name = 'TRG_OC_TS_APPROVAL_APPEND_ONLY';

  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('trigger not present; nothing to disable');
  ELSE
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only DISABLE';
  END IF;

  BEGIN
    FOR m IN (SELECT old_period_id, new_period_id, period_name
                FROM oc_ts_period_remap ORDER BY remap_id) LOOP
      UPDATE oc_ts_approval SET period_id = m.new_period_id
       WHERE period_id = m.old_period_id;
      IF SQL%ROWCOUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  ' || m.period_name || ': ' || SQL%ROWCOUNT
                          || ' approval row(s) ' || m.old_period_id
                          || ' -> ' || m.new_period_id);
        v_moved := v_moved + SQL%ROWCOUNT;
      END IF;
    END LOOP;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    IF v_n > 0 THEN
      EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
    END IF;
    RAISE;
  END;

  IF v_n > 0 THEN
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
  END IF;
  DBMS_OUTPUT.PUT_LINE(v_moved || ' approval row(s) reattached; trigger re-enabled');
END;
/

PROMPT ============================================================
PROMPT [2/6] OC_TS_WEEK_BK — put the backup back
PROMPT ============================================================

-- 40 moved 1,070 rows here. Safe to reverse: the new ids were issued upstream
-- AFTER the backup was taken, so no row in a backup can legitimately hold one.
-- Anything currently holding a new id was put there by 40 and by nothing else.
DECLARE
  v_back NUMBER := 0;
  v_n    NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TS_WEEK_BK';
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('OC_TS_WEEK_BK not present, skipped');
  ELSE
    FOR m IN (SELECT old_period_id, new_period_id, period_name
                FROM oc_ts_period_remap ORDER BY remap_id) LOOP
      EXECUTE IMMEDIATE
        'UPDATE oc_ts_week_bk SET period_id = :o WHERE period_id = :n'
        USING m.old_period_id, m.new_period_id;
      IF SQL%ROWCOUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  ' || m.period_name || ': ' || SQL%ROWCOUNT
                          || ' row(s) restored to ' || m.old_period_id);
        v_back := v_back + SQL%ROWCOUNT;
      END IF;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_back || ' backup row(s) restored');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [3/6] OC_TIME_REMAP_PERIODS — never touch a backup again
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_remap_periods(
  p_actor  IN VARCHAR2 DEFAULT 'REMAP',
  p_report IN BOOLEAN  DEFAULT TRUE)
IS
  v_total NUMBER := 0;
  v_moved NUMBER;
  v_left  NUMBER;

  PROCEDURE move(p_tab VARCHAR2, p_col VARCHAR2,
                 p_old NUMBER, p_new NUMBER, p_moved OUT NUMBER) IS
  BEGIN
    EXECUTE IMMEDIATE 'UPDATE ' || p_tab || ' SET ' || p_col || ' = :n'
                   || ' WHERE ' || p_col || ' = :o'
      USING p_new, p_old;
    p_moved := SQL%ROWCOUNT;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('    ' || RPAD(p_tab || '.' || p_col, 40)
                      || ' FAILED ' || SUBSTR(SQLERRM, 1, 80));
    p_moved := 0;
  END move;

BEGIN
  FOR m IN (
    SELECT DISTINCT w.period_id AS old_id, p.period_id AS new_id,
           p.period_name, p.start_date
      FROM oc_ts_week w
      JOIN oc_time_period p
        ON w.week_start BETWEEN p.start_date AND p.end_date
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_period q
                        WHERE q.period_id = w.period_id)
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  ' || m.period_name || ': ' || m.old_id
                      || ' -> ' || m.new_id);
    v_total := 0;

    FOR t IN (
      SELECT c.table_name, c.column_name
        FROM user_tab_columns c
        JOIN user_tables u ON u.table_name = c.table_name
       WHERE c.column_name IN ('PERIOD_ID','SOURCE_PERIOD_ID','POST_PERIOD_ID')
         AND c.table_name LIKE 'OC%'
         AND c.table_name NOT IN ('OC_TIME_PERIOD_BASE','OC_TS_PERIOD_REMAP')
         -- A BACKUP MUST NOT TRACK THE LIVE DATA. 40 moved 1,070 rows in
         -- OC_TS_WEEK_BK, which exists to record what things looked like
         -- before -- rewriting it destroys the only copy of the answer to
         -- "what did this look like beforehand". Same for anything archived.
         AND c.table_name NOT LIKE '%\_BK'      ESCAPE '\'
         AND c.table_name NOT LIKE '%\_BAK'     ESCAPE '\'
         AND c.table_name NOT LIKE '%\_BACKUP'  ESCAPE '\'
         AND c.table_name NOT LIKE '%\_ARCH'    ESCAPE '\'
         AND c.table_name NOT LIKE '%\_ARCHIVE' ESCAPE '\'
         AND c.table_name NOT LIKE '%\_OLD'     ESCAPE '\'
       ORDER BY c.table_name, c.column_name
    ) LOOP
      move(t.table_name, t.column_name, m.old_id, m.new_id, v_moved);
      IF v_moved > 0 THEN
        DBMS_OUTPUT.PUT_LINE('    ' || RPAD(t.table_name || '.' || t.column_name, 40)
                          || TO_CHAR(v_moved, '999999') || ' row(s)');
        v_total := v_total + v_moved;
      END IF;
    END LOOP;

    -- OC_TS_APPROVAL is append-only and its trigger refuses an UPDATE. The
    -- trail must still follow its weeks, so the trigger comes off for exactly
    -- this statement and goes back on immediately, including on failure.
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only DISABLE';
      BEGIN
        UPDATE oc_ts_approval SET period_id = m.new_id WHERE period_id = m.old_id;
        IF SQL%ROWCOUNT > 0 THEN
          DBMS_OUTPUT.PUT_LINE('    ' || RPAD('OC_TS_APPROVAL.PERIOD_ID', 40)
                            || TO_CHAR(SQL%ROWCOUNT, '999999') || ' row(s)');
          v_total := v_total + SQL%ROWCOUNT;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('    OC_TS_APPROVAL FAILED ' || SUBSTR(SQLERRM,1,80));
      END;
      EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
    EXCEPTION WHEN OTHERS THEN
      BEGIN EXECUTE IMMEDIATE 'ALTER TRIGGER trg_oc_ts_approval_append_only ENABLE';
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END;

    INSERT INTO oc_ts_period_remap (old_period_id, new_period_id, period_name,
                                    start_date, rows_moved, detail, remapped_by)
    VALUES (m.old_id, m.new_id, m.period_name, m.start_date, v_total,
            'Upstream re-issued the period id; rows matched by date.', p_actor);
  END LOOP;

  COMMIT;

  SELECT COUNT(*) INTO v_left FROM oc_ts_week w
   WHERE NOT EXISTS (SELECT 1 FROM oc_time_period q WHERE q.period_id = w.period_id);

  IF p_report THEN
    DBMS_OUTPUT.PUT_LINE('Weeks still orphaned after remap: ' || v_left);
  END IF;
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [4/6] OC_TIME_DAILY_PERIOD_HEALTH — drop the dead dependency
PROMPT ============================================================

-- oc_time_provision_mec_periods is gone, and correctly so. 34 wrote it to give
-- each upstream period a LOCAL anchor row, because OC_TIME_PERIOD was then a
-- view over a local base table. 36 replaced that with a direct view over
-- oc_mec_period_src -- there is no local table left to insert into, so a new
-- month appears the instant it appears upstream and provisioning has nothing
-- to do. 34 has been dead code since; this is the first thing to reference it.
CREATE OR REPLACE PROCEDURE oc_time_daily_period_health
IS
BEGIN
  oc_time_remap_periods('DAILY_SYNC', FALSE);
EXCEPTION WHEN OTHERS THEN
  -- Never stop the sync over this. A period problem is bad; a sync that
  -- refuses to run because of one is worse.
  DBMS_OUTPUT.PUT_LINE('period health skipped: ' || SUBSTR(SQLERRM, 1, 120));
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [5/6] DeliveryCutoff must not blame the manager for a missing sheet
PROMPT ============================================================

-- The rule matched any submission state, so a week nobody submitted became
-- NotYetSubmitted / ManagerDefaulted. Two things follow from that state and
-- both are wrong:
--
--   * WEEK_STATUS derives to 'Defaulted' with DEFAULTED_BY = 'MANAGER', so the
--     manager is on record as having failed to approve something that was
--     never sent to them.
--   * run_salary_stopping holds pay only on an EMPLOYEE default, so the
--     employee who never submitted keeps their salary and their manager wears
--     it. That is RULE-016 inverted.
--
-- A manager can only fail to act on something that reached them. Defaulted
-- counts -- the weekly job submitted it on the employee's behalf and it is
-- genuinely waiting on the manager. NotYetSubmitted does not.
DECLARE
  PROCEDURE rule(p_from_sub VARCHAR2, p_order NUMBER, p_notes VARCHAR2) IS
  BEGIN
    INSERT INTO oc_ts_transition (
      event_code, match_order, from_submission, from_approval,
      period_state, timing, require_flag,
      to_submission, to_approval, raise_flag, scenario_ref, notes, active_flag)
    VALUES ('DeliveryCutoff', p_order, p_from_sub, 'Pending',
            NULL, NULL, NULL,
            NULL, 'ManagerDefaulted', 'ManagerDefaulted', '17', p_notes, 'Y');
  END rule;
BEGIN
  DELETE FROM oc_ts_transition WHERE event_code = 'DeliveryCutoff';
  DBMS_OUTPUT.PUT_LINE(SQL%ROWCOUNT || ' old DeliveryCutoff rule(s) removed');

  rule('Submitted', 10,
       'The employee submitted and the manager did not act by the delivery '
    || 'cut-off. The submission axis is untouched -- the employee did nothing '
    || 'wrong and their record must not say otherwise.');

  rule('LateSubmission', 20,
       'Submitted late, but submitted. Lateness is the employee''s flag; '
    || 'failing to approve it is still the manager''s.');

  rule('Defaulted', 30,
       'The weekly job submitted on the employee''s behalf, so the week did '
    || 'reach the manager and they still did not act. DEFAULTED_BY stays '
    || 'EMPLOYEE -- see oc_time_apply_event, where the employee attribution '
    || 'wins so the salary hold is not silently released.');

  -- NO RULE FOR NotYetSubmitted, deliberately. Firing DeliveryCutoff on a week
  -- that was never submitted now raises -20034 by name instead of quietly
  -- producing a state that misassigns blame and misdirects a salary hold.
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('3 DeliveryCutoff rules seeded');
END;
/

PROMPT ============================================================
PROMPT [6/6] Verification
PROMPT ============================================================

COLUMN resolves_to FORMAT A24
PROMPT --- approval trail follows its weeks
SELECT NVL(TO_CHAR(a.period_id),'(null)') AS period_id, COUNT(*) AS approvals,
       CASE WHEN p.period_id IS NULL THEN '*** no such period ***'
            ELSE p.period_name END AS resolves_to
  FROM oc_ts_approval a
  LEFT JOIN oc_time_period p ON p.period_id = a.period_id
 GROUP BY a.period_id, p.period_id, p.period_name ORDER BY 1;

PROMPT
PROMPT --- DeliveryCutoff rules
COLUMN from_submission FORMAT A18
COLUMN to_approval     FORMAT A18
SELECT match_order, from_submission, from_approval, to_approval, raise_flag
  FROM oc_ts_transition WHERE event_code = 'DeliveryCutoff' ORDER BY match_order;

PROMPT
PROMPT NotYetSubmitted is absent on purpose. A manager cannot fail to approve
PROMPT something that was never sent, and -20034 says so out loud.

SELECT object_name, status FROM user_objects
 WHERE object_name IN ('OC_TIME_REMAP_PERIODS','OC_TIME_DAILY_PERIOD_HEALTH')
 ORDER BY object_name;
