--==============================================================
-- time/58_demo_passwords.sql
-- O2C Timesheet Module — one shared password, for demo only
--
-- Sets every account in the test cohort Active with the same password so
-- signing in is not a thing anybody has to think about during a demo.
--
-- THIS IS NOT A PRODUCTION SCRIPT AND MUST NOT REACH ONE.
--
--   One credential across twelve real identities means the audit trail is
--   fiction: OC_TS_APPROVAL records who approved a week, OC_TS_WEEK_VERSION
--   records who changed it, and RULE-015 turns on a manager not being the
--   person they approve. All of that is only as true as the login, and a
--   password twelve people share cannot tell them apart. It is fine for a
--   demo, where nobody is pretending the trail is evidence, and it is not fine
--   anywhere a real approval is recorded.
--
--   The same string is also the Fusion pod password for
--   sampaul.jeevan@rite.digital (CLAUDE.md section 13, already flagged for
--   rotation). Reusing it here couples the two: whoever can sign into the
--   timesheet demo can guess their way into the pod. Rotate the pod
--   credential and this becomes a demo password and nothing else.
--
-- The proper path is 56 + set-password per person, which needs no shared
-- secret and leaves the trail meaning what it says. Use that for UAT.
--
-- Idempotent. Re-running resets the same password and kills open sessions.
--
-- Depends on: time/11 (oc_time_hash_password), 56 (the accounts), 57 (emails).
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_objects
   WHERE object_name = 'OC_TIME_HASH_PASSWORD' AND status = 'VALID';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099,
      'OC_TIME_HASH_PASSWORD is missing or invalid. Run 11_auth.sql first.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/3] Set the shared password
PROMPT ============================================================

DECLARE
  -- Change here, not in twelve places. Kept as a constant so the value is
  -- stated once and the script reads as "one password", which is the point.
  c_pwd CONSTANT VARCHAR2(60) := 'Rite@123';
  v_n   NUMBER := 0;
  v_s   NUMBER := 0;
BEGIN
  FOR u IN (SELECT user_id, LOWER(email) AS email, employee_id
              FROM oc_time_user
             WHERE employee_id IN ('RI9001','RI2894','RI2824','RI2900','RI2963',
                                   'RI2935','RI3004','RI2914','CRI0406',
                                   'CRI0398','RI2985','RI2249')
                OR LOWER(email) = 'admin@rite.digital')
  LOOP
    -- The hash is over LOWER(email) || ':' || password, so it must be built
    -- from the SAME email the login will send. Passing the raw column would
    -- produce a hash nothing can reproduce if the stored address has any
    -- upper case in it -- which RI2894's did, before Fusion lower-cased it.
    UPDATE oc_time_user
       SET password_hash = oc_time_hash_password(u.email, c_pwd),
           status        = 'Active',
           failed_count  = 0,
           updated_by    = 'DEMO_PWD',
           updated_on    = SYSTIMESTAMP
     WHERE user_id = u.user_id;
    v_n := v_n + 1;

    -- Same rule as set-password in ords/14: changing a credential ends every
    -- session opened with the old one.
    DELETE FROM oc_time_session WHERE user_id = u.user_id;
    v_s := v_s + SQL%ROWCOUNT;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('accounts set Active: ' || v_n);
  DBMS_OUTPUT.PUT_LINE('sessions ended: ' || v_s);
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('*** Nothing matched. Run 57 then 56 first.');
  END IF;
END;
/

PROMPT ============================================================
PROMPT [2/3] Everyone who can sign in, and as what
PROMPT ============================================================

COLUMN email FORMAT A36
COLUMN employee_id FORMAT A11
COLUMN status FORMAT A9
COLUMN app_role FORMAT A22
COLUMN menu FORMAT A26
SELECT u.email,
       NVL(u.employee_id,'(no worker)') AS employee_id,
       u.status,
       NVL(u.app_role, NVL(w.app_role,'ROLE_TIME_NONE')) AS app_role,
       -- RULE-022 / PER-004, so it is obvious which login demonstrates what.
       CASE NVL(u.app_role, NVL(w.app_role,'ROLE_TIME_NONE'))
            WHEN 'ROLE_TIME_ADMIN'      THEN 'Setup + Operations'
            WHEN 'ROLE_TIME_MANAGER'    THEN 'My Work + Team'
            WHEN 'ROLE_TIME_EMPLOYEE'   THEN 'My Work'
            WHEN 'ROLE_TIME_CONTRACTOR' THEN 'My Work'
            ELSE 'none - empty menu' END AS menu
  FROM oc_time_user u
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 ORDER BY app_role, u.email;

PROMPT ============================================================
PROMPT [3/3] Reminder
PROMPT ============================================================
PROMPT
PROMPT Every account above now shares one password. That is deliberate and it
PROMPT is demo-only. Before UAT, run 56 for real accounts and have each person
PROMPT set their own through POST /oc/time/auth/set-password -- an approval
PROMPT trail is only worth what the login behind it is worth.
