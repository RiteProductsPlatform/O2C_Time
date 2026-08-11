--==============================================================
-- time/91_production_readiness.sql
-- O2C Timesheet Module — what is Fusion's, what is seed, what is test
--
-- READ ONLY. Deletes nothing, changes nothing. Run it, read it, then decide.
--
-- THE QUESTION IT ANSWERS
--   "I want production ready. Only Fusion data, other than the login."
--
-- That cannot be taken literally, and the distinction matters more than it
-- looks. THREE kinds of row live in these tables:
--
--   FUSION      workers, projects, tasks, allocations, absences, calendar.
--               Synced. Carries a FUSION_* id.
--
--   DESIGN      PRJ-ORG and the COMMON tasks (Leave, Training, Travel), the
--               status and flag dictionaries, rejection reasons,
--               OC_TIME_CONFIG, OC_TIME_PERIOD and its cut-offs. Fusion has no
--               source for any of it and never will -- a period is a decision,
--               not a fact about Fusion. Seeded by 10_seed.sql, and REQUIRED:
--               remove the COMMON Leave task and absence prepopulation has
--               nowhere to write (RULE-008); remove PRJ-ORG and FLD-006's
--               implicitly-everyone project is gone.
--
--   TEST        12 workers, 3 projects, their WBS tasks, allocations, a
--               hand-made Jun-Aug calendar, absences and dev logins. Seeded by
--               90_test_seed.sql. All of it is now supplied by Fusion, so all
--               of it must go before production.
--
-- HOW THEY ARE TOLD APART
--   By the Fusion id. The sync populates FUSION_PERSON_ID, FUSION_PROJECT_ID
--   and FUSION_TASK_ID; a hand-seeded row has none. That discriminator only
--   became reliable on 11-Aug-2026, when the extracts started carrying those
--   ids -- before that WORKERS did not select person_id at all.
--
--   So: NULL Fusion id AND not one of the two design rows => test data.
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT ============================================================
PROMPT [1/5] Master data — how much is really Fusion's
PROMPT ============================================================

COLUMN table_name FORMAT A22
COLUMN verdict    FORMAT A46

SELECT 'OC_TIME_WORKER' AS table_name,
       COUNT(*) AS total,
       COUNT(fusion_person_id) AS from_fusion,
       COUNT(*) - COUNT(fusion_person_id) AS not_fusion
  FROM oc_time_worker
UNION ALL
SELECT 'OC_TIME_PROJECT', COUNT(*), COUNT(fusion_project_id),
       COUNT(*) - COUNT(fusion_project_id) FROM oc_time_project
UNION ALL
SELECT 'OC_TIME_TASK', COUNT(*), COUNT(fusion_task_id),
       COUNT(*) - COUNT(fusion_task_id) FROM oc_time_task
UNION ALL
SELECT 'OC_TIME_ALLOCATION', COUNT(*), COUNT(fusion_project_id),
       COUNT(*) - COUNT(fusion_project_id) FROM oc_time_allocation
UNION ALL
SELECT 'OC_TIME_ABSENCE', COUNT(*), COUNT(fusion_absence_id),
       COUNT(*) - COUNT(fusion_absence_id) FROM oc_time_absence;

PROMPT
PROMPT NOT_FUSION is the number to look at. Some of it is DESIGN and must stay
PROMPT -- the next section separates the two.

PROMPT
PROMPT ============================================================
PROMPT [2/5] The non-Fusion rows, named
PROMPT ============================================================

COLUMN what      FORMAT A34
COLUMN detail    FORMAT A44
COLUMN keep_drop FORMAT A6

-- Projects with no Fusion id. PRJ-ORG is design; anything else is test data.
SELECT 'PROJECT' AS what,
       project_number || ' - ' || SUBSTR(project_name, 1, 30) AS detail,
       CASE WHEN project_number = 'PRJ-ORG' THEN 'KEEP' ELSE 'DROP' END AS keep_drop
  FROM oc_time_project
 WHERE fusion_project_id IS NULL
UNION ALL
-- Tasks with no Fusion id. COMMON tasks are design; a WBS task without a
-- Fusion id was hand-seeded against a hand-seeded project.
SELECT 'TASK (' || task_type || ')',
       task_code || ' - ' || SUBSTR(task_name, 1, 28),
       CASE WHEN task_type = 'COMMON' THEN 'KEEP' ELSE 'DROP' END
  FROM oc_time_task
 WHERE fusion_task_id IS NULL
 ORDER BY 3 DESC, 1, 2;

PROMPT
PROMPT Every KEEP row is design data required by a rule. Every DROP row came
PROMPT from 90_test_seed.sql and is now supplied by Fusion.

PROMPT
PROMPT ============================================================
PROMPT [3/5] Workers with no Fusion id
PROMPT ============================================================

-- All twelve HDL test workers were loaded INTO Fusion, so they come back
-- through the sync and carry a person id like everyone else. A worker with no
-- Fusion id was created only in this schema and exists nowhere upstream --
-- they cannot be managed, terminated or paid, and their timesheets reference a
-- person Fusion has never heard of.
COLUMN employee_id   FORMAT A14
COLUMN employee_name FORMAT A28
COLUMN status        FORMAT A10

SELECT employee_id, employee_name, status, worker_type
  FROM oc_time_worker
 WHERE fusion_person_id IS NULL
 ORDER BY employee_id;

PROMPT
PROMPT Empty is the right answer. Any row here is a person who exists only in
PROMPT this database.

PROMPT
PROMPT ============================================================
PROMPT [4/5] Transactions resting on non-Fusion master data
PROMPT ============================================================

-- THE REASON ORDER MATTERS. A test project cannot simply be deleted while
-- timesheet entries point at it: the foreign key refuses, or cascades and
-- takes real-looking hours with it. This counts what is standing on top.
SELECT 'entries on non-Fusion projects' AS what, COUNT(*) AS rows_
  FROM oc_ts_entry e
  JOIN oc_time_project p ON p.project_id = e.project_id
 WHERE p.fusion_project_id IS NULL AND p.project_number <> 'PRJ-ORG'
UNION ALL
SELECT 'entries on non-Fusion tasks', COUNT(*)
  FROM oc_ts_entry e
  JOIN oc_time_task t ON t.task_id = e.task_id
 WHERE t.fusion_task_id IS NULL AND t.task_type <> 'COMMON'
UNION ALL
SELECT 'weeks for non-Fusion workers', COUNT(*)
  FROM oc_ts_week w
  JOIN oc_time_worker wk ON wk.employee_id = w.employee_id
 WHERE wk.fusion_person_id IS NULL
UNION ALL
SELECT 'allocations on non-Fusion projects', COUNT(*)
  FROM oc_time_allocation a
  JOIN oc_time_project p ON p.project_id = a.project_id
 WHERE p.fusion_project_id IS NULL AND p.project_number <> 'PRJ-ORG';

PROMPT
PROMPT Anything above zero must be cleared BEFORE the master rows, or the
PROMPT delete either fails on the foreign key or cascades further than intended.

PROMPT
PROMPT ============================================================
PROMPT [5/5] Logins
PROMPT ============================================================

-- The one thing that is deliberately NOT from Fusion. OC_TIME_USER is the
-- module's own sign-in store (section 4) and a production instance needs real
-- users invited into it. What must not survive is the demo password.
--
-- Matched on the hash rather than a name list: anyone who has set their own
-- password has a different hash and is a real account.
SELECT COUNT(*) AS total_users,
       SUM(CASE WHEN u.password_hash =
                     (SELECT RAWTOHEX(STANDARD_HASH(LOWER(u.email)||':Rite@123','SHA256'))
                        FROM dual)
                THEN 1 ELSE 0 END) AS still_on_demo_password,
       SUM(CASE WHEN u.app_role IS NOT NULL THEN 1 ELSE 0 END) AS role_overrides
  FROM oc_time_user u;

PROMPT
PROMPT still_on_demo_password must be 0 in production. role_overrides should be
PROMPT the number of common administrators and nothing more -- OC_TIME_USER.
PROMPT APP_ROLE exists only for the admin who need not be a worker (section 4).

PROMPT
PROMPT ============================================================
PROMPT Reference data — deliberately NOT listed above
PROMPT ============================================================
PROMPT
PROMPT OC_TIME_PERIOD, its cut-offs, OC_TIME_CONFIG and the lookup dictionaries
PROMPT are seeded by 10_seed.sql and have NO Fusion source. They are decisions,
PROMPT not facts about Fusion, and they are required. What they DO need before
PROMPT production is a review of their VALUES:
PROMPT
PROMPT   * OC_TIME_PERIOD covers only the current and next month
PROMPT   * DELIVERY_CUTOFF / FINANCE_CUTOFF / PAYROLL_CUTOFF carry demo dates
PROMPT   * RULE-017 is relaxed -- JUL and AUG are both Open (section 7a)
PROMPT
PROMPT Those are a configuration exercise, not a cleanup.
