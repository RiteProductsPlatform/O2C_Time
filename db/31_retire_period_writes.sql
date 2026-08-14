--==============================================================
-- time/31_retire_period_writes.sql
-- O2C Timesheet Module — nothing here opens or closes a period any more
--
-- Housekeeping after time/30 made OC_TIME_PERIOD a view over the main
-- application's OC_MEC_PERIOD.
--
-- WHAT BREAKS WITHOUT THIS
--   OC_TIME_OPEN_PERIOD and OC_TIME_CLOSE_PERIOD were built on 12-Aug and do
--   `UPDATE oc_time_period SET status = ...`. That target is now a JOINED
--   view, so the update is not key-preserved and Oracle refuses it with
--   ORA-01732 -- at RUN time, not compile time. The procedures stay VALID and
--   fail only when an admin presses the button.
--
--   That is the worst shape for a failure: it looks like the feature is there.
--
-- WHY THEY ARE NOT SIMPLY DROPPED
--   The ORDS routes and the page chains call them by name. Dropping them
--   turns a clear refusal into a 404 and an unexplained toast. Instead they
--   now raise a business error saying where period control actually lives,
--   which the handlers already map to a 400 and the page shows verbatim.
--
-- Idempotent. Depends on: time/24, time/30
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ── WHICH SCHEMA AM I? ───────────────────────────────────────
-- Run in the wrong one and every statement fails with ORA-00942 naming a
-- table that plainly exists -- because it exists in the OTHER schema. That
-- happened on 14-Aug against O2C_DEV, and the output is long enough that the
-- cause is not obvious from it. So: refuse immediately, and say so.
--
-- O2C_DEV owns OC_MEC_PERIOD and is the schema this module READS FROM.
-- O2C_TIME owns everything else here and is the schema to be CONNECTED AS.
DECLARE
  v_me VARCHAR2(128) := SYS_CONTEXT('USERENV','CURRENT_SCHEMA');
BEGIN
  IF v_me <> 'O2C_TIME' THEN
    RAISE_APPLICATION_ERROR(-20099,
      'Connected as ' || v_me || '. This script must run as O2C_TIME -- ' ||
      'O2C_DEV owns OC_MEC_PERIOD and is only read FROM. Reconnect and re-run.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || v_me);
END;
/

PROMPT ============================================================
PROMPT [1/3] The two period writers now refuse, and say why
PROMPT ============================================================

CREATE OR REPLACE FUNCTION oc_time_open_period(
  p_period_id IN NUMBER,
  p_actor     IN VARCHAR2 DEFAULT 'ADMIN') RETURN NUMBER
IS
  v_name oc_time_period.period_name%TYPE;
BEGIN
  BEGIN
    SELECT period_name INTO v_name
      FROM oc_time_period WHERE period_id = p_period_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_name := 'That period'; END;

  -- -20013 is inside the band the ORDS handlers map to HTTP 400 with the
  -- message passed through, so the admin reads this sentence and not a stack.
  RAISE_APPLICATION_ERROR(-20013,
    v_name || ' cannot be opened from here. Period control moved to the O2C '
    || 'main application on 13-Aug-2026 -- open it on its Period Control '
    || 'screen and this module picks the change up immediately, because it '
    || 'reads the period live rather than holding a copy.');
END;
/
SHOW ERRORS

CREATE OR REPLACE FUNCTION oc_time_close_period(
  p_period_id IN NUMBER,
  p_actor     IN VARCHAR2 DEFAULT 'ADMIN',
  p_force     IN VARCHAR2 DEFAULT 'N') RETURN NUMBER
IS
  v_name oc_time_period.period_name%TYPE;
BEGIN
  BEGIN
    SELECT period_name INTO v_name
      FROM oc_time_period WHERE period_id = p_period_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_name := 'That period'; END;

  RAISE_APPLICATION_ERROR(-20013,
    v_name || ' cannot be closed from here. Period control moved to the O2C '
    || 'main application on 13-Aug-2026. Note it also closes a period '
    || 'automatically once the accounting date has passed, and permits only '
    || 'one open period at a time.');
END;
/
SHOW ERRORS

PROMPT ============================================================
PROMPT [2/3] The admin view stops offering what it cannot do
PROMPT ============================================================

-- Everything informational is kept -- phase, weeks, people, and the
-- unconfirmed-project count, which is still the number that decides whether a
-- month is SAFE to close. It is just no longer this module's button to press.
--
-- CAN_OPEN and CAN_CLOSE are gone rather than hardcoded to 'N'. A flag that
-- always says no is a flag somebody will one day try to make say yes.
CREATE OR REPLACE VIEW v_oc_time_period_admin AS
SELECT p.period_id,
       p.period_name,
       p.status,
       TO_CHAR(p.start_date,      'YYYY-MM-DD') AS start_date,
       TO_CHAR(p.end_date,        'YYYY-MM-DD') AS end_date,
       TO_CHAR(p.delivery_cutoff, 'YYYY-MM-DD') AS delivery_cutoff,
       TO_CHAR(p.finance_cutoff,  'YYYY-MM-DD') AS finance_cutoff,
       CASE WHEN TRUNC(SYSDATE) BETWEEN p.start_date AND p.end_date
              THEN 'Current'
            WHEN p.start_date > TRUNC(SYSDATE) THEN 'Future'
            ELSE 'Past'
       END AS phase,
       (SELECT COUNT(*) FROM oc_ts_week w
         WHERE w.period_id = p.period_id)                    AS weeks,
       (SELECT COUNT(DISTINCT w.employee_id) FROM oc_ts_week w
         WHERE w.period_id = p.period_id)                    AS people,
       (SELECT COUNT(*) FROM (
          SELECT DISTINCT m.project_id
            FROM v_oc_ts_month_summary m
           WHERE m.period_id = p.period_id
             AND NOT EXISTS (SELECT 1 FROM oc_ts_month_confirm c
                              WHERE c.project_id = m.project_id
                                AND c.period_id  = m.period_id)))
                                                             AS unconfirmed_projects,
       -- Where the row actually comes from. 'N' means the main application has
       -- no period starting on this date, so STATUS and the cut-offs above are
       -- the last known local values rather than live ones.
       p.mec_linked,
       p.mec_period_id,
       p.mec_period_name,
       -- The weekly cut-off has no upstream source and stays this module's.
       p.ts_cutoff_day, p.ts_cutoff_time
  FROM oc_time_period p;

PROMPT ============================================================
PROMPT [3/3] Verification
PROMPT ============================================================

COLUMN period_name FORMAT A12
COLUMN status      FORMAT A8
COLUMN phase       FORMAT A8
COLUMN mec_name    FORMAT A16
SELECT period_name, status, phase, mec_linked,
       mec_period_name AS mec_name, weeks, people,
       unconfirmed_projects AS unconfirmed,
       ts_cutoff_day || ' ' || ts_cutoff_time AS weekly_cutoff
  FROM v_oc_time_period_admin ORDER BY start_date;

PROMPT
PROMPT MEC_LINKED must read 'Y' on every period that matters. An 'N' means the
PROMPT main application has no row starting on that date -- the period still
PROMPT works, on its last known local values, but it has stopped tracking.
PROMPT
PROMPT UNCONFIRMED_PROJECTS is still worth reading before anyone closes a month
PROMPT upstream: closing gates editing, and a project found unconfirmed
PROMPT afterwards cannot be fixed by approving it. The number moved; the risk
PROMPT did not.
PROMPT
PROMPT STILL TO DO ON THE SCREEN: main-sync-status-page.html carries Open and
PROMPT Close buttons that now call a refusal. They are safe -- the admin gets a
PROMPT sentence telling them where to go -- but they should come off the page.
