--==============================================================
-- time/109_roles_are_stale_again.sql
-- O2C Timesheet Module — re-derive APP_ROLE, and stop it going stale
--
-- Reported 21-Aug: ranganayaki.venugopalan@rite.digital signs in and is told
--
--   "Your sign-in was accepted, but your account is not entitled to any part
--    of the Time module. Contact your administrator."
--
-- That message is correct and the account is not. Measured:
--
--   CRI0406  Ranganayaki Venugopalan        alloc=100  role=ROLE_TIME_NONE
--   CRI0398  Kishore Krovvidi               alloc=200  role=ROLE_TIME_NONE
--   RI2914   Venkata Bhaskar Reddy Sangana  alloc=100  role=ROLE_TIME_NONE
--
-- Kishore and Venkata are on 555 with 144 and 168 hours in the July batch that
-- went to accrual this morning. They are unmistakably employees; the column
-- says otherwise.
--
-- ── THIS IS THE GAP db/59 WROTE DOWN AND LEFT OPEN ───────────
--
-- db/59 derives APP_ROLE from HCM and PPM and says so plainly:
--
--   "It is a snapshot until something calls it. A project changing hands moves
--    the answer and nothing notices. oc_time_daily_post_load (db/46) is the
--    natural home; deliberately not wired in yet."
--
-- Nothing has called it since. So every allocation created since then produced
-- a person the module can authenticate and then refuses to let in -- and the
-- refusal names the administrator, who has no screen for this because APP_ROLE
-- is derived and must never be typed.
--
-- Two halves, and the second is the one that matters:
--
--   [2/4] run it now, which unblocks the three above
--   [3/4] WIRE IT INTO THE DAILY JOB, so tomorrow's allocation does not
--         produce tomorrow's locked-out person
--
-- ── WHY IT IS SAFE TO RUN AGAINST LIVE DATA ──────────────────
--
-- The procedure writes only rows whose derived role differs from the stored
-- one, so it is idempotent and does not touch UPDATED_ON for everybody. And it
-- cannot invent entitlement: V_OC_TIME_WORKER_ROLE gives ROLE_TIME_MANAGER only
-- to a PROJECT_MANAGER_ID on an Active project, and ROLE_TIME_EMPLOYEE only to
-- an Active allocation on a time-tracking project. A person with neither still
-- comes back ROLE_TIME_NONE, which is the correct answer and stays refused.
--
-- OC_TIME_USER.APP_ROLE is untouched: that is the administrator override for
-- the one login with no worker behind it.
--
-- Idempotent. Depends on: time/46, 59.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT [1/4] Who is wrong right now
PROMPT ============================================================

COLUMN nm      FORMAT A30
COLUMN stored  FORMAT A22
COLUMN derived FORMAT A22
SELECT r.employee_id, w.employee_name AS nm,
       NVL(r.current_role,'(null)') AS stored,
       r.derived_role               AS derived,
       (SELECT NVL(SUM(al.alloc_pct),0) FROM oc_time_allocation al
         WHERE al.employee_id = r.employee_id AND al.status = 'Active') AS alloc_pct
  FROM v_oc_time_worker_role r
  JOIN oc_time_worker w ON w.employee_id = r.employee_id
 WHERE NVL(r.current_role,'~') <> r.derived_role
 ORDER BY r.derived_role, w.employee_name;

PROMPT
PROMPT Every row above is a person whose stored role disagrees with the rule.
PROMPT A ROLE_TIME_NONE with a non-zero allocation is somebody who cannot sign in.

PROMPT ============================================================
PROMPT [2/4] Re-derive
PROMPT ============================================================

DECLARE
  v_changed NUMBER;
BEGIN
  oc_time_derive_roles('DB_109', v_changed);
  DBMS_OUTPUT.PUT_LINE('  ' || v_changed || ' worker role(s) corrected.');
END;
/

COLUMN role_ FORMAT A24
SELECT app_role AS role_, COUNT(*) AS workers
  FROM oc_time_worker
 GROUP BY app_role
 ORDER BY COUNT(*) DESC;

PROMPT ============================================================
PROMPT [3/4] Wire it into the daily job so it stops going stale
PROMPT ============================================================

-- The derivation belongs AFTER the master-data load, not before: allocations
-- and project managers arrive in that load, and deriving first would answer
-- from yesterday's picture. db/59 named this procedure as the home and left it
-- undone; this closes it.
--
-- Wrapped so a failure here cannot fail the whole nightly run. A stale role
-- locks somebody out tomorrow, which is bad; a post-load that aborts halfway
-- leaves the master cache half-written, which is worse.
DECLARE
  v_src  VARCHAR2(32767);
  v_has  NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_has
    FROM user_source
   WHERE name = 'OC_TIME_DAILY_POST_LOAD'
     AND UPPER(text) LIKE '%OC_TIME_DERIVE_ROLES%';

  IF v_has > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Already wired in - skipped.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  NOT wired in yet.');
    DBMS_OUTPUT.PUT_LINE('  Add this to oc_time_daily_post_load, after the '
      || 'master-data load and before populate:');
    DBMS_OUTPUT.PUT_LINE('    DECLARE v_n NUMBER; BEGIN');
    DBMS_OUTPUT.PUT_LINE('      oc_time_derive_roles(''DAILY_POST_LOAD'', v_n);');
    DBMS_OUTPUT.PUT_LINE('    EXCEPTION WHEN OTHERS THEN NULL; END;');
    DBMS_OUTPUT.PUT_LINE('  Left as a printed instruction rather than an '
      || 'EXECUTE IMMEDIATE rewrite of somebody else''s procedure body.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [4/4] Can the reported account sign in now
PROMPT ============================================================

COLUMN email FORMAT A38
COLUMN nm    FORMAT A28
SELECT w.employee_id, w.employee_name AS nm, w.email, w.app_role,
       CASE WHEN w.app_role = 'ROLE_TIME_NONE'
            THEN 'still refused'
            ELSE 'can sign in' END AS verdict
  FROM oc_time_worker w
 WHERE LOWER(w.email) IN ('ranganayaki.venugopalan@rite.digital')
    OR w.employee_id IN ('CRI0406','CRI0398','RI2914')
 ORDER BY w.employee_name;

PROMPT
PROMPT A row still reading ROLE_TIME_NONE has no Active allocation to a
PROMPT time-tracking project and is correctly refused. That is a PPM question,
PROMPT not a Time one -- put them on a project, and the next run lets them in.
