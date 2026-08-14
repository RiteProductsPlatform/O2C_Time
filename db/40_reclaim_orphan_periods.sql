--==============================================================
-- time/40_reclaim_orphan_periods.sql
-- O2C Timesheet Module — reattach rows whose period was renumbered upstream
--
-- WHAT HAPPENED
--   1,295 weeks point at period ids that no longer exist:
--
--     period_id  covering            weeks  resolves to
--     21         03-08-26..31-08-26    670  *** nothing ***     <- ALL OF AUGUST
--     42         01-06-26..30-06-26    625  *** nothing ***     <- ALL OF JUNE
--     43         JUL-2026              670  JUL-2026            ok
--     44         SEP-2026              670  SEP-2026            ok
--
--   The migration captured 42/43/21/44/45 from o2c_dev.oc_mec_period. Two of
--   those five have since been re-issued upstream under different ids, so the
--   rows keyed to them became unreachable -- not deleted, not wrong, just
--   invisible to every query that joins OC_TIME_PERIOD.
--
--   August is the whole point. It is the only Open period, and its 670 weeks
--   were sitting right there the entire time. "August has no weeks, wait for
--   the monthly OIC run" was the wrong conclusion -- the weeks existed and the
--   join was failing. A LEFT JOIN found in one query what an INNER JOIN had
--   been hiding through three scripts.
--
-- WHY IT WILL HAPPEN AGAIN, AND WHAT THAT MEANS
--   PERIOD_ID is the main application's number, and we adopted it as our own
--   foreign key. So they can renumber a month for their own reasons and every
--   OC_TS_* row keyed to it is orphaned here, silently, with no error raised
--   anywhere on either side.
--
--   That is the real cost of reading periods live, and it is worth stating
--   plainly rather than patching quietly: the direct-select decision was the
--   right one -- period control genuinely belongs to them -- but the key has
--   to be something they do not renumber. START_DATE is that thing. A month
--   is identified by when it starts, upstream and here, and that never moves.
--
--   This script therefore does NOT hand-patch two ids. It remaps by DATE, so
--   re-running it heals whatever they renumber next, and step [4] makes it
--   part of the daily process so nobody has to notice first.
--
-- Idempotent -- remaps only what is currently orphaned. Depends on: time/36
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
PROMPT [1/5] OC_TS_PERIOD_REMAP — keep the evidence
PROMPT ============================================================

-- A permanent record of every renumber, because the alternative is that ids
-- change, rows silently move, and six months later nobody can explain why a
-- July week is attached to period 43 in one export and 61 in another.
DECLARE
BEGIN
  EXECUTE IMMEDIATE q'~
    CREATE TABLE oc_ts_period_remap (
      REMAP_ID     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      OLD_PERIOD_ID NUMBER NOT NULL,
      NEW_PERIOD_ID NUMBER NOT NULL,
      PERIOD_NAME   VARCHAR2(30 CHAR),
      START_DATE    DATE,
      ROWS_MOVED    NUMBER,
      DETAIL        VARCHAR2(500 CHAR),
      REMAPPED_BY   VARCHAR2(100 CHAR) DEFAULT USER NOT NULL,
      REMAPPED_ON   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
    )~';
  DBMS_OUTPUT.PUT_LINE('OC_TS_PERIOD_REMAP created');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN DBMS_OUTPUT.PUT_LINE('OC_TS_PERIOD_REMAP exists, skipped');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [2/5] OC_TIME_REMAP_PERIODS — remap by date, not by id
PROMPT ============================================================

CREATE OR REPLACE PROCEDURE oc_time_remap_periods(
  p_actor  IN VARCHAR2 DEFAULT 'REMAP',
  p_report IN BOOLEAN  DEFAULT TRUE)
IS
  -- Declared BEFORE the nested procedure below. PL/SQL requires every
  -- declaration to precede the first nested subprogram BODY -- putting a
  -- variable after one is PLS-00103, and the message points at the variable
  -- rather than at the ordering. Already recorded in CLAUDE.md section 5, and
  -- hit again while writing the test block for this very script.
  v_total   NUMBER := 0;
  v_moved   NUMBER;
  v_left    NUMBER;

  PROCEDURE move(p_tab VARCHAR2, p_col VARCHAR2,
                 p_old NUMBER, p_new NUMBER, p_moved OUT NUMBER) IS
  BEGIN
    EXECUTE IMMEDIATE 'UPDATE ' || p_tab || ' SET ' || p_col || ' = :n'
                   || ' WHERE ' || p_col || ' = :o'
      USING p_new, p_old;
    p_moved := SQL%ROWCOUNT;
  EXCEPTION WHEN OTHERS THEN
    -- One table failing must not abandon the rest half-moved. Report and go
    -- on; step [3] shows anything still orphaned afterwards.
    DBMS_OUTPUT.PUT_LINE('    ' || RPAD(p_tab || '.' || p_col, 40)
                      || ' FAILED ' || SUBSTR(SQLERRM, 1, 80));
    p_moved := 0;
  END move;

BEGIN
  -- The mapping comes from the WEEKS, because a week carries the one fact
  -- that survives a renumber: the dates it covers. Match those to whichever
  -- period now spans them and the correct id falls out, whatever it is.
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

    -- Every table that carries the number, found from the dictionary rather
    -- than listed by hand -- a list would go stale the first time a table is
    -- added, and the failure mode is silent orphaning again.
    FOR t IN (
      SELECT c.table_name, c.column_name
        FROM user_tab_columns c
        JOIN user_tables u ON u.table_name = c.table_name
       WHERE c.column_name IN ('PERIOD_ID','SOURCE_PERIOD_ID','POST_PERIOD_ID')
         AND c.table_name LIKE 'OC%'
         AND c.table_name NOT IN ('OC_TIME_PERIOD_BASE','OC_TS_PERIOD_REMAP')
       ORDER BY c.table_name, c.column_name
    ) LOOP
      move(t.table_name, t.column_name, m.old_id, m.new_id, v_moved);
      IF v_moved > 0 THEN
        DBMS_OUTPUT.PUT_LINE('    ' || RPAD(t.table_name || '.' || t.column_name, 40)
                          || TO_CHAR(v_moved, '999999') || ' row(s)');
        v_total := v_total + v_moved;
      END IF;
    END LOOP;

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
    IF v_left > 0 THEN
      -- Left deliberately, not swept up. A week whose dates match no period at
      -- all is a different problem -- the period was deleted upstream rather
      -- than renumbered -- and guessing at it would destroy the evidence.
      DBMS_OUTPUT.PUT_LINE('  These cover dates no current period spans. '
                        || 'Do not guess -- ask which month they belong to.');
    END IF;
  END IF;
END;
/
SHOW ERRORS

BEGIN oc_time_remap_periods('MANUAL-14AUG'); END;
/

PROMPT ============================================================
PROMPT [3/5] Verification — nothing may be left unreachable
PROMPT ============================================================

COLUMN resolves_to FORMAT A24
SELECT NVL(TO_CHAR(w.period_id),'(null)') AS period_id,
       MIN(w.week_start) AS earliest, MAX(w.week_end) AS latest,
       COUNT(*) AS weeks,
       CASE WHEN p.period_id IS NULL THEN '*** no such period ***'
            ELSE p.period_name END AS resolves_to
  FROM oc_ts_week w
  LEFT JOIN oc_time_period p ON p.period_id = w.period_id
 GROUP BY w.period_id, p.period_id, p.period_name
 ORDER BY 1;

PROMPT
PROMPT Every row must resolve. AUG-2026 should now appear with its 670 weeks
PROMPT it is the only Open period, so it is the one that had to be reachable.

COLUMN period_name FORMAT A12
SELECT period_name, old_period_id, new_period_id, rows_moved,
       TO_CHAR(remapped_on,'DD-MON-YY HH24:MI') AS remapped_on
  FROM oc_ts_period_remap ORDER BY remap_id;

PROMPT ============================================================
PROMPT [4/5] Run it daily, so a renumber heals itself
PROMPT ============================================================

-- The failure this fixes is invisible: no error, no empty screen that looks
-- broken, just a month quietly missing. It was found by accident, and the
-- next one would be too. So it runs every day whether or not anything is
-- wrong -- the query costs nothing when there is nothing to remap.
CREATE OR REPLACE PROCEDURE oc_time_daily_period_health
IS
BEGIN
  oc_time_provision_mec_periods('DAILY_SYNC');   -- new months get a local anchor
  oc_time_remap_periods('DAILY_SYNC', FALSE);    -- renumbered months get reattached
EXCEPTION WHEN OTHERS THEN
  -- Never stop the sync over this. A period problem is bad; a sync that
  -- refuses to run because of one is worse.
  DBMS_OUTPUT.PUT_LINE('period health skipped: ' || SUBSTR(SQLERRM, 1, 120));
END;
/
SHOW ERRORS

PROMPT
PROMPT Call oc_time_daily_period_health at the start of the OIC daily run. It
PROMPT supersedes oc_time_daily_provision, which only handled NEW periods and
PROMPT would not have noticed a renumbered one.

PROMPT ============================================================
PROMPT [5/5] The longer-term fix, NOT done here
PROMPT ============================================================
PROMPT
PROMPT Remapping heals the symptom on a schedule. The cause is that our foreign
PROMPT keys hold a number the main application owns and can re-issue.
PROMPT
PROMPT The durable fix is to key on START_DATE, which identifies a month in both
PROMPT systems and never moves, and to keep PERIOD_ID as a lookup only. That is
PROMPT a change to eight tables and every join in the module, so it is a phase
PROMPT of its own -- not something to fold into the status engine.
PROMPT
PROMPT Until then the daily job is the guard, and OC_TS_PERIOD_REMAP is the
PROMPT record of how often this actually happens. If it fires more than once or
PROMPT twice, do the durable fix.
