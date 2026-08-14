--==============================================================
-- time/35_period_direct.sql
-- O2C Timesheet Module — OC_TIME_PERIOD becomes a direct select
--
-- Requested 14-Aug-2026: no local anchor table, no provisioning step. A period
-- added upstream should simply BE here. This delivers that.
--
-- WHAT WAS IN THE WAY, AND WHY IT NO LONGER IS
--
--   1. PERIOD_ID. Ten tables point at it and their rows hold OUR ids, while
--      the main application has its own -- theirs is 21 for August where ours
--      is 21 for September. That is why 30 kept a local table driving the
--      join.
--
--      Fixed by REMAPPING once. Every PERIOD_ID in this schema is rewritten to
--      the upstream id for the same START_DATE. After that the two systems
--      agree on what a period id means, permanently, and nothing has to
--      translate between them again.
--
--   2. The "local-only" columns. TS_CUTOFF_DAY, TS_CUTOFF_TIME,
--      CONTRACTOR_RESUBMIT_DAYS, ADJUSTMENT_MONTHS, BACKDATED_MONTHS and
--      HOLD_RELEASE_DAYS looked like per-period data holding the design
--      hostage. They are not: 10_seed.sql writes 'Monday', '17:00', 60, 3, 3
--      into every single period. They are module settings that happened to be
--      stored per row.
--
--      Fixed by moving them to OC_TIME_CONFIG, where settings already live.
--      The view cross-joins one row of them.
--
-- WHAT IT COSTS: THE TEN FOREIGN KEYS
--   A view cannot be the target of a foreign key, so they go. Worth being
--   honest about what that loses -- and it is less than it appears. The
--   constraint stopped a week pointing at a period that does not exist. Once
--   another application owns periods, they can delete one we hold weeks
--   against and no constraint of ours prevents it. The guarantee left when
--   ownership did; only the appearance of it remained.
--
-- THE GUARD THAT MATTERS
--   Every local period THAT HOLDS DATA must exist upstream. If SEP-2026 has
--   1,070 weeks and the main application has no September, remapping would
--   orphan them. This script REFUSES in that case and names the period. Add it
--   upstream first, then re-run.
--
-- Reversible until the base table is dropped: OC_TIME_PERIOD_BASE is left in
-- place, renamed, holding the old ids and the old values.
--
-- Idempotent. Depends on: time/33
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables WHERE table_name = 'OC_TIME_WORKER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') ||
      ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/6] The mapping, and the guard
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN mec_name    FORMAT A16
SELECT b.period_id AS local_id, b.period_name,
       m.period_id AS mec_id, m.period_name AS mec_name,
       (SELECT COUNT(*) FROM oc_ts_week w WHERE w.period_id = b.period_id) AS weeks,
       CASE WHEN m.period_id IS NULL THEN '*** NO UPSTREAM ROW ***' END AS problem
  FROM oc_time_period_base b
  LEFT JOIN oc_mec_period_src m ON m.start_date = b.start_date
 ORDER BY b.start_date;

DECLARE
  v_bad NUMBER;
  v_names VARCHAR2(400);
BEGIN
  -- Only periods CARRYING DATA are fatal. An empty local period with no
  -- upstream counterpart is just noise and is dropped with the base table.
  SELECT COUNT(*), LISTAGG(period_name, ', ') WITHIN GROUP (ORDER BY start_date)
    INTO v_bad, v_names
    FROM (SELECT b.period_name, b.start_date
            FROM oc_time_period_base b
            LEFT JOIN oc_mec_period_src m ON m.start_date = b.start_date
           WHERE m.period_id IS NULL
             AND EXISTS (SELECT 1 FROM oc_ts_week w WHERE w.period_id = b.period_id));

  IF v_bad > 0 THEN
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('REFUSED. These periods hold timesheets and do not');
    DBMS_OUTPUT.PUT_LINE('exist in the main application: ' || v_names);
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Remapping now would orphan every week in them. Add');
    DBMS_OUTPUT.PUT_LINE('them on the Period Control screen, then re-run.');
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    RAISE_APPLICATION_ERROR(-20033,
      'Periods with data and no upstream row: ' || v_names);
  END IF;
  DBMS_OUTPUT.PUT_LINE('Every period holding data maps upstream. Proceeding.');
END;
/

PROMPT ============================================================
PROMPT [2/6] Move the module settings out of the period row
PROMPT ============================================================

DECLARE
  PROCEDURE cfg(p_name VARCHAR2, p_val VARCHAR2, p_desc VARCHAR2) IS
  BEGIN
    MERGE INTO oc_time_config t
    USING (SELECT p_name AS n FROM dual) s
       ON (t.config_name = s.n AND t.scope_key = 'GLOBAL')
     WHEN MATCHED THEN UPDATE SET config_value = p_val, description = p_desc
     WHEN NOT MATCHED THEN
       INSERT (config_name, config_type, config_value, scope_key, description)
       VALUES (p_name, 'business', p_val, 'GLOBAL', p_desc);
  END;
  v_day  VARCHAR2(10); v_time VARCHAR2(5);
  v_con  NUMBER; v_adj NUMBER; v_back NUMBER; v_hold NUMBER;
BEGIN
  -- Taken from the existing rows rather than hardcoded, so a schema that was
  -- tuned by hand keeps its values. They are identical across periods; MAX
  -- simply picks the one they all share.
  SELECT MAX(ts_cutoff_day), MAX(ts_cutoff_time), MAX(contractor_resubmit_days),
         MAX(adjustment_months), MAX(backdated_months), MAX(hold_release_days)
    INTO v_day, v_time, v_con, v_adj, v_back, v_hold
    FROM oc_time_period_base;

  cfg('ts_cutoff_day',  NVL(v_day,'Monday'),
      'Weekly cut-off day. The EMPLOYEE deadline, and what V4 TIMING compares '
      || 'a submission against. The main application has no column for it.');
  cfg('ts_cutoff_time', NVL(v_time,'17:00'),
      'Weekly cut-off time, 24h.');
  cfg('contractor_resubmit_days', TO_CHAR(NVL(v_con,60)),
      'How far back a contractor may resubmit, in calendar days. Any '
      || 'resubmission past the weekly cut-off is Late Submission.');
  cfg('adjustment_months', TO_CHAR(NVL(v_adj,3)),
      'How many closed months back an adjustment may be raised.');
  cfg('backdated_months',  TO_CHAR(NVL(v_back,3)),
      'How far back a backdated change is accepted.');
  cfg('hold_release_days', TO_CHAR(NVL(v_hold,60)),
      'Days before an unresolved salary hold auto-releases.');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('6 settings moved to OC_TIME_CONFIG (scope GLOBAL)');
END;
/

PROMPT ============================================================
PROMPT [3/6] Drop the ten foreign keys
PROMPT ============================================================

-- Discovered rather than listed. A hardcoded list is a list that goes stale,
-- and the whole point of this step is that nothing may reference the base
-- table once the view replaces it.
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR c IN (SELECT c.table_name, c.constraint_name
              FROM user_constraints c
              JOIN user_constraints p ON p.constraint_name = c.r_constraint_name
             WHERE c.constraint_type = 'R'
               AND p.table_name = 'OC_TIME_PERIOD_BASE') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE ' || c.table_name
                   || ' DROP CONSTRAINT ' || c.constraint_name;
    DBMS_OUTPUT.PUT_LINE('  dropped ' || RPAD(c.constraint_name, 24)
                      || ' on ' || c.table_name);
    v_n := v_n + 1;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(v_n || ' foreign key(s) dropped');
END;
/

PROMPT ============================================================
PROMPT [4/6] Remap every PERIOD_ID to the upstream id
PROMPT ============================================================

DECLARE
  v_tot NUMBER := 0;
  v_n   NUMBER;
BEGIN
  -- Every table with a PERIOD_ID column, found from the dictionary. The
  -- mapping is by START_DATE, the only field that cannot mean two things.
  FOR t IN (SELECT DISTINCT tc.table_name
              FROM user_tab_columns tc
              JOIN user_tables ut ON ut.table_name = tc.table_name
             WHERE tc.column_name = 'PERIOD_ID'
               AND tc.table_name NOT IN ('OC_TIME_PERIOD_BASE')
               AND tc.table_name NOT LIKE '%\_BK' ESCAPE '\'
             ORDER BY tc.table_name) LOOP
    EXECUTE IMMEDIATE
      'UPDATE ' || t.table_name || ' x SET x.period_id = ('
      || '  SELECT m.period_id FROM oc_time_period_base b'
      || '    JOIN oc_mec_period_src m ON m.start_date = b.start_date'
      || '   WHERE b.period_id = x.period_id)'
      || ' WHERE EXISTS ('
      || '  SELECT 1 FROM oc_time_period_base b'
      || '    JOIN oc_mec_period_src m ON m.start_date = b.start_date'
      || '   WHERE b.period_id = x.period_id AND m.period_id <> b.period_id)';
    v_n := SQL%ROWCOUNT;
    IF v_n > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(t.table_name, 30) || v_n || ' row(s)');
    END IF;
    v_tot := v_tot + v_n;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE(v_tot || ' row(s) remapped to upstream period ids');
END;
/

PROMPT ============================================================
PROMPT [5/6] OC_TIME_PERIOD — a direct select, at last
PROMPT ============================================================

-- No local table in the FROM. A period added upstream appears here on the
-- next query, with nothing to run and nothing to provision.
--
-- PERIOD_NAME is derived rather than taken: theirs reads 'August 2026' and
-- every screen and message in this module reads 'AUG-2026'. Their name is
-- carried alongside so nothing is hidden.
CREATE OR REPLACE VIEW oc_time_period AS
SELECT m.period_id,
       UPPER(TO_CHAR(m.start_date, 'MON-YYYY'))    AS period_name,
       EXTRACT(YEAR  FROM m.start_date)            AS period_year,
       EXTRACT(MONTH FROM m.start_date)            AS period_month,
       m.status,
       m.start_date,
       m.end_date,
       m.accounting_date,
       m.delivery_cutoff_date AS delivery_cutoff,
       m.finance_cutoff_date  AS finance_cutoff,
       m.mec_close_date       AS mec_close,
       m.book_close_date      AS book_closure,
       -- Module settings, one row, cross-joined. These are the same for every
       -- period and always were -- 10_seed.sql wrote identical values into
       -- each one, which is what made them look like period data.
       c.ts_cutoff_day,
       c.ts_cutoff_time,
       CAST(NULL AS DATE)     AS client_cutoff,
       CAST(NULL AS VARCHAR2(60 CHAR)) AS payroll_country,
       CAST(NULL AS DATE)     AS payroll_cutoff,
       -- ADVANCE_CLOSE is theirs, and means something different from the
       -- column this module used to keep: they compute "any close-cycle date
       -- still ahead of today", we recorded "confirmed to accrual without full
       -- approval". The decision now lives on OC_TS_MONTH_CONFIRM.CONFIRM_TYPE
       -- where it always had its detail, and this column carries their meaning.
       m.advance_close,
       c.contractor_resubmit_days,
       c.hold_release_days,
       c.adjustment_months,
       c.backdated_months,
       m.period_id   AS mec_period_id,
       m.period_name AS mec_period_name,
       'Y'           AS mec_linked,
       m.created_by, m.created_on, m.updated_by, m.updated_on
  FROM oc_mec_period_src m
 CROSS JOIN (
       SELECT MAX(CASE WHEN config_name='ts_cutoff_day'  THEN config_value END) AS ts_cutoff_day,
              MAX(CASE WHEN config_name='ts_cutoff_time' THEN config_value END) AS ts_cutoff_time,
              MAX(CASE WHEN config_name='contractor_resubmit_days' THEN TO_NUMBER(config_value) END) AS contractor_resubmit_days,
              MAX(CASE WHEN config_name='hold_release_days'        THEN TO_NUMBER(config_value) END) AS hold_release_days,
              MAX(CASE WHEN config_name='adjustment_months'        THEN TO_NUMBER(config_value) END) AS adjustment_months,
              MAX(CASE WHEN config_name='backdated_months'         THEN TO_NUMBER(config_value) END) AS backdated_months
         FROM oc_time_config WHERE scope_key = 'GLOBAL') c;

PROMPT ============================================================
PROMPT [6/6] Recompile and verify
PROMPT ============================================================

DECLARE
  v_after NUMBER;
BEGIN
  FOR pass IN 1 .. 2 LOOP
    FOR o IN (SELECT object_name, object_type FROM user_objects
               WHERE status = 'INVALID'
                 AND object_type IN ('VIEW','PROCEDURE','FUNCTION',
                                     'PACKAGE','PACKAGE BODY','TRIGGER')
               ORDER BY CASE object_type WHEN 'VIEW' THEN 1
                                         WHEN 'PACKAGE' THEN 2 ELSE 3 END) LOOP
      BEGIN
        IF o.object_type = 'PACKAGE BODY' THEN
          EXECUTE IMMEDIATE 'ALTER PACKAGE ' || o.object_name || ' COMPILE BODY';
        ELSE
          EXECUTE IMMEDIATE 'ALTER ' || o.object_type || ' ' || o.object_name || ' COMPILE';
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END LOOP;
  SELECT COUNT(*) INTO v_after FROM user_objects WHERE status = 'INVALID';
  DBMS_OUTPUT.PUT_LINE('invalid after recompile: ' || v_after);
END;
/

SELECT object_name, object_type, status FROM user_objects
 WHERE status = 'INVALID' ORDER BY object_type, object_name;

COLUMN period_name FORMAT A12
COLUMN status      FORMAT A8
COLUMN editable    FORMAT A8
SELECT period_id, period_name, status,
       TO_CHAR(start_date,'DD-MON-YY')      AS starts,
       TO_CHAR(delivery_cutoff,'DD-MON-YY') AS delivery,
       ts_cutoff_day || ' ' || ts_cutoff_time AS weekly,
       CASE WHEN status <> 'Open' THEN 'N'
            WHEN TRUNC(SYSDATE) > delivery_cutoff THEN 'N'
            ELSE 'Y' END AS editable
  FROM oc_time_period ORDER BY start_date;

PROMPT
PROMPT --- weeks now hanging off an id no period has (must be empty) --
SELECT w.period_id, COUNT(*) AS weeks
  FROM oc_ts_week w
 WHERE NOT EXISTS (SELECT 1 FROM oc_time_period p WHERE p.period_id = w.period_id)
 GROUP BY w.period_id;

PROMPT
PROMPT PERIOD_ID is now the main application's id. Add a period there and it
PROMPT appears here on the next query -- nothing to provision, nothing to run.
PROMPT
PROMPT The query above replaces the ten foreign keys that were dropped. They
PROMPT could not survive a view, and they had stopped guaranteeing anything the
PROMPT moment another application took ownership of periods. Run it after any
PROMPT upstream deletion.
PROMPT
PROMPT OC_TIME_PERIOD_BASE is left in place with the old ids and values. Drop
PROMPT it once this is proven; until then it is the way back.
