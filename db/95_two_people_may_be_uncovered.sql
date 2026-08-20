--==============================================================
-- time/95_two_people_may_be_uncovered.sql
-- O2C Timesheet Module — RULE-014's index refused a second ABSENCE, not a
-- second cover
--
-- Santosh Kumar Kanala's 20-Aug absence still would not appear on PAGE-006
-- after db/94 put his leave right. Calling the endpoint said why, which reading
-- the code had not:
--
--   POST /oc/time/approval/llc/generate  {projectId:1121, periodId:46}
--   500 ORA-00001: unique constraint (O2C_TIME.UK_OC_TSLLC_COVER_DAY) violated
--
-- db/05 created it to enforce RULE-014 -- "One unbilled employee cannot be
-- mapped to 2 absent employees for the same day":
--
--   CREATE UNIQUE INDEX uk_oc_tsllc_cover_day
--     ON oc_ts_leave_loss_cover (cover_employee_id, absence_date)
--
-- ORACLE OMITS AN INDEX ENTRY ONLY WHEN EVERY KEY COLUMN IS NULL. ABSENCE_DATE
-- is NOT NULL, so a row awaiting a cover is indexed as (NULL, 20-Aug) and is
-- perfectly comparable with the next one. Sam Joshuva S already had an
-- uncovered line on 20-Aug, so Santosh's collided with it.
--
-- The rule it actually enforced was therefore: ONLY ONE PERSON IN THE COMPANY
-- MAY BE UNCOVERED ON ANY GIVEN DATE. Which is the opposite of the intent, and
-- gets worse the more absences there are to cover.
--
-- WORSE THAN LOSING ONE ROW. generate_llc_lines is a single INSERT ... SELECT,
-- so one collision rolls the whole run back: every absence that would have been
-- added that day is lost, not just the colliding one. And the handler answers
-- 500, which the screen reports as "Could not refresh absences" -- so the
-- manager sees a failure with no hint that the cause is a second person being
-- off on a day somebody else is already off.
--
-- It has been latent since db/05 and only shows once two people are absent on
-- the same date. On this pod that took until 20-Aug.
--
-- ── THE FIX ──────────────────────────────────────────────────────────────
--
-- A partial unique index, the standard Oracle idiom: make BOTH key expressions
-- NULL when there is no cover, so the row is not indexed at all.
--
--   CASE WHEN cover_employee_id IS NULL THEN NULL ELSE cover_employee_id END
--   CASE WHEN cover_employee_id IS NULL THEN NULL ELSE absence_date      END
--
-- Uncovered rows: both NULL, no entry, any number of them per date.
-- Assigned rows: the real pair, and RULE-014 holds exactly as written.
--
-- Global rather than per project, deliberately and unchanged: a person can only
-- physically stand in for one colleague on one day, whichever projects the two
-- absences belong to.
--
-- Idempotent. Supersedes db/05's index. Depends on: time/05, 09.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_tables
   WHERE table_name = 'OC_TS_LEAVE_LOSS_COVER';
  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20099, 'Connected as '
      || SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ', which does not own this module.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Schema OK: ' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'));
END;
/

PROMPT ============================================================
PROMPT [1/4] The absences the index is currently hiding
PROMPT ============================================================

-- Every date where more than one person is absent on an FCP + leave-loss
-- project. Each of these is a date where generate_llc_lines can only ever
-- create ONE line, and fails outright trying to add the second.
COLUMN who FORMAT A46
SELECT p.project_number,
       TO_CHAR(ab.absence_date,'DD-Mon-YY') AS on_date,
       COUNT(DISTINCT ab.employee_id)       AS people_absent,
       LISTAGG(DISTINCT w.employee_name, ', ')
         WITHIN GROUP (ORDER BY w.employee_name) AS who
  FROM oc_time_absence    ab
  JOIN oc_time_worker     w  ON w.employee_id  = ab.employee_id
  JOIN oc_time_allocation al ON al.employee_id = ab.employee_id
                            AND al.status      = 'Active'
                            AND ab.absence_date BETWEEN al.start_date
                                                AND NVL(al.end_date, ab.absence_date)
  JOIN oc_time_project    p  ON p.project_id   = al.project_id
                            AND p.revenue_model   = 'FCP'
                            AND p.leave_loss_flag = 'Y'
 WHERE ab.approval_status = 'Approved'
 GROUP BY p.project_number, ab.absence_date
HAVING COUNT(DISTINCT ab.employee_id) > 1
 ORDER BY p.project_number, ab.absence_date;

PROMPT
PROMPT Any row above is a date the old index could not hold. 20-Aug on 555
PROMPT should be one of them - Sam and Santosh are both off.

PROMPT ============================================================
PROMPT [2/4] UK_OC_TSLLC_COVER_DAY — index the cover, not the gap
PROMPT ============================================================

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM user_indexes
   WHERE index_name = 'UK_OC_TSLLC_COVER_DAY';
  IF v_n > 0 THEN
    EXECUTE IMMEDIATE 'DROP INDEX uk_oc_tsllc_cover_day';
    DBMS_OUTPUT.PUT_LINE('  old index dropped.');
  END IF;
END;
/

BEGIN
  -- RULE-014: a colleague cannot cover two absentees on the same day.
  --
  -- Both expressions collapse to NULL when no cover is assigned, so an
  -- uncovered row produces no index entry and any number of people may be
  -- waiting for a cover on one date. Writing it as (cover_employee_id,
  -- absence_date) indexed the gap instead of the cover, because ABSENCE_DATE is
  -- NOT NULL and Oracle only skips an entry when EVERY key column is null.
  EXECUTE IMMEDIATE q'~
    CREATE UNIQUE INDEX uk_oc_tsllc_cover_day
      ON oc_ts_leave_loss_cover (
        CASE WHEN cover_employee_id IS NULL THEN NULL ELSE cover_employee_id END,
        CASE WHEN cover_employee_id IS NULL THEN NULL ELSE absence_date      END)
  ~';
  DBMS_OUTPUT.PUT_LINE('  UK_OC_TSLLC_COVER_DAY recreated as a partial index.');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1452 THEN
    DBMS_OUTPUT.PUT_LINE('  *** NOT CREATED: two assigned rows already share a '
      || 'cover and a date. Resolve them, then re-run this file.');
  ELSE RAISE; END IF;
END;
/

PROMPT ============================================================
PROMPT [3/4] Build the lines the index had been refusing
PROMPT ============================================================

DECLARE
  v_made  NUMBER;
  v_total NUMBER := 0;
BEGIN
  FOR pe IN (SELECT period_id, period_name FROM oc_time_period
              WHERE status = 'Open' ORDER BY start_date)
  LOOP
    FOR pr IN (SELECT project_id, project_number FROM oc_time_project
                WHERE revenue_model = 'FCP' AND leave_loss_flag = 'Y'
                ORDER BY project_number)
    LOOP
      BEGIN
        v_made := oc_time_pkg.generate_llc_lines(pr.project_id, pe.period_id,
                                                 'FIX_95');
        IF v_made > 0 THEN
          DBMS_OUTPUT.PUT_LINE('  ' || pr.project_number || ' / '
            || pe.period_name || ': ' || v_made || ' line(s) added.');
        END IF;
        v_total := v_total + v_made;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  ' || pr.project_number || ' / '
          || pe.period_name || ': FAILED - ' || SUBSTR(SQLERRM,1,180));
      END;
    END LOOP;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('  ' || v_total || ' line(s) added in total.');
  COMMIT;
END;
/

PROMPT ============================================================
PROMPT [4/4] Verification
PROMPT ============================================================

COLUMN absent FORMAT A24
COLUMN cover  FORMAT A24
COLUMN proj   FORMAT A10
SELECT l.project_number AS proj, l.absence_date AS on_date, l.absence_day,
       l.absent_employee_name AS absent,
       l.absence_hours, l.loss_hours,
       NVL(l.cover_employee_name,'(none)') AS cover,
       l.llc_status
  FROM v_oc_ts_llc l
 ORDER BY l.project_number, l.absence_date, l.absent_employee_name;

PROMPT
PROMPT 20-Aug on 555 should now carry TWO rows - Sam at 2.00 and Santosh at
PROMPT 4.00, his 50% of an 8-hour shift. Both uncovered until a cover is
PROMPT assigned, which is a state the index no longer objects to.

PROMPT
PROMPT And the rule the index is actually for: nobody covering two people on
PROMPT one date. Must be no rows.

SELECT cover_employee_id, TO_CHAR(absence_date,'DD-Mon-YY') AS on_date,
       COUNT(*) AS assigned_twice
  FROM oc_ts_leave_loss_cover
 WHERE cover_employee_id IS NOT NULL
 GROUP BY cover_employee_id, absence_date
HAVING COUNT(*) > 1;
