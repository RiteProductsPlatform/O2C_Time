--==============================================================
-- time/54_payroll_country_alias.sql
-- O2C Timesheet Module — the payroll config names countries differently
--
-- 53 wired the payroll cut-off to o2c_dev.OC_PAYROLL_CONFIG and then reported
-- that it governs nobody. Two rows are configured for AUG-2026:
--
--   COUNTRY          TYPE         CUT-OFF      RELEASE
--   United States    Cut off      01-Aug-26    1
--   DUBAI            Date Range   31-Aug-26    1
--
-- and OC_TIME_WORKER.BASE_COUNTRY holds ISO alpha-2: 'US' for 2,066 people,
-- 'AE' for 44. The join c.country = w.base_country matches neither row, so
-- every worker resolves to NULL and salary stopping holds nobody -- correctly,
-- and uselessly.
--
-- THE SAME SHAPE AS THE TIMEZONE MAP, WITH ONE DIFFERENCE
--   49 fixed 'IN' versus 'India' by seeding both spellings on OUR side. That
--   worked because both ends were ours. Here the left-hand side belongs to the
--   main application, is read live, and is not ours to rewrite -- so the
--   translation has to live here.
--
-- AND 'DUBAI' IS NOT A COUNTRY
--   It is a city. The period definition says the cut-off varies by "different
--   business and countries", so COUNTRY plainly carries a payroll GROUP, not
--   an ISO code. Mapping DUBAI to AE is the obvious reading and it is still a
--   guess -- it could equally be a Dubai-based business unit whose staff sit
--   in several countries. It is seeded because leaving it unmapped holds
--   nobody either way, and flagged below so somebody confirms it.
--
-- Idempotent. Depends on: time/53
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
PROMPT [1/4] What the main application actually calls each payroll group
PROMPT ============================================================

COLUMN country FORMAT A26
COLUMN maps_to FORMAT A28
SELECT c.country,
       c.period_type,
       TO_CHAR(c.payroll_cutoff,'DD-Mon-YY') AS cutoff,
       c.hold_release_days AS rel_days,
       NVL((SELECT MAX(cfg.config_value) FROM oc_time_config cfg
             WHERE cfg.config_name = 'payroll_country_alias'
               AND cfg.scope_key   = c.country),
           '*** UNMAPPED - governs nobody ***') AS maps_to
  FROM oc_payroll_config_src c
 ORDER BY c.country, c.payroll_cutoff;

PROMPT
PROMPT Every row must map to a BASE_COUNTRY value that real workers carry.
PROMPT An unmapped row is not an error -- it simply governs no one.

PROMPT ============================================================
PROMPT [2/4] The alias map
PROMPT ============================================================

DECLARE
  PROCEDURE alias(p_their VARCHAR2, p_ours VARCHAR2, p_note VARCHAR2) IS
  BEGIN
    MERGE INTO oc_time_config c
    USING (SELECT p_their AS s FROM dual) x
       ON (c.config_name = 'payroll_country_alias' AND c.scope_key = x.s)
     WHEN MATCHED THEN UPDATE
          SET c.config_value = p_ours, c.description = p_note,
              c.updated_by = 'PAYROLL_ALIAS', c.updated_on = SYSTIMESTAMP
     WHEN NOT MATCHED THEN
          INSERT (config_name, config_type, config_value, scope_key,
                  description, created_by)
          VALUES ('payroll_country_alias', 'business', p_ours, p_their,
                  p_note, 'PAYROLL_ALIAS');
  END alias;
BEGIN
  -- SCOPE_KEY is THEIR string, CONFIG_VALUE is OUR BASE_COUNTRY code. That
  -- direction matters: their side is the one that varies and is not ours to
  -- change, so it is the key we look up by.
  alias('United States', 'US', 'Long-form country name in OC_PAYROLL_CONFIG.');
  alias('United Kingdom','GB', 'Long form; not yet present but costs nothing.');
  alias('India',         'IN', 'Long form; not yet present but costs nothing.');

  -- A CITY, mapped to its country. Flagged in [4] for confirmation: if DUBAI
  -- means a business unit rather than the UAE, this maps the wrong people.
  alias('DUBAI',         'AE', 'CITY, not a country - assumed United Arab '
                            || 'Emirates. CONFIRM with Finance.');

  -- Identity rows, so an ISO code on their side needs no special case and the
  -- join has exactly one shape.
  FOR c IN (SELECT DISTINCT base_country FROM oc_time_worker
             WHERE base_country IS NOT NULL) LOOP
    alias(c.base_country, c.base_country, 'Identity - already an ISO code.');
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('alias map seeded');
END;
/

PROMPT ============================================================
PROMPT [3/4] V_OC_TIME_PAYROLL_CUTOFF joins through the alias
PROMPT ============================================================

CREATE OR REPLACE VIEW v_oc_time_payroll_cutoff AS
SELECT p.period_id,
       p.period_name,
       -- OUR code, not theirs. Every caller asks with a BASE_COUNTRY, so the
       -- translation happens here once rather than at each call site.
       NVL(a.config_value, c.country)                          AS country,
       c.country                                               AS source_country,
       MAX(c.payroll_cutoff)                                   AS payroll_cutoff,
       MAX(c.hold_release_days) KEEP (DENSE_RANK LAST
             ORDER BY c.payroll_cutoff)                        AS hold_release_days,
       COUNT(*)                                                AS cutoffs_in_period,
       MAX(c.period_type) KEEP (DENSE_RANK LAST
             ORDER BY c.payroll_cutoff)                        AS period_type
  FROM oc_time_period        p
  JOIN oc_payroll_config_src c
    ON c.payroll_cutoff BETWEEN p.start_date AND p.end_date
  LEFT JOIN oc_time_config   a
    ON a.config_name = 'payroll_country_alias'
   AND a.scope_key   = c.country
 WHERE c.payroll_cutoff IS NOT NULL
 GROUP BY p.period_id, p.period_name, NVL(a.config_value, c.country), c.country;

PROMPT ============================================================
PROMPT [4/4] Who is now governed, and who still is not
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN country FORMAT A10
COLUMN source_country FORMAT A20
SELECT x.period_name, x.country, x.source_country,
       TO_CHAR(x.payroll_cutoff,'DD-Mon-YY') AS cutoff,
       x.hold_release_days AS rel_days,
       (SELECT COUNT(*) FROM oc_time_worker w
         WHERE w.status = 'Active' AND w.base_country = x.country) AS workers
  FROM v_oc_time_payroll_cutoff x
 ORDER BY x.period_name, x.country;

PROMPT
PROMPT WORKERS is the number this cut-off now governs. A zero there means the
PROMPT alias still does not match anybody, and the row is decoration.

PROMPT
PROMPT --- and the reverse: people in the open period with no cut-off at all
SELECT NVL(w.base_country,'(null)') AS base_country, COUNT(*) AS workers
  FROM oc_time_worker w
 WHERE w.status = 'Active'
   AND NOT EXISTS (SELECT 1 FROM v_oc_time_payroll_cutoff x
                    JOIN oc_time_period p ON p.period_id = x.period_id
                   WHERE x.country = w.base_country AND p.status = 'Open')
 GROUP BY w.base_country ORDER BY 2 DESC FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT ============================================================
PROMPT TWO THINGS TO CONFIRM WITH FINANCE
PROMPT ============================================================
PROMPT
PROMPT 1. DUBAI. Mapped to AE on the reading that it means the United Arab
PROMPT    Emirates. If it is a business unit instead, it governs the wrong
PROMPT    people -- change the alias row, not this script.
PROMPT
PROMPT 2. HOLD_RELEASE_DAYS is 1 on both rows. CFG-012 and the period
PROMPT    definition both describe roughly 60 days for an employee to resubmit
PROMPT    a defaulted timesheet. One day is either deliberate for testing or a
PROMPT    placeholder nobody revisited, and it decides how long somebody's pay
PROMPT    stays held.
