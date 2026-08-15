--==============================================================
-- time/49_country_zones.sql
-- O2C Timesheet Module — a zone for every country in the worker data
--
-- 48 seeded nine countries. The worker table holds 59 distinct BASE_COUNTRY
-- values, so about fifty of them -- SA, FR, IT, CH, ES, JP, CN and the rest --
-- were falling back to Asia/Kolkata. That fallback is the safe failure rather
-- than a crash, but it is still the wrong cut-off for everybody in them: a
-- worker in Sao Paulo would be judged against a deadline nine hours out.
--
-- The codes are ISO-3166 alpha-2, which the run of [1/6] in 48 confirmed --
-- 'US', 'GB', 'IN', not long names. The long-form rows 48 seeded ('India',
-- 'United Kingdom', 'United States') are left in place: harmless, and they
-- cost nothing if the extract ever changes shape.
--
-- COUNTRIES THAT SPAN SEVERAL ZONES get their commercial centre, and that is a
-- real approximation rather than a fact:
--
--   US  America/New_York     eastern; Chicago, Denver and LA are 1-3h behind
--   CA  America/Toronto      eastern; Vancouver is 3h behind
--   AU  Australia/Sydney     eastern; Perth is 2h behind
--   BR  America/Sao_Paulo    the populated south-east
--   RU  Europe/Moscow        western; Russia spans eleven zones
--   MX  America/Mexico_City  central
--   CN  Asia/Shanghai        the whole country runs on one zone anyway
--
--   Anybody in the wrong half of one of those is judged against a cut-off up
--   to three hours out. If that matters, the fix is not a better country
--   guess -- it is a per-worker zone, which needs a column Fusion is not
--   sending today.
--
-- Idempotent. Depends on: time/48
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
PROMPT [1/3] Every country in the worker data
PROMPT ============================================================

DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(64) INDEX BY VARCHAR2(8);
  m t_map;
  v_added NUMBER := 0;

  -- VALIDATE BEFORE WRITING. A zone Oracle does not recognise makes FROM_TZ
  -- raise inside oc_time_week_timing, which swallows it and returns
  -- WithinCutoff -- so that country never defaults, silently and for ever.
  -- Seeding one is worse than leaving it unmapped, because unmapped at least
  -- falls back to a working zone.
  PROCEDURE put(p_code VARCHAR2, p_zone VARCHAR2) IS
    v_ok VARCHAR2(1);
  BEGIN
    BEGIN
      SELECT 'Y' INTO v_ok FROM dual
       WHERE FROM_TZ(CAST(SYSDATE AS TIMESTAMP), p_zone) IS NOT NULL;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  REFUSED ' || p_code || ' -> ' || p_zone
        || ' (this database does not know that zone)');
      RETURN;
    END;

    MERGE INTO oc_time_config c
    USING (SELECT p_code AS s FROM dual) x
       ON (c.config_name = 'ts_cutoff_tz' AND c.scope_key = x.s)
     WHEN MATCHED THEN UPDATE
          SET c.config_value = p_zone, c.updated_by = 'COUNTRY_TZ',
              c.updated_on = SYSTIMESTAMP
     WHEN NOT MATCHED THEN
          INSERT (config_name, config_type, config_value, scope_key,
                  description, created_by)
          VALUES ('ts_cutoff_tz', 'business', p_zone, p_code,
                  'Cut-off zone for ' || p_code, 'COUNTRY_TZ');
  END put;
BEGIN
  -- Asia / Middle East
  put('IN','Asia/Kolkata');        put('PK','Asia/Karachi');
  put('CN','Asia/Shanghai');       put('JP','Asia/Tokyo');
  put('KR','Asia/Seoul');          put('TW','Asia/Taipei');
  put('HK','Asia/Hong_Kong');      put('SG','Asia/Singapore');
  put('MY','Asia/Kuala_Lumpur');   put('TH','Asia/Bangkok');
  put('VN','Asia/Ho_Chi_Minh');    put('ID','Asia/Jakarta');
  put('PH','Asia/Manila');         put('KZ','Asia/Almaty');
  put('AE','Asia/Dubai');          put('SA','Asia/Riyadh');
  put('KW','Asia/Kuwait');         put('OM','Asia/Muscat');
  put('QA','Asia/Qatar');          put('BH','Asia/Bahrain');
  put('IL','Asia/Jerusalem');      put('TR','Europe/Istanbul');

  -- Europe
  put('GB','Europe/London');       put('IE','Europe/Dublin');
  put('FR','Europe/Paris');        put('DE','Europe/Berlin');
  put('IT','Europe/Rome');         put('ES','Europe/Madrid');
  put('PT','Europe/Lisbon');       put('NL','Europe/Amsterdam');
  put('BE','Europe/Brussels');     put('LU','Europe/Luxembourg');
  put('CH','Europe/Zurich');       put('AT','Europe/Vienna');
  put('SE','Europe/Stockholm');    put('NO','Europe/Oslo');
  put('DK','Europe/Copenhagen');   put('FI','Europe/Helsinki');
  put('PL','Europe/Warsaw');       put('CZ','Europe/Prague');
  put('HU','Europe/Budapest');     put('RO','Europe/Bucharest');
  put('GR','Europe/Athens');
  -- 'Kiev', not 'Kyiv'. The 2022 rename is in current tzdata but not in this
  -- database's timezone file, and the validation above caught it on the first
  -- run -- Ukraine's 24 workers would otherwise never have defaulted. Kiev
  -- remains a backward-compatibility alias in new files, so it works on both.
  put('UA','Europe/Kiev');
  put('RU','Europe/Moscow');

  -- Americas
  put('US','America/New_York');    put('CA','America/Toronto');
  put('MX','America/Mexico_City'); put('BR','America/Sao_Paulo');
  put('AR','America/Argentina/Buenos_Aires');
  put('CL','America/Santiago');    put('CO','America/Bogota');
  put('VE','America/Caracas');

  -- Africa / Oceania
  put('ZA','Africa/Johannesburg'); put('DZ','Africa/Algiers');
  put('MA','Africa/Casablanca');   put('AU','Australia/Sydney');
  put('NZ','Pacific/Auckland');

  COMMIT;
  SELECT COUNT(*) INTO v_added FROM oc_time_config
   WHERE config_name = 'ts_cutoff_tz';
  DBMS_OUTPUT.PUT_LINE(v_added || ' cut-off zone rows in total');
END;
/

PROMPT ============================================================
PROMPT [2/3] Anything still unmapped, and anything that is not a real zone
PROMPT ============================================================

-- Two different faults, and only one of them is visible without asking.
--
--   unmapped  -- a country with workers and no row. Falls back to GLOBAL,
--                so those people are judged against India's clock.
--   bad zone  -- a row whose value Oracle does not recognise. FROM_TZ raises,
--                oc_time_week_timing swallows it and returns WithinCutoff,
--                so that country NEVER defaults. Silent, and worse.
COLUMN base_country FORMAT A16
COLUMN zone         FORMAT A30
COLUMN state        FORMAT A34
DECLARE
  v_bad  NUMBER := 0;
  v_miss NUMBER := 0;
  v_ok   VARCHAR2(1);
BEGIN
  FOR c IN (SELECT NVL(w.base_country,'(null)') AS country, COUNT(*) AS n,
                   (SELECT config_value FROM oc_time_config
                     WHERE config_name = 'ts_cutoff_tz'
                       AND scope_key = w.base_country) AS zone
              FROM oc_time_worker w
             WHERE w.status = 'Active'
             GROUP BY w.base_country
             ORDER BY COUNT(*) DESC)
  LOOP
    IF c.zone IS NULL THEN
      v_miss := v_miss + 1;
      DBMS_OUTPUT.PUT_LINE('  UNMAPPED  ' || RPAD(c.country,16)
        || LPAD(c.n,6) || ' worker(s) -> falls back to GLOBAL');
    ELSE
      BEGIN
        -- The only way to know a zone name is real is to make Oracle use it.
        SELECT 'Y' INTO v_ok FROM dual
         WHERE FROM_TZ(CAST(SYSDATE AS TIMESTAMP), c.zone) IS NOT NULL;
      EXCEPTION WHEN OTHERS THEN
        v_bad := v_bad + 1;
        DBMS_OUTPUT.PUT_LINE('  BAD ZONE  ' || RPAD(c.country,16)
          || c.zone || '  *** never defaults ***');
      END;
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(CHR(10) || v_miss || ' country(ies) unmapped, '
                    || v_bad || ' with an unusable zone');
  IF v_miss = 0 AND v_bad = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Every country with active workers has a valid zone.');
  END IF;
END;
/

PROMPT
PROMPT A (null) country is expected and is not a fault -- those workers have no
PROMPT BASE_COUNTRY from Fusion at all and correctly take the GLOBAL zone.

PROMPT ============================================================
PROMPT [3/3] The spread, and what the job would do now
PROMPT ============================================================

COLUMN zone  FORMAT A30
COLUMN codes FORMAT A46
SELECT config_value AS zone,
       COUNT(*) AS countries,
       LISTAGG(scope_key, ' ') WITHIN GROUP (ORDER BY scope_key) AS codes
  FROM oc_time_config
 WHERE config_name = 'ts_cutoff_tz' AND scope_key <> 'GLOBAL'
 GROUP BY config_value
 ORDER BY 1;

PROMPT
DECLARE
  v_due NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_due
    FROM oc_ts_week w
    JOIN oc_time_period p ON p.period_id = w.period_id
   WHERE p.status = 'Open'
     AND w.submission_status = 'NotYetSubmitted'
     AND w.week_end < TRUNC(SYSDATE)
     AND oc_time_week_timing(w.ts_week_id) = 'PastCutoff';
  DBMS_OUTPUT.PUT_LINE(v_due || ' week(s) would be defaulted by the next run.');
  DBMS_OUTPUT.PUT_LINE('Counted with the ZONE-AWARE timing, so it may differ');
  DBMS_OUTPUT.PUT_LINE('from the 134 that 47 reported before zones existed.');
END;
/

PROMPT
PROMPT ============================================================
PROMPT THE JOB IS ENABLED
PROMPT ============================================================
PROMPT
PROMPT 47 and 48 both created it with enabled => TRUE, which was wrong of them:
PROMPT 47's own output said to decide deliberately and then started the job
PROMPT anyway. It runs every fifteen minutes.
PROMPT
PROMPT   BEGIN DBMS_SCHEDULER.DISABLE('OC_TIME_CUTOFF_JOB'); END;
PROMPT   /
PROMPT
PROMPT   BEGIN DBMS_SCHEDULER.ENABLE('OC_TIME_CUTOFF_JOB');  END;
PROMPT   /
PROMPT
PROMPT Defaulting the backlog is not reversible from a screen. Each week gets
PROMPT locked, marked DEFAULTED_BY='EMPLOYEE', and becomes a salary-hold
PROMPT candidate under RULE-016.
