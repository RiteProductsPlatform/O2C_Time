--==============================================================
-- time/57_worker_emails.sql
-- O2C Timesheet Module — work emails for the test cohort
--
-- 56 could invite only one person. Measured against the pod 17-Aug-2026:
-- of the twelve, ONLY RI2894 has an email in PER_EMAIL_ADDRESSES (type W1).
-- The other eleven have none, so the WORKERS sync brings back NULL and
-- OC_TIME_USER.EMAIL is NOT NULL -- there is nothing to invite them with.
--
-- The addresses below are the ones supplied when the module was first set up.
-- They are NOT invented here and they are NOT derived from a name pattern:
-- guessing an address that half-works is worse than leaving it null, because
-- the account is created, looks fine, and the person can never be reached.
--
-- THIS SURVIVES THE NEXT SYNC. sync/worker sets
--   w.email = NVL(LOWER(r.email), w.email)
-- so a locally-set address is preserved when Fusion has none, and is correctly
-- overwritten the moment somebody adds a real one in HCM. That is the right way
-- round, and it is why this is safe to run rather than a change that gets
-- silently undone on the next master sync.
--
-- The proper fix is to load these into HCM. Until then this is a local stand-in
-- for one environment, which is why it is not in install_time.sql.
--
-- Idempotent. Never overwrites an address that already exists -- including the
-- one Fusion supplied for RI2894, which stays exactly as Fusion sent it.
--
-- Depends on: time/02, a completed WORKERS sync. Run 56 afterwards.
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
PROMPT [1/3] Set the addresses Fusion does not hold
PROMPT ============================================================

DECLARE
  v_set  NUMBER := 0;
  v_had  NUMBER := 0;
  v_miss NUMBER := 0;

  -- Delete a line to leave that person without a login. The list is the full
  -- original cohort; nothing here forces all twelve to be used.
  PROCEDURE addr(p_emp VARCHAR2, p_email VARCHAR2) IS
    v_rows NUMBER;
    v_exists NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_exists FROM oc_time_worker WHERE employee_id = p_emp;
    IF v_exists = 0 THEN
      v_miss := v_miss + 1;
      DBMS_OUTPUT.PUT_LINE('absent  ' || RPAD(p_emp,9)
        || ' no such worker -- not synced from HCM');
      RETURN;
    END IF;

    -- WHERE email IS NULL is the whole safety of this script: an address that
    -- came from Fusion, or one somebody corrected by hand, is never touched.
    UPDATE oc_time_worker
       SET email      = LOWER(p_email),
           updated_by = 'ADMIN_EMAIL',
           updated_on = SYSTIMESTAMP
     WHERE employee_id = p_emp
       AND email IS NULL;
    v_rows := SQL%ROWCOUNT;

    IF v_rows = 1 THEN
      v_set := v_set + 1;
      DBMS_OUTPUT.PUT_LINE('set     ' || RPAD(p_emp,9) || ' ' || LOWER(p_email));
    ELSE
      v_had := v_had + 1;
    END IF;
  END addr;
BEGIN
  addr('RI9001',  'navamani.solairajan@rite.digital');
  addr('RI2894',  'santoshkumar.kanala@rite.digital');   -- already from Fusion
  addr('RI2900',  'saisowmith.kantipudi@rite.digital');
  addr('RI2963',  'wajahad.ali@rite.digital');
  addr('RI2935',  'shivani.rathore@rite.digital');
  addr('RI3004',  'gayathri.radhakrishnan@rite.digital');
  addr('RI2914',  'bhaskar.sang@rite.digital');
  addr('CRI0406', 'ranganayaki.venugopalan@rite.digital');
  addr('CRI0398', 'kishore.krovvidi@rite.digital');
  addr('RI2985',  'aadhiseshan.a@rite.digital');
  addr('RI2249',  'saicharan.vadlakonda@rite.digital');

  -- RI2824 was ambiguous until 17-Aug-2026: a second record, person 7793
  -- 'S, Sam Joshuva Paul Jeevan', carried the same identity and it was unclear
  -- which one this address belonged to. 7793 has since been purged from HCM
  -- and RI2824 is now the only Sam Joshuva on the pod, so the address is
  -- unambiguous. Left recorded because "why are there two of this person"
  -- is a question worth not having to answer twice.
  addr('RI2824',  'sampaul.jeevan@rite.digital');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('set ' || v_set || ', already had one ' || v_had
                       || ', worker missing ' || v_miss);
END;
/

PROMPT ============================================================
PROMPT [2/3] Who can be invited now
PROMPT ============================================================

COLUMN employee_id FORMAT A12
COLUMN employee_name FORMAT A30
COLUMN email FORMAT A36
COLUMN source FORMAT A16
SELECT w.employee_id, w.employee_name,
       NVL(w.email,'(still none)') AS email,
       CASE WHEN w.email IS NULL          THEN 'cannot invite'
            WHEN w.updated_by = 'ADMIN_EMAIL' THEN 'local'
            ELSE 'Fusion' END AS source,
       NVL(w.app_role,'-') AS app_role
  FROM oc_time_worker w
 WHERE w.employee_id IN ('RI9001','RI2894','RI2824','RI2900','RI2963','RI2935',
                         'RI3004','RI2914','CRI0406','CRI0398','RI2985','RI2249')
 ORDER BY w.employee_id;

PROMPT ============================================================
PROMPT [3/3] Next, and one thing to check
PROMPT ============================================================
PROMPT
PROMPT Run 56_invite_logins.sql now. It will create an Invited account for
PROMPT everyone listed above with an address, then each person sets their own
PROMPT password:
PROMPT
PROMPT   POST /oc/time/auth/set-password
PROMPT   {"email":"<their email>","newPassword":"<8+ characters>"}
PROMPT
PROMPT WHERE THESE ADDRESSES COME FROM. Every one of the twelve has an HCM
PROMPT username in PER_USERS, and normalising it -- lower-case, spaces removed,
PROMPT plus @rite.digital -- reproduces EIGHT of the twelve exactly, including
PROMPT RI2894's, which is the one address Fusion actually holds. So that rule is
PROMPT the house convention and is the right fallback for anyone not listed
PROMPT here. The other four are shortened forms supplied at setup
PROMPT (wajahad.ali, bhaskar.sang, aadhiseshan.a, sampaul.jeevan) and are kept
PROMPT because a real mailbox beats a derived one.
PROMPT
PROMPT The real fix for all eleven is a work email in HCM. Once one exists,
PROMPT sync/worker overwrites the local value on its own -- NVL(LOWER(r.email),
PROMPT w.email) prefers Fusion whenever Fusion has an answer.
