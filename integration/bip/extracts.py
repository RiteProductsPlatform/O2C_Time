"""
O2C Time — the six Fusion master-data extracts.

Each entry maps one Fusion source to one O2C_TIME cache table. The SELECT alias
list IS the CSV header and IS the upsert column list, so the three can never
drift apart.

Every object name and every column here was verified against a live Fusion pod
(see integration/bip/README.md). Two corrections worth remembering:

  * shift and work-pattern REFERENCE data lives under HTS_. The PER-WORKER
    ROSTER does not: it is PER_SCHEDULE_ASSIGNMENTS joined to
    ZMM_SR_SCHEDULE_DTLS, with ZMM_SR_SHIFTS_VL as its shift dictionary.

    This note used to say ZMM_SR_* was Service Request scheduling and nothing
    to do with HCM availability. That is wrong on this pod and cost real time:
    WORKER_SHIFTS was rewritten onto the ZMM_SR_* pair in Aug-2026 after
    HTS_WORKERS_WITH_SHIFTS_V returned nothing usable, and HTS_SHIFTS_VL does
    not contain the shift ids those schedules reference. TWO SHIFT
    DICTIONARIES, one id space each -- join the HTS one to a ZMM_SR shift id
    and you get no rows, which reads as missing data rather than a wrong join.
  * HR_ALL_ORGANIZATION_UNITS_F has no NAME column - the name is in the
    translated view HR_ALL_ORGANIZATION_UNITS_F_VL.

All extracts take :P_EFFECTIVE_DATE. The HCM tables are effective-dated (_F/_M),
so without it you get every historical version of every row.
"""

# ── EFFECTIVE-DATE PREDICATE ─────────────────────────────────────────────
# Fusion passes report parameters as strings; TO_DATE keeps the comparison a
# date one rather than an implicit-conversion accident.
# BOTH PARAMETERS ARE OPTIONAL, and that is a requirement, not a convenience.
#
# OC_TIME_SYNC_CONFIG carries exactly ONE value for INT 002 to pass:
# LASTSYNC_DATE. The reports declared TWO binds, and BIP declares every
# parameter with defaultValue="" -- which in Oracle IS NULL. So a report run by
# OIC got P_EFFECTIVE_DATE = NULL, every "NULL BETWEEN x AND y" evaluated
# false, and the extract returned ZERO ROWS WHILE REPORTING SUCCESS. Nine of
# eleven feeds. Exactly the silent-zero this module's docstring warns about,
# and invisible from the sync status.
#
# The NVL defaults make the correct behaviour the DEFAULT behaviour:
#
#   P_EFFECTIVE_DATE unset -> today on the Fusion database
#   P_LAST_SYNC      unset -> 1900, i.e. a full load
#
# Passing either still overrides, so --effective-date and --since keep working
# for pinned, reproducible test runs. But a caller that knows nothing about
# these parameters now gets "everything, as of now", which is the only sane
# reading of no arguments -- and not zero rows.
ED = "NVL(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), TRUNC(SYSDATE))"

# Which projects the module cares about at all.
#
# Decided 03-Aug-2026, and it is a scope rule rather than a technical filter:
#
#   * time tracked  - PJS_TRACK_TIME = 'Y' on an internal party. A project
#     nobody tracks time against does not belong in a timesheet picker. 48 of
#     424 on this pod.
#   * has a manager - a project party in the 'Project Manager' role. RULE-015
#     routes every approval to that person, so a project without one has no
#     approver and its weeks could be submitted and never actioned. 187 of 424.
#
# Applied to PROJECTS, TASKS *and* ALLOCATIONS, not just PROJECTS. Filtering
# only the parent would leave ~10,000 task rows and ~1,500 allocation rows
# pointing at projects that were never loaded — each one failing its FK lookup
# and landing in OC_TIME_SYNC_FAILED. The queue is for problems worth reading,
# and burying it under thousands of by-design rejections would make it useless.
#
# {A} is the alias of the table carrying PROJECT_ID in the query it is used in.
IN_SCOPE = """
   EXISTS (SELECT 1
             FROM pjf_projects_all_b sp
            WHERE sp.project_id = {A}.project_id
              -- Recency lives HERE, not in each extract's own WHERE. The three
              -- used to test different dates for the same idea — the project's
              -- completion date in PROJECTS, the task's in TASKS, the party's
              -- end date in ALLOCATIONS — so a project completed 18 months ago
              -- was dropped from PROJECTS while its still-open tasks sailed
              -- through, and 89 rows failed their FK lookup. One test, one
              -- answer, for all three.
              AND NVL(sp.completion_date, {ED}) >= ADD_MONTHS({ED}, -12)
              AND EXISTS (SELECT 1 FROM pjf_project_parties tp
                           WHERE tp.project_id = sp.project_id
                             AND tp.project_party_type = 'IN'
                             AND tp.pjs_track_time = 'Y')
              AND EXISTS (SELECT 1
                            FROM pjf_project_parties mp
                            JOIN pjt_project_roles_vl mr
                              ON mr.project_role_id = mp.project_role_id
                            JOIN per_all_people_f mpp
                              ON mpp.person_id = mp.resource_source_id
                             AND {ED} BETWEEN mpp.effective_start_date
                                          AND mpp.effective_end_date
                           WHERE mp.project_id = sp.project_id
                             AND mp.project_party_type = 'IN'
                             AND mr.name = 'Project Manager'))
""".replace("{ED}", ED)


WORKERS = {
    "name": "WORKERS",
    "target": "OC_TIME_WORKER",
    "integration": "INT-001",
    "key": ["EMPLOYEE_ID"],
    "columns": ["FUSION_PERSON_ID", "EMPLOYEE_ID", "EMPLOYEE_NAME", "EMAIL",
                "WORKER_TYPE", "BASE_COUNTRY", "STD_HOURS_PER_DAY",
                "MANAGER_EMP_ID", "LEGAL_EMPLOYER", "EXPENDITURE_ORG",
                "HIRE_DATE", "TERMINATION_DATE", "STATUS"],
    "sql": """
-- person_id as well as person_number. OC_TIME_WORKER.FUSION_PERSON_ID has
-- existed since 02_time_master.sql:34 and nothing has ever written to it,
-- because this SELECT took only the number. PersonNumber (RI2894) is a real
-- Fusion key and several REST resources accept it, but /absences and the OTL
-- time-record payloads want the numeric PersonId, and deriving it needs a
-- round trip per person. Carry both -- it costs one column on a query that
-- already joins papf.
-- ONE ROW PER PERSON, taken from the latest period of service.
--
-- Measured 10-Aug-2026: 5991 rows for 5850 people. 140 person numbers appear
-- twice -- REHIRES. per_all_assignments_m holds one primary assignment per
-- PERIOD OF SERVICE, and a rehired person has two; both carry primary_flag='Y'
-- inside their own period and both satisfy the effective-date predicate, so
-- assignment_type IN ('E','C') does not separate them:
--
--   person 300000049306731  hire 2009-01-27  term 2015-02-28  Terminated
--   person 300000049306731  hire 2015-03-01  term (none)      Active
--
-- Two source rows matching one target row is ORA-30926, "unable to get a
-- stable set of rows in the source tables" -- the MERGE refuses rather than
-- pick, correctly, since it cannot know which is current. WORKERS is the
-- parent of allocation and absence, so the whole sync stops there.
--
-- Deduped by window rather than by filtering on assignment_type, because the
-- terminated-assignment codes vary by how the termination was processed and a
-- filter that is subtly wrong DROPS PEOPLE silently. Ordering by period start
-- is true regardless: the newest period of service is the current one, and a
-- genuinely terminated person still has exactly one row and keeps it.
SELECT papf.person_id                                    AS fusion_person_id,
       papf.person_number                                AS employee_id,
       ppnf.display_name                                 AS employee_name,
       LOWER(pea.email_address)                          AS email,
       CASE WHEN paam.system_person_type = 'CWK' THEN 'Contractor'
            ELSE 'Employee' END                          AS worker_type,
       loc.country                                       AS base_country,
       -- NORMAL_HOURS is per FREQUENCY and has to be reduced to a DAILY figure
       -- before it can drive FLD-011 / CFG-013.
       --
       -- Every frequency on the pod is handled, not just weekly. An earlier
       -- version divided 'W' by 5 and passed everything else through raw, which
       -- sent monthly workers through at 186 — nine of them failed the load
       -- with ORA-01438 against STD_HOURS_PER_DAY's NUMBER(4,2).
       --
       -- Observed 02-Aug-2026: W 4,606 (0-53) · null 1,339 · D 34 (8-9) ·
       -- M 9 (186). No 'Y' rows, but it is handled because one hire would
       -- otherwise reintroduce exactly the same failure.
       --
       -- LEAST(...,24) because CHK_OC_TW_STD constrains 0-24 and a bad source
       -- value should land as a clamped number rather than reject the worker
       -- outright — the person still needs to exist to record time.
       LEAST(
         CASE
           WHEN NVL(paam.normal_hours,0) <= 0 THEN 8          -- no data: corporate default
           WHEN paam.frequency = 'D' THEN paam.normal_hours
           WHEN paam.frequency = 'W' THEN ROUND(paam.normal_hours / 5, 2)
           WHEN paam.frequency = 'M' THEN ROUND(paam.normal_hours / 21.67, 2)
           WHEN paam.frequency = 'Y' THEN ROUND(paam.normal_hours / 260, 2)
           ELSE 8                                             -- unknown frequency
         END, 24)                                    AS std_hours_per_day,
       mgr.person_number                                 AS manager_emp_id,
       org.name                                          AS legal_employer,
       -- POET's O, resource-wise: the organization that INCURS the cost.
       -- Deliberately paam.organization_id, NOT legal_entity_id above. The legal
       -- employer is who employs the person; the expenditure organization is the
       -- costing unit the work books to. Fusion treats them as different and on
       -- most pods they are — reading one for the other sends cost to the wrong
       -- place while looking entirely plausible.
       expo.name                                         AS expenditure_org,
       TO_CHAR(pos.date_start,'YYYY-MM-DD')              AS hire_date,
       TO_CHAR(pos.actual_termination_date,'YYYY-MM-DD') AS termination_date,
       CASE WHEN pos.actual_termination_date IS NULL
             OR pos.actual_termination_date >= {ED}
            THEN 'Active' ELSE 'Terminated' END          AS status
  FROM per_all_people_f papf
  JOIN per_all_assignments_m paam
    ON paam.person_id = papf.person_id
   AND paam.primary_flag = 'Y'
   AND paam.assignment_type IN ('E','C')
   AND paam.effective_latest_change = 'Y'
   AND {ED} BETWEEN paam.effective_start_date AND paam.effective_end_date
  JOIN per_person_names_f ppnf
    ON ppnf.person_id = papf.person_id
   AND ppnf.name_type = 'GLOBAL'
   AND {ED} BETWEEN ppnf.effective_start_date AND ppnf.effective_end_date
  -- Work email is the join to the app: getMe looks the worker up by it.
  LEFT JOIN per_email_addresses pea
    ON pea.person_id = papf.person_id AND pea.email_type = 'W1'
  LEFT JOIN per_periods_of_service pos
    ON pos.period_of_service_id = paam.period_of_service_id
  LEFT JOIN hr_locations_all_f loc
    ON loc.location_id = paam.location_id
   AND {ED} BETWEEN loc.effective_start_date AND loc.effective_end_date
  LEFT JOIN hr_all_organization_units_f_vl org
    ON org.organization_id = paam.legal_entity_id
   AND {ED} BETWEEN org.effective_start_date AND org.effective_end_date
  -- Same table, different key: the assignment's own organization rather than
  -- its legal entity. _F_VL because the base _F has no NAME (note 7 below).
  LEFT JOIN hr_all_organization_units_f_vl expo
    ON expo.organization_id = paam.organization_id
   AND {ED} BETWEEN expo.effective_start_date AND expo.effective_end_date
  -- RULE-015 depends on this: a manager's own time is approved by THIS person.
  LEFT JOIN per_assignment_supervisors_f sup
    ON sup.assignment_id = paam.assignment_id
   AND sup.manager_type = 'LINE_MANAGER' AND sup.primary_flag = 'Y'
   AND {ED} BETWEEN sup.effective_start_date AND sup.effective_end_date
  LEFT JOIN per_all_people_f mgr
    ON mgr.person_id = sup.manager_id
   AND {ED} BETWEEN mgr.effective_start_date AND mgr.effective_end_date
 WHERE {ED} BETWEEN papf.effective_start_date AND papf.effective_end_date
   -- Keep only the LATEST period of service, as a correlated NOT EXISTS
   -- rather than a ROW_NUMBER in an outer query.
   --
   -- The wrapper was tried first and broke the extract: the :P_LAST_SYNC delta
   -- predicate is APPENDED to this SQL, so it landed on the outer SELECT where
   -- mgr, sup and expo are out of scope -- ORA-00904 "MGR"."EFFECTIVE_START_DATE".
   -- The delta machinery requires this query stay a single flat SELECT.
   AND NOT EXISTS (
         SELECT 1
           FROM per_all_assignments_m a2
           JOIN per_periods_of_service p2
             ON p2.period_of_service_id = a2.period_of_service_id
          WHERE a2.person_id = papf.person_id
            AND a2.primary_flag = 'Y'
            AND a2.assignment_type IN ('E','C')
            AND a2.effective_latest_change = 'Y'
            AND {ED} BETWEEN a2.effective_start_date AND a2.effective_end_date
            -- Strictly later period, with an id tiebreak so two periods
            -- starting on the SAME day still leave exactly one survivor
            -- rather than silently reintroducing the duplicate.
            AND (NVL(p2.date_start, DATE '1900-01-01')
                   > NVL(pos.date_start, DATE '1900-01-01')
              OR (NVL(p2.date_start, DATE '1900-01-01')
                   = NVL(pos.date_start, DATE '1900-01-01')
                 AND a2.assignment_id > paam.assignment_id)))
""".replace("{ED}", ED),
}


PROJECTS = {
    "name": "PROJECTS",
    "target": "OC_TIME_PROJECT",
    "integration": "INT-002",
    "key": ["PROJECT_NUMBER"],
    "columns": ["FUSION_PROJECT_ID", "PROJECT_NUMBER", "PROJECT_NAME", "PROJECT_TYPE",
                "CUSTOMER_NAME", "STATUS", "PROJECT_START_DATE", "PROJECT_END_DATE",
                "ORGANIZATION", "PROJECT_MANAGER_ID", "TIME_ENTRY_ENABLED"],
    "sql": """
-- Fusion's id. NOT our PROJECT_ID -- that is a local identity key.
SELECT p.project_id                            AS fusion_project_id,
       p.segment1                              AS project_number,
       ptl.name                                AS project_name,
       -- 'Billable', a LITERAL. OC_TIME_PROJECT.PROJECT_TYPE is not Fusion's
       -- project type -- it is a two-value flag, CHK_OC_TPRJ_TYPE
       -- ('Billable','Organization'), identifying ONE special project: PRJ-ORG,
       -- the Organization (Non-Billable) project implicitly assigned to every
       -- employee (FLD-006). PRJ-ORG is seeded by 10_seed.sql and does not
       -- exist in Fusion, so nothing the sync brings back can ever be it.
       --
       -- Sending pt.project_type raw failed with ORA-12899: Fusion's values run
       -- to 29 characters against a VARCHAR2(20). Widening the column would
       -- have moved the failure to ORA-02290 on the CHECK, which is the more
       -- honest error -- the value was never in the domain, only too long to
       -- fit while being wrong.
       'Billable'                              AS project_type,
       cust.party_name                         AS customer_name,
       -- Mapped, not passed through. CHK_OC_TPRJ_STAT allows
       -- ('Active','Closed','On Hold') and project_status_code is a Fusion
       -- code -- CLOSED, PENDING_CLOSE, ON_HOLD and others. The same defect as
       -- PROJECT_TYPE above and it would have surfaced the moment that one was
       -- fixed.
       --
       -- Unknown codes fall to 'Active' deliberately: the extract already
       -- filters to projects that track time and have a manager, so a project
       -- reaching here is one people book against. Hiding it because its status
       -- code is unfamiliar loses time entry; showing it does not.
       CASE
         WHEN UPPER(p.project_status_code) LIKE '%CLOSE%' THEN 'Closed'
         WHEN UPPER(p.project_status_code) LIKE '%HOLD%'  THEN 'On Hold'
         ELSE 'Active'
       END                                     AS status,
       TO_CHAR(p.start_date,'YYYY-MM-DD')      AS project_start_date,
       TO_CHAR(p.completion_date,'YYYY-MM-DD') AS project_end_date,
       org.name                                AS organization,
       -- The project manager. CrewRite routes approval to a crew lead; here it
       -- is the project manager, and RULE-015 depends on it — an employee's
       -- week goes to THIS person. Without it PROJECT_MANAGER_ID stays null, no
       -- project has an approver, and the manager landing page is empty for
       -- everyone. 366 of 732 projects on this pod have one.
       --
       -- A SCALAR SUBQUERY, not a join, and that is deliberate: a project can
       -- carry the same role more than once over time, and a join would emit
       -- one project row per party — silently duplicating projects into a MERGE
       -- keyed on project_number.
       --
       -- Exact match on 'Project Manager'. A LIKE '%PROJECT MANAGER%' also
       -- catches 'Associate Project Manager', which is a different person and a
       -- different authority.
       (SELECT MIN(pm.person_number)
          FROM pjf_project_parties mpp
          JOIN pjt_project_roles_vl r
            ON r.project_role_id = mpp.project_role_id
          JOIN per_all_people_f pm
            ON pm.person_id = mpp.resource_source_id
           AND {ED} BETWEEN pm.effective_start_date AND pm.effective_end_date
         WHERE mpp.project_id = p.project_id
           AND mpp.project_party_type = 'IN'
           AND r.name = 'Project Manager'
           AND {ED} BETWEEN NVL(mpp.start_date_active, {ED})
                        AND NVL(mpp.end_date_active,   {ED}))
                                               AS project_manager_id,
       -- TIME_ENTRY_ENABLED (CrewRite CR-B-BR08, Reuse Assessment §2.4).
       -- Without a filter every active project in the enterprise reaches the
       -- employee's picker: 732 here.
       --
       -- PJS_TRACK_TIME on the project party is Fusion's OWN answer to this, so
       -- it beats deriving one. On this pod it selects 55 projects — the ones
       -- somebody actually tracks time against. An earlier version guessed "has
       -- any internal party", which would have let 327 through.
       CASE WHEN EXISTS (SELECT 1 FROM pjf_project_parties tp
                          WHERE tp.project_id = p.project_id
                            AND tp.project_party_type = 'IN'
                            AND tp.pjs_track_time = 'Y')
            THEN 'Y' ELSE 'N' END              AS time_entry_enabled
  FROM pjf_projects_all_b p
  JOIN pjf_projects_all_tl ptl
    ON ptl.project_id = p.project_id AND ptl.language = USERENV('LANG')
  -- PROJECT_TYPE is on the _TL, not the _B.
  LEFT JOIN pjf_project_types_tl pt
    ON pt.project_type_id = p.project_type_id AND pt.language = USERENV('LANG')
  LEFT JOIN hr_all_organization_units_f_vl org
    ON org.organization_id = p.carrying_out_organization_id
   AND {ED} BETWEEN org.effective_start_date AND org.effective_end_date
  -- Customer comes through the project party. The party type code is 'CO'
  -- (customer); 'IN' is an internal team member. A project has many parties, so
  -- the type filter is what keeps this one row.
  LEFT JOIN pjf_project_parties cpp
    ON cpp.project_id = p.project_id AND cpp.project_party_type = 'CO'
  LEFT JOIN hz_parties cust
    ON cust.party_id = cpp.resource_source_id
 WHERE {IN_SCOPE}
""".replace("{IN_SCOPE}", IN_SCOPE.replace("{A}", "p")).replace("{ED}", ED),
}


TASKS = {
    "name": "TASKS",
    "target": "OC_TIME_TASK",
    "integration": "INT-002",
    # Must be the key the MERGE matches on, not merely a unique one. The DB
    # merges on (PROJECT_ID, TASK_CODE) -- UK_OC_TTSK_WBS. If two extract rows
    # share a (project, code) with different Fusion ids, this check passes,
    # and the MERGE then fails with ORA-30926 "unable to get a stable set of
    # rows in the source tables" -- which names neither the report nor the
    # duplicate. Catching it here says which rows, at extract time.
    "key": ["PROJECT_NUMBER", "TASK_CODE"],
    "columns": ["FUSION_TASK_ID", "FUSION_PROJECT_ID", "PROJECT_NUMBER", "TASK_CODE",
                "TASK_NAME", "CHARGEABLE_FLAG", "BILLABLE_TYPE",
                "WBS_LEVEL", "PARENT_TASK_ID", "START_DATE", "END_DATE",
                "EXPENDITURE_TYPE"],
    "sql": """
-- Fusion's ids. TASK_ID and PROJECT_ID on OC_TIME_TASK are LOCAL keys.
SELECT e.proj_element_id                        AS fusion_task_id,
       e.project_id                             AS fusion_project_id,
       p.segment1                               AS project_number,
       e.element_number                         AS task_code,
       etl.name                                 AS task_name,
       -- RULE-010: only a chargeable task may appear in the grid's task LOV.
       NVL(e.chargeable_flag,'N')               AS chargeable_flag,
       CASE WHEN NVL(e.billable_flag,'N') = 'Y'
            THEN 'Billable' ELSE 'Non-billable' END  AS billable_type,
       e.denorm_wbs_level                       AS wbs_level,
       e.denorm_parent_element_id               AS parent_task_id,
       TO_CHAR(e.start_date,'YYYY-MM-DD')       AS start_date,
       TO_CHAR(e.completion_date,'YYYY-MM-DD')  AS end_date,
       -- POET's E. Deliberately NULL here, not omitted.
       --
       -- The column has to exist because it is part of this extract's contract
       -- with POST sync/task, and the loader sends what the contract declares.
       -- It is null because expenditure type is not an attribute of the task in
       -- Fusion — it comes from transaction controls, which TASK_EXP_TYPES
       -- reads and which nobody has yet confirmed this pod uses.
       --
       -- Harmless meanwhile: sync/task applies
       -- NVL(payload, existing), so a null never erases a value already set.
       CAST(NULL AS VARCHAR2(80))               AS expenditure_type
  FROM pjf_proj_elements_b e
  JOIN pjf_proj_elements_tl etl
    ON etl.proj_element_id = e.proj_element_id AND etl.language = USERENV('LANG')
  JOIN pjf_projects_all_b p
    ON p.project_id = e.project_id
 WHERE e.object_type = 'PJF_TASKS'   -- plural; 'PJF_TASK' matches nothing
   AND {IN_SCOPE}
""".replace("{IN_SCOPE}", IN_SCOPE.replace("{A}", "e")).replace("{ED}", ED),
}


ALLOCATIONS = {
    "name": "ALLOCATIONS",
    "target": "OC_TIME_ALLOCATION",
    "integration": "INT-003",
    # FUSION_PROJECT_ID, never PROJECT_ID. This used to emit Fusion's project id
    # under the alias PROJECT_ID -- the exact name of the LOCAL surrogate
    # foreign key OC_TIME_ALLOCATION.PROJECT_ID. The loader matched the name,
    # took it as an ordinary column, and its foreign-key resolution then found
    # the column already populated and skipped itself. Fusion's
    # 300000337787982 went at the local FK: ORA-02291 on a good day, and a
    # silent attachment to the WRONG project on a bad one.
    #
    # TASKS never had this because it aliases to FUSION_PROJECT_ID (see below).
    # The local id is resolved from PROJECT_NUMBER by FK_LOOKUP_SQL; the Fusion
    # id is KEPT, in its own column, because the OTL push (INT-007) has to name
    # the project back to Fusion and cannot do that with our 376.
    "key": ["PROJECT_NUMBER", "EMPLOYEE_ID"],
    "columns": ["FUSION_PROJECT_ID", "PROJECT_NUMBER", "EMPLOYEE_ID",
                "START_DATE", "END_DATE", "ALLOC_PCT", "CAP_HOURS",
                "TRACK_TIME_FLAG", "STATUS"],
    "sql": """
-- One row per project x employee. Both sides need collapsing first, and
-- skipping either produces duplicates that violate UK_OC_TAL_ASSIGN:
--
--   * PJF_PROJECT_PARTIES holds MORE THAN ONE row per (project, person) -
--     re-assignment over time, ~1000 cases on a demo pod. The outer GROUP BY
--     reduces them to one span, earliest start to latest end.
--   * PJR_ASSIGNMENT holds several concurrent assignments per (project,
--     resource), so joining it raw fans 5,000 parties out to 14,500 rows. The
--     inline aggregate collapses it BEFORE the join.
--
-- BILLABLE_PERCENT is SUMmed, not MAXed: a person can hold two concurrent
-- assignments on one project and RULE-001 cares about their combined load.
SELECT pp.project_id                                   AS fusion_project_id,
       prj.segment1                                    AS project_number,
       papf.person_number                              AS employee_id,
       -- NVL, because START_DATE is NOT NULL and a project party need not have
       -- a stated start: ORA-01400 on the whole ALLOCATIONS load. An allocation
       -- with no start of its own began when the PROJECT did, which is both
       -- true and useful -- populate_month tests the allocation's span against
       -- the period, so an epoch fallback would make every such person look
       -- allocated since 1900.
       TO_CHAR(NVL(MIN(pp.start_date_active),
                   NVL(MIN(prj.start_date), DATE '1900-01-01')),
               'YYYY-MM-DD')                            AS start_date,
       TO_CHAR(MAX(pp.end_date_active),'YYYY-MM-DD')   AS end_date,
       -- NVL, because the DEFAULT cannot save this. ALLOC_PCT is NOT NULL
       -- DEFAULT 100 (02_time_master.sql:219), but a column DEFAULT applies
       -- only when the INSERT OMITS the column -- the loader always names
       -- every column and passes an explicit NULL, which is ORA-01400. The
       -- LEFT JOIN to pjr_assignment misses for any party with no resource
       -- assignment, which is most of them.
       --
       -- 100 is the right fallback: a project party with no assignment row is
       -- on the project without a stated split, and RULE-001 should see them
       -- at full load rather than at zero (which CHK_OC_TAL_PCT rejects too,
       -- since it requires alloc_pct > 0).
       -- LEAST(...,100) because CHK_OC_TAL_PCT requires 0 < pct <= 100 and the
       -- SUM below can exceed it when somebody holds two concurrent rows on
       -- one project. Capping loads the row; not capping fails that person's
       -- whole allocation with ORA-02290 and tells nobody why.
       LEAST(NVL(MAX(asg.alloc_pct), 100), 100)        AS alloc_pct,
       MAX(asg.hours_per_day)                          AS cap_hours,
       MAX(pp.pjs_track_time)                          AS track_time_flag,
       -- 'Ended', NOT 'Inactive'. CHK_OC_TAL_STATUS allows only
       -- ('Active','Ended') -- db/02_time_master.sql:235 -- so 'Inactive'
       -- fails ORA-02290 on every allocation whose end date has passed. The
       -- word differs from the WORKERS feed's Active/Inactive on purpose:
       -- these are two different column domains, not one shared vocabulary.
       CASE WHEN MAX(NVL(pp.end_date_active, DATE '4712-12-31')) >= {ED}
            THEN 'Active' ELSE 'Ended' END             AS status
  FROM pjf_project_parties pp
  JOIN pjf_projects_all_b prj
    ON prj.project_id = pp.project_id
  JOIN per_all_people_f papf
    ON papf.person_id = pp.resource_source_id
   AND {ED} BETWEEN papf.effective_start_date AND papf.effective_end_date
  -- PJT_PROJECT_RESOURCE, NOT PJR_ASSIGNMENT, and that difference is the whole
  -- reason every allocation used to arrive at 100%.
  --
  -- This read PJR_ASSIGNMENT.BILLABLE_PERCENT, which is a Project Resource
  -- MANAGEMENT record, created by staffing a resource request. Our projects
  -- have none: measured 17-Aug-2026, PJR_ASSIGNMENT holds 4,289 rows across
  -- 120 projects and ZERO for 444, 555 or PCS10034. So the LEFT JOIN never
  -- matched, NVL(...,100) answered for everybody, and the feed carried exactly
  -- one distinct value -- 100 -- which reads as data rather than as a
  -- fallback. Setting real percentages in PPM changed nothing, twice.
  --
  -- The number on the "Manage Project Resources" cards is PROJECT TEAM
  -- membership and lands in PJT_PROJECT_RESOURCE.ALLOCATION. Confirmed against
  -- the screen: RI2824 shows 50 on 444, 25 on 555, 25 on PCS10034, and the
  -- table holds exactly those three.
  --
  -- Joined on PERSON_ID, not RESOURCE_ID. The party's RESOURCE_ID is a
  -- resource-management key, and using it is what made the old join miss even
  -- on projects that did have assignments.
  --
  -- SUM as before: two concurrent rows on one project are a combined load and
  -- RULE-001 cares about the total. Capped at the SELECT above.
  LEFT JOIN (SELECT project_id,
                    person_id,
                    SUM(allocation)       AS alloc_pct,
                    MAX(hours_per_day)    AS hours_per_day,
                    -- Exposed so the incremental predicate can reach it.
                    -- Without this, changing only a percentage moves no date
                    -- the delta looks at and the change is never picked up.
                    MAX(last_update_date) AS last_update_date
               FROM pjt_project_resource
              WHERE {ED} BETWEEN NVL(start_date_active, {ED})
                             AND NVL(end_date_active,   {ED})
              GROUP BY project_id, person_id) asg
    ON asg.project_id = pp.project_id
   AND asg.person_id  = pp.resource_source_id
 WHERE pp.project_party_type = 'IN'   -- internal team member ('CO' = customer)
   AND {IN_SCOPE}
 GROUP BY pp.project_id, prj.segment1, papf.person_number
""".replace("{IN_SCOPE}", IN_SCOPE.replace("{A}", "pp")).replace("{ED}", ED),
}


ABSENCES = {
    "name": "ABSENCES",
    "target": "OC_TIME_ABSENCE",
    "integration": "INT-006",
    "key": ["EMPLOYEE_ID", "ABSENCE_DATE", "ABSENCE_TYPE"],
    "columns": ["EMPLOYEE_ID", "ABSENCE_DATE", "ABSENCE_TYPE", "ABSENCE_HOURS",
                "APPROVAL_STATUS", "ABSENCE_STATUS"],
    "sql": """
-- ONE ROW PER DAY, GENERATED FROM THE HEADER'S DATE RANGE.
--
-- This used to INNER JOIN anc_per_abs_entry_dtls for its day-level rows, on the
-- reasonable assumption that a multi-day absence is stored as one detail row
-- per day. It is not, and the table is mostly empty: measured 17-Aug-2026 on
-- this pod, 8,922 absence headers exist and only 988 have ANY detail row --
-- 7,934 of them, 89%, have none at all. The inner join silently discarded every
-- one of those, so the feed returned 4 rows out of thousands and absence
-- reached the timesheet for almost nobody.
--
-- Nothing about that looked broken: the extract ran clean, the sync reported
-- Success, and a person with no leave is indistinguishable from a person whose
-- leave was dropped. It surfaced only when a real absence was booked on a known
-- person and never appeared.
--
-- So the header is the source of truth for WHICH DAYS, and the detail is
-- consulted only for hours where it happens to exist. The generator is capped
-- at 366 -- an absence longer than a year is not a timesheet problem.
-- AGGREGATED TO THE KEY, which the day expansion above made necessary.
-- OC_TIME_ABSENCE is unique on (employee, date, type) -- UK_OC_TABS_DAY -- and
-- Fusion happily holds the same absence type over the same date more than
-- once: measured 17-Aug-2026, 3,409 keys appeared twice or three times out of
-- 3,977, and the duplicate rows were IDENTICAL in every column. Mostly
-- 'Holiday UK' recorded repeatedly. Without this the load fails 6,806 rows on
-- the unique key, or upserts each over the last depending on the loader.
SELECT papf.person_number                     AS employee_id,
       TO_CHAR(x.absence_date,'YYYY-MM-DD')   AS absence_date,
       t.name                                 AS absence_type,
       -- NULL when there is no detail row. The loader falls back to the
       -- worker's own STD_HOURS_PER_DAY rather than this extract inventing an
       -- 8-hour day for people who do not work one. MAX, not SUM: two records
       -- for one day are the same day recorded twice, not sixteen hours.
       MAX(d.duration)                        AS absence_hours,
       MAX(x.approval_status_cd)              AS approval_status,
       -- Carried so a WITHDRAWN absence is distinguishable from an approved
       -- one. A withdrawn entry may also vanish from the header table outright,
       -- which the loader's retraction pass handles separately.
       --
       -- WITHDRAWN ONLY IF EVERY CONTRIBUTING RECORD IS. If one of two
       -- overlapping records is withdrawn and the other stands, the person is
       -- still absent. Written out rather than left to MAX(), which happens to
       -- give the right answer here purely because 'SUBMITTED' sorts after
       -- 'ORA_WITHDRAWN' -- true today and not a reason.
       CASE WHEN COUNT(CASE WHEN UPPER(NVL(x.absence_status_cd,'X'))
                                 NOT LIKE '%WITHDRAWN%' THEN 1 END) > 0
            THEN 'SUBMITTED' ELSE 'ORA_WITHDRAWN' END AS absence_status
  FROM (SELECT e.per_absence_entry_id,
               e.person_id,
               e.absence_type_id,
               e.approval_status_cd,
               e.absence_status_cd,
               e.last_update_date,
               e.start_date + gen.n           AS absence_date
          FROM anc_per_abs_entries e
          CROSS JOIN (SELECT LEVEL - 1 AS n FROM dual
                       CONNECT BY LEVEL <= 366) gen
         WHERE gen.n <= (e.end_date - e.start_date)) x
  LEFT JOIN anc_per_abs_entry_dtls d
    ON d.per_absence_entry_id = x.per_absence_entry_id
   AND d.absence_date         = x.absence_date
  JOIN per_all_people_f papf
    ON papf.person_id = x.person_id
   AND x.absence_date BETWEEN papf.effective_start_date AND papf.effective_end_date
  LEFT JOIN anc_absence_types_vl t
    ON t.absence_type_id = x.absence_type_id
 WHERE x.approval_status_cd = 'APPROVED'
   AND x.absence_date >= ADD_MONTHS({ED}, -12)
   AND x.absence_date <  ADD_MONTHS({ED},   3)
 GROUP BY papf.person_number, TO_CHAR(x.absence_date,'YYYY-MM-DD'), t.name
""".replace("{ED}", ED),
}


CALENDAR = {
    "name": "CALENDAR",
    "target": "OC_TIME_CALENDAR",
    "integration": "INT-004 / INT-005",
    "key": ["LAYER", "SCOPE_KEY", "CAL_DATE"],
    "columns": ["LAYER", "SCOPE_KEY", "CAL_DATE", "IS_WORKING_DAY",
                "HOLIDAY_NAME", "SHIFT_CODE", "STD_HOURS"],
    "sql": """
-- CORPORATE layer only: public holidays from HCM calendar events, expanded to
-- one row per day. PROJECT / CLIENT / SHIFT layers are loaded separately -
-- OC_TIME_CALENDAR resolves them by precedence (SHIFT 4 > CLIENT 3 >
-- PROJECT 2 > CORPORATE 1).
SELECT 'CORPORATE'                                       AS layer,
       NVL(ce.short_code,'GLOBAL')                       AS scope_key,
       TO_CHAR(TRUNC(ce.start_date_time) + lvl.n,'YYYY-MM-DD') AS cal_date,
       'N'                                               AS is_working_day,
       ce.short_code                                     AS holiday_name,
       CAST(NULL AS VARCHAR2(20))                        AS shift_code,
       0                                                 AS std_hours
  FROM per_calendar_events ce
  CROSS JOIN (SELECT LEVEL - 1 AS n FROM dual CONNECT BY LEVEL <= 30) lvl
 WHERE ce.category = 'PH'   -- public holiday
   AND TRUNC(ce.start_date_time) + lvl.n <= TRUNC(ce.end_date_time)
   AND TRUNC(ce.start_date_time) + lvl.n >= ADD_MONTHS({ED}, -3)
   AND TRUNC(ce.start_date_time) + lvl.n <  ADD_MONTHS({ED}, 12)
""".replace("{ED}", ED),
}


SHIFTS = {
    "name": "SHIFTS",
    "target": "OC_TIME_CALENDAR (SHIFT layer)",
    "integration": "INT-004",
    "key": ["SHIFT_CODE"],
    "columns": ["SHIFT_CODE", "SHIFT_NAME", "WORK_DURATION", "BREAK_DURATION",
                "SHIFT_CATEGORY", "ACTIVE_FLAG"],
    "sql": """
-- RULE-011: shift is display-only, one per day. This is the reference list;
-- the per-worker assignment comes from HTS_WORKERS_WITH_SHIFTS_V.
SELECT s.shift_code      AS shift_code,
       s.shift_name      AS shift_name,
       s.work_duration   AS work_duration,
       s.break_duration  AS break_duration,
       s.shift_category  AS shift_category,
       s.active_flag     AS active_flag
  FROM hts_shifts_vl s
 WHERE 1 = 1
   -- ACCEPTED AND DELIBERATELY UNUSED, so that all eleven reports take the
   -- SAME TWO PARAMETERS and INT 002 needs no per-report mapping. Without it
   -- this report declares one parameter and the other nine declare two, and
   -- OIC has to know which is which.
   --
   -- HTS_SHIFTS_VL is not effective-dated -- it carries last_update_date and
   -- nothing else -- so there is no honest as-of predicate to write. Rather
   -- than invent one, the bind is referenced where it cannot change the
   -- result: {ED} is NVL(TO_DATE(...), TRUNC(SYSDATE)), non-null by
   -- construction, so this is always true.
   --
   -- Not purely decorative. A MALFORMED P_EFFECTIVE_DATE now raises ORA-01861
   -- here exactly as it does on the other nine, rather than being silently
   -- ignored by these two alone -- a bad parameter fails the same way
   -- everywhere instead of only on some reports.
   AND {ED} IS NOT NULL
""".replace("{ED}", ED),
}


# ── Fusion availability: the four objects the CORPORATE/SHIFT layers need ──
#
# Together these replace the Mon-Fri baseline that 10_seed.sql fabricates.
# Fusion models availability in four parts, and OC_TIME_CALENDAR needs all of
# them to resolve a day:
#
#   work shift     HTS_SHIFTS_VL              the catalogue of shift definitions
#   work pattern   HTS_WORK_PATTERNS_VL       which shift falls on which day of
#                  + HTS_WORK_PATTERN_SHIFTS  a repeating cycle
#   work schedule  PER_SCHEDULE_ASSIGNMENTS   which worker is on which schedule
#   work calendar  PER_CALENDAR_EVENTS        public holidays that override it
#
# WORKER_SHIFTS is the resolved output and the one that actually populates the
# SHIFT layer - Fusion has already expanded pattern x schedule into concrete
# person x date x shift rows, so there is no need to re-derive the cycle.

WORK_PATTERNS = {
    "name": "WORK_PATTERNS",
    "target": "OC_TIME_CALENDAR (pattern reference)",
    "integration": "INT-004",
    "key": ["WORK_PATTERN_ID", "DAY_INDEX"],
    "columns": ["WORK_PATTERN_ID", "WORK_PATTERN_NAME", "REPEAT_CYCLE",
                "REPEAT_NUM", "DAY_INDEX", "SHIFT_ID", "SHIFT_NAME",
                "DURATION", "BREAK_DURATION"],
    "sql": """
-- DAY_INDEX is the position within the repeat cycle, not a weekday: a 4-on
-- 3-off pattern has DAY_INDEX 1..7 that does not line up with Mon..Sun. A day
-- absent from this list is a non-working day in that pattern.
SELECT wp.work_pattern_id      AS work_pattern_id,
       wp.work_pattern_name    AS work_pattern_name,
       wp.repeat_cycle         AS repeat_cycle,
       wp.repeat_num           AS repeat_num,
       wps.day_index           AS day_index,
       wps.shift_id            AS shift_id,
       sh.shift_name           AS shift_name,
       wps.duration            AS duration,
       wps.break_duration      AS break_duration
  FROM hts_work_patterns_vl wp
  LEFT JOIN hts_work_pattern_shifts wps
    ON wps.work_pattern_id = wp.work_pattern_id
  LEFT JOIN hts_shifts_vl sh
    ON sh.shift_id = wps.shift_id
 WHERE NVL(wp.template_flag,'N') = 'N'
   -- ACCEPTED AND DELIBERATELY UNUSED, so that all eleven reports take the
   -- SAME TWO PARAMETERS and INT 002 needs no per-report mapping. Without it
   -- this report declares one parameter and the other nine declare two, and
   -- OIC has to know which is which.
   --
   -- HTS_WORK_PATTERNS_VL is not effective-dated -- it carries last_update_date and
   -- nothing else -- so there is no honest as-of predicate to write. Rather
   -- than invent one, the bind is referenced where it cannot change the
   -- result: {ED} is NVL(TO_DATE(...), TRUNC(SYSDATE)), non-null by
   -- construction, so this is always true.
   --
   -- Not purely decorative. A MALFORMED P_EFFECTIVE_DATE now raises ORA-01861
   -- here exactly as it does on the other nine, rather than being silently
   -- ignored by these two alone -- a bad parameter fails the same way
   -- everywhere instead of only on some reports.
   AND {ED} IS NOT NULL
""".replace("{ED}", ED),
}


WORK_SCHEDULES = {
    "name": "WORK_SCHEDULES",
    "target": "OC_TIME_CALENDAR (schedule assignment)",
    "integration": "INT-004",
    "key": ["EMPLOYEE_ID", "SCHEDULE_ID", "START_DATE"],
    "columns": ["EMPLOYEE_ID", "SCHEDULE_ID", "RESOURCE_TYPE", "START_DATE",
                "END_DATE", "PRIMARY_FLAG"],
    "sql": """
-- Which worker follows which schedule, and when.
--
-- RESOURCE_TYPE is 'ASSIGN' | 'DEP' | 'LEGALEMP' - there is no 'PERSON'. And
-- for 'ASSIGN' the RESOURCE_ID is an ASSIGNMENT_ID, not a PERSON_ID, so joining
-- it straight to PER_ALL_PEOPLE_F matches nothing at all. It has to go through
-- the assignment.
--
-- 'DEP' and 'LEGALEMP' assign a schedule to a whole department or legal
-- employer. They are deliberately excluded here: those are org-wide defaults
-- that belong to the CORPORATE layer, whereas this feeds the per-worker one.
SELECT papf.person_number                       AS employee_id,
       sa.schedule_id                           AS schedule_id,
       sa.resource_type                         AS resource_type,
       TO_CHAR(sa.start_date,'YYYY-MM-DD')      AS start_date,
       TO_CHAR(sa.end_date,'YYYY-MM-DD')        AS end_date,
       NVL(sa.primary_flag,'N')                 AS primary_flag
  FROM per_schedule_assignments sa
  JOIN per_all_assignments_m paam
    ON paam.assignment_id = sa.resource_id
   AND paam.effective_latest_change = 'Y'
   AND {ED} BETWEEN paam.effective_start_date AND paam.effective_end_date
  JOIN per_all_people_f papf
    ON papf.person_id = paam.person_id
   AND {ED} BETWEEN papf.effective_start_date AND papf.effective_end_date
 WHERE sa.resource_type = 'ASSIGN'
   AND NVL(sa.end_date, {ED}) >= ADD_MONTHS({ED}, -12)
""".replace("{ED}", ED),
}


WORKER_SHIFTS = {
    "name": "WORKER_SHIFTS",
    "target": "OC_TIME_CALENDAR (SHIFT layer)",
    "integration": "INT-004",
    "key": ["SCOPE_KEY", "CAL_DATE"],
    # PATTERN_NAME, not SHIFT_CODE. The alias IS the target column for the OIC
    # XML loader, so renaming it here is what moves the value into the new
    # column -- and leaves SHIFT_CODE meaning a shift, which the SHIFTS
    # reference feed still loads.
    "columns": ["LAYER", "SCOPE_KEY", "CAL_DATE", "IS_WORKING_DAY",
                "PATTERN_NAME"],
    "sql": """
-- The SHIFT layer: which days each worker is rostered on.
--
-- REWRITTEN 16-Aug-2026, AND THE OLD SOURCE WAS THE WRONG PRODUCT.
--
-- This used to read HTS_SCHEDULE_SHIFTS_VL. That is Workforce Scheduling,
-- and it returned 2,094 rows for 63 Vision demo workers with nothing after
-- 12-Jul, no matter what the extract asked for. Two people given a real Work
-- Schedule Assignment in HCM produced ZERO rows -- so the sync ran, loaded
-- cleanly, reported success and delivered nothing, which is the worst shape a
-- fault can take.
--
-- The Work Schedule Assignment page writes PER_SCHEDULE_ASSIGNMENTS, and the
-- schedule is resolved into dated rows in ZMM_SR_SCHEDULE_DTLS. Verified
-- against the pod: schedule 300000340161641 returns Sun-Thu with a shift and
-- Friday with none, which is exactly the assignment as configured.
--
-- RESOURCE_TYPE 'ASSIGN' carries an ASSIGNMENT_ID in RESOURCE_ID, not a
-- PERSON_ID, so it has to go through PER_ALL_ASSIGNMENTS_M. 'DEP' and
-- 'LEGALEMP' assign a schedule to a whole department or legal employer and are
-- excluded -- those are org defaults belonging to the CORPORATE layer.
--
-- IS_WORKING_DAY IS REAL HERE, unlike the old source which only ever said 'Y'.
-- A row with no SHIFT_ID is an explicit day off, which is how Friday arrives.
--
-- TWO THINGS THIS DOES NOT CARRY, both deliberate:
--
--   STD_HOURS IS NOT SENT AT ALL. START_DATE_TIME to END_DATE_TIME spans the
--   whole day -- measured at 24 hours for a working day and 48 for a Fri+Sat
--   off-block -- so it is a period, not a shift length. The shift's real
--   duration lives in the ZMM definitions, and our shift id appears in none of
--   HTS_SHIFTS_VL's 64 rows.
--
--   Omitting the column beats sending NULL. The loader only touches columns
--   present in BOTH the XML and the table, so a column the report does not
--   send keeps whatever it already had -- which preserves the real hours on
--   the 63 rows the old feed loaded, instead of blanking them. New rows get
--   NULL, and resolve_day's NVL(std_hours, v_std) falls back to the worker's
--   own STD_HOURS_PER_DAY, which is the right default anyway.
--
--   A multi-day off-block only marks its FIRST day. Friday's row covers Friday
--   and Saturday, so Saturday arrives with no row at all. resolve_day handles
--   that: a day missing from a week the person is rostered in counts as
--   non-working.
SELECT 'SHIFT'                                          AS layer,
       papf.person_number                               AS scope_key,
       TO_CHAR(TRUNC(d.start_date_time),'YYYY-MM-DD')   AS cal_date,
       -- MAX over the day, and 'Y' sorts above 'N' -- so a date with any
       -- rostered shift is a working day even if another row on it is blank.
       -- Grouping by SHIFT_ID instead produced 38,442 duplicate keys and the
       -- MERGE would have raised ORA-30926: a person can hold more than one
       -- schedule assignment, and a date more than one detail row.
       MAX(CASE WHEN d.shift_id IS NULL THEN 'N' ELSE 'Y' END) AS is_working_day,
       -- THE PATTERN, not the shift, and not the shift's id.
       --
       -- This was TO_CHAR(MAX(d.shift_id)) and PAGE-001 duly displayed
       -- "300000265863352". Resolving it to the SHIFT name ("8 hours a day")
       -- was still the wrong answer: in Fusion terms a SHIFT is the standard
       -- hours for a day and varies by location, while what the timesheet is
       -- describing -- which days of the week somebody works -- is the
       -- PATTERN. "O2C Sunday to Thursday" is the useful fact; "8 hours a day"
       -- restates STD_HOURS_PER_DAY, which the worker row already carries.
       --
       -- It is also the wrong GRAIN. A pattern belongs to the week, not the
       -- day, so this value repeats across the seven days of a week and the UI
       -- shows it once at week level rather than seven times in a strip.
       --
       -- LISTAGG rather than MAX because a schedule may rotate: 94 patterns
       -- across 111 schedules on this pod, up to 3 on one schedule. Both O2C
       -- schedules hold exactly one, so this is a single name today. Where a
       -- schedule really does rotate, naming all of its patterns is honest --
       -- picking one would assert a rotation position nothing here computes.
       LISTAGG(DISTINCT pt.pattern_name, ' / ')
               WITHIN GROUP (ORDER BY pt.pattern_name)  AS pattern_name
  FROM per_schedule_assignments sa
  JOIN per_all_assignments_m paam
    ON paam.assignment_id = sa.resource_id
   AND paam.effective_latest_change = 'Y'
   AND {ED} BETWEEN paam.effective_start_date AND paam.effective_end_date
  JOIN per_all_people_f papf
    ON papf.person_id = paam.person_id
   AND {ED} BETWEEN papf.effective_start_date AND papf.effective_end_date
  JOIN zmm_sr_schedule_dtls d
    ON d.schedule_id = sa.schedule_id
   AND TRUNC(d.start_date_time) >= sa.start_date
   AND TRUNC(d.start_date_time) <= NVL(sa.end_date, DATE '4712-12-31')
  -- The PATTERN behind the schedule. Joined from the schedule, not from the
  -- day: a pattern is a weekly shape, and ZMM_SR_SCHEDULE_PATTERNS is where a
  -- schedule states which one(s) it is built from.
  --
  -- Both LEFT. A schedule with no pattern rows, or a day with no shift, must
  -- still produce its IS_WORKING_DAY answer above -- that is the column the
  -- roster logic actually depends on, and losing a row to an inner join here
  -- would turn a rostered day into a silent gap.
  LEFT JOIN zmm_sr_schedule_patterns sp
    ON sp.schedule_id = sa.schedule_id
  LEFT JOIN zmm_sr_patterns_vl pt
    ON pt.pattern_id = sp.pattern_id
 WHERE sa.resource_type = 'ASSIGN'
   -- ONE SCHEDULE ASSIGNMENT PER PERSON, chosen -- not "the one flagged
   -- primary", which is what this used to say.
   --
   -- The intent was right: two schedules would contribute a row per schedule
   -- per day and could disagree about whether somebody is working. But
   -- NVL(sa.primary_flag,'N') = 'Y' also silently drops anyone whose single
   -- assignment has a NULL flag, and 68 of the 559 assignments on this pod do.
   -- RI9001 was one: exactly one schedule, no flag, no roster, and Fusion's
   -- own screen shows the schedule perfectly well. Nothing reported it -- a
   -- person with no SHIFT rows just falls back to Mon-Fri, which looks like a
   -- deliberate answer.
   --
   -- So rank instead of filter: prefer the flagged one, then the latest start,
   -- then the highest id so the choice is stable across runs. A person with one
   -- assignment always keeps it, flagged or not, and a person with several
   -- still contributes exactly one.
   --
   -- The correlated subquery scopes the KEEP to this resource. Left uncorrelated
   -- it would rank across the whole table and return one assignment for the pod.
   AND sa.schedule_assignment_id = (
         SELECT MAX(sa2.schedule_assignment_id) KEEP (DENSE_RANK FIRST
                  ORDER BY CASE WHEN NVL(sa2.primary_flag,'N') = 'Y'
                                THEN 0 ELSE 1 END,
                           sa2.start_date DESC)
           FROM per_schedule_assignments sa2
          WHERE sa2.resource_id   = sa.resource_id
            AND sa2.resource_type = 'ASSIGN')
   AND d.start_date_time >= ADD_MONTHS({ED}, -3)
   AND d.start_date_time <  ADD_MONTHS({ED},  3)
 GROUP BY papf.person_number, TRUNC(d.start_date_time)
""".replace("{ED}", ED),
}


# ══════════════════════════════════════════════════════════════
# POET — expenditure type (INT-007 prerequisite)
#
# Verified against the pod on 02-Aug-2026, and the answer was not the expected
# one. Recorded here because it is the kind of thing that gets re-guessed:
#
#   * PJF_EXP_TYPES_B exists and holds 268 types. The column is
#     EXPENDITURE_CATEGORY_ID, not EXPENDITURE_CATEGORY.
#
#   * PJF_TXN_CONTROLS DOES NOT EXIST on this pod. The only object matching
#     %TXN_CONTROL% is PJC_TXN_CONTROLS_STAGE, a staging table. So there are no
#     live transaction controls to read an expenditure type from, and a
#     TASK_EXP_TYPES extract was removed rather than left failing.
#
# That settles the open question from the README: expenditure type is NOT a per
# task attribute here. It comes from configuration —
# OC_TIME_CONFIG DEFAULT_EXPENDITURE_TYPE, seeded to 'Regular Labor', which is
# one of the four labour types on this pod carrying UOM = HOURS (alongside
# Overtime, Supervisory and Miscellaneous Labor).
#
# EXP_TYPES stays as a reference extract: it is what tells an administrator
# which values are legal before they change that configuration.
#
# The expenditure ORGANIZATION half of POET is unaffected — it comes from the
# WORKERS extract above.
# ══════════════════════════════════════════════════════════════

EXP_TYPES = {
    "name": "EXP_TYPES",
    "target": "(reference — the legal values for DEFAULT_EXPENDITURE_TYPE)",
    "integration": "INT-002",
    "key": ["EXPENDITURE_TYPE_ID"],
    "columns": ["EXPENDITURE_TYPE_ID", "EXPENDITURE_TYPE_NAME",
                "EXPENDITURE_CATEGORY_ID", "UNIT_OF_MEASURE",
                "START_DATE", "END_DATE"],
    "sql": """
-- The master list: 268 rows on the reference pod. Worth having because it
-- answers "what may an expenditure type be?" before anyone edits the config.
--
-- UNIT_OF_MEASURE is the useful filter, not the name: a timesheet needs an
-- HOURS type. Several 'Labor' types on this pod are DOLLARS (Craft Labor
-- Straight Time, Consultant Labor...) and would be wrong for hours.
--
-- _TL for the name, following note 7: the base table carries ids, the
-- translated table the display name.
SELECT etb.expenditure_type_id                      AS expenditure_type_id,
       ettl.expenditure_type_name                   AS expenditure_type_name,
       etb.expenditure_category_id                  AS expenditure_category_id,
       etb.unit_of_measure                          AS unit_of_measure,
       TO_CHAR(etb.start_date_active,'YYYY-MM-DD')  AS start_date,
       TO_CHAR(etb.end_date_active,'YYYY-MM-DD')    AS end_date
  FROM pjf_exp_types_b etb
  JOIN pjf_exp_types_tl ettl
    ON ettl.expenditure_type_id = etb.expenditure_type_id
   AND ettl.language = USERENV('LANG')
 WHERE NVL(etb.end_date_active, {ED}) >= {ED}
""".replace("{ED}", ED),
}


ALL_EXTRACTS = [WORKERS, PROJECTS, TASKS, ALLOCATIONS, ABSENCES,
                CALENDAR, SHIFTS, WORK_PATTERNS, WORK_SCHEDULES, WORKER_SHIFTS,
                EXP_TYPES]
BY_NAME = {e["name"]: e for e in ALL_EXTRACTS}

# The ones proven against a pod. --run ALL uses this, so an unverified extract
# cannot quietly join the monthly MasterSync and write a column nobody checked.
VERIFIED = [e for e in ALL_EXTRACTS if e.get("verified", True)]


# ═════════════════════════════════════════════════════════════════════════
# INCREMENTAL SYNC — :P_LAST_SYNC
# ═════════════════════════════════════════════════════════════════════════
#
# Added 09-Aug-2026 so the daily job can fetch only what moved. Every extract
# above is an AS-OF snapshot keyed on :P_EFFECTIVE_DATE; this adds a second,
# independent filter for WHEN THE ROW LAST CHANGED.
#
# ONE MODEL, TWO MODES. Pass '1900-01-01' (the declared default) and the
# predicate is satisfied by everything, so the monthly run is a full refresh
# through exactly the same data model the daily run uses. There is no second
# report to keep in step.
#
# WHY IT IS NOT JUST last_update_date > :P_LAST_SYNC
#
#   1. EFFECTIVE-DATED ROWS CHANGE WITHOUT BEING UPDATED, and this is the trap
#      that makes a naive delta lose data permanently. A termination effective
#      31-Aug entered in June carries LAST_UPDATE_DATE of June. A delta run on
#      1-Sep asking for "changed since 31-Aug" does not select it, so the worker
#      stays Active in our cache for ever and no error is ever raised.
#
#      So EFFECTIVE_START_DATE is folded into the same GREATEST. The as-of
#      predicates already restrict every row to the one current on
#      :P_EFFECTIVE_DATE, so a row whose EFFECTIVE_START_DATE is later than
#      :P_LAST_SYNC is precisely one that came into effect during the window.
#
#   2. A ROW IS A JOIN, NOT A TABLE. A worker row is ten tables wide. Filtering
#      on the driving table alone misses an email change, a manager change or a
#      location change -- silently, because the row simply is not returned.
#      Every alias that contributes a column is listed.
#
# WHAT IT STILL CANNOT DO: see a DELETE. Nothing in a delta can, and the loaders
# only MERGE, so a project team membership removed in Fusion stays in our cache.
# The monthly full refresh does not fix that either -- it re-asserts what exists
# and never removes what does not. Reconciliation is a separate problem; do not
# read "full refresh" as "self-correcting" for deletes.
# 1900, not NULL. LASTSYNC_DATE is nullable and IS null before the first
# successful run -- so the very first sync, the one that must load everything,
# was the one guaranteed to compare against NULL and return nothing. It would
# have read as "no changes" on a completely empty schema.
LAST_SYNC = "NVL(TO_DATE(:P_LAST_SYNC,'YYYY-MM-DD'), DATE '1900-01-01')"

# alias -> is this alias effective-dated IN THIS QUERY (does it contribute an
# EFFECTIVE_START_DATE that can move a row in or out of the as-of window)?
DELTA_ALIASES = {
    "WORKERS":        {"papf": 1, "paam": 1, "ppnf": 1, "pea": 0, "pos": 0,
                       "loc": 1, "org": 1, "expo": 1, "sup": 1, "mgr": 1},
    "PROJECTS":       {"p": 0, "ptl": 0, "pt": 0, "org": 1, "cpp": 0, "cust": 0},
    "TASKS":          {"e": 0, "etl": 0, "p": 0},
    # 'asg' is the PJT_PROJECT_RESOURCE aggregate and it MUST be here: an
    # allocation percentage edited in PPM touches no date on the party, the
    # project or the person, so without this an incremental run never sees it
    # and the split silently stays at whatever was last loaded.
    "ALLOCATIONS":    {"pp": 0, "prj": 0, "papf": 1, "asg": 0},
    # 'e' is now inside the day-generating inline view and is not visible to the
    # injected predicate; the view exposes LAST_UPDATE_DATE and is aliased 'x'.
    # Same failure mode as the WORKER_SHIFTS note below -- a stale alias here
    # produces ORA-00904 from a predicate that is not in the file.
    "ABSENCES":       {"x": 0, "d": 0, "papf": 1, "t": 0},
    "CALENDAR":       {"ce": 0},
    "SHIFTS":         {"s": 0},
    "WORK_PATTERNS":  {"wp": 0, "wps": 0, "sh": 0},
    "WORK_SCHEDULES": {"sa": 0, "paam": 1, "papf": 1},
    # 'ss' was hts_schedule_shifts_vl, which WORKER_SHIFTS no longer reads.
    # Leaving it here produced ORA-00904 on "SS"."LAST_UPDATE_DATE" -- from a
    # predicate injected after the SQL, so the file looked correct and only the
    # pod disagreed.
    # 'sp'/'pt' are the schedule-to-pattern pair. Listed because RENAMING a
    # pattern must reach the cache: it changes no date on the assignment or
    # the detail rows, so without these an incremental run never sees it.
    "WORKER_SHIFTS":  {"d": 0, "sa": 0, "papf": 1, "sp": 0, "pt": 0},
    "EXP_TYPES":      {"etb": 0, "ettl": 0},
}

# How the predicate attaches. Blind appending is wrong for two of the eleven:
# ALLOCATIONS and WORKER_SHIFTS end in GROUP BY.
#   "and"    - the SQL ends inside its WHERE clause  (the default)
#   "where"  - there is no WHERE; open one
#   "before" - insert ahead of the trailing clause named in DELTA_BEFORE
#
# SHIFTS was "where" and is now the default. It had no WHERE clause until
# P_EFFECTIVE_DATE was added for parameter parity, which gave it "WHERE 1 = 1"
# -- leaving the mode alone would have appended a SECOND WHERE and produced
# ORA-00933. Whenever a WHERE is added to a base query, check this map.
DELTA_MODE = {
    # ABSENCES joined these on 17-Aug-2026, when the day-expansion rewrite gave
    # it a GROUP BY. Appended blindly the predicate lands AFTER the GROUP BY and
    # the whole extract fails to parse.
    "ALLOCATIONS": "before", "WORKER_SHIFTS": "before", "ABSENCES": "before",
}
DELTA_BEFORE = {"ALLOCATIONS": "GROUP BY", "WORKER_SHIFTS": "GROUP BY",
                "ABSENCES": "GROUP BY"}

_EPOCH = "DATE '1900-01-01'"


def _delta_predicate(aliases):
    """GREATEST over every alias's change stamps, compared to :P_LAST_SYNC."""
    parts = []
    for a, is_effective_dated in aliases.items():
        parts.append("NVL(%s.last_update_date, %s)" % (a, _EPOCH))
        if is_effective_dated:
            parts.append("NVL(%s.effective_start_date, %s)" % (a, _EPOCH))
    return ("GREATEST(\n           " + ",\n           ".join(parts)
            + ") > " + LAST_SYNC)


def _attach_delta(ex):
    name, sql = ex["name"], ex["sql"].rstrip()
    aliases = DELTA_ALIASES.get(name)
    if not aliases:
        return sql
    pred = _delta_predicate(aliases)
    mode = DELTA_MODE.get(name, "and")

    if mode == "and":
        return sql + "\n   AND " + pred + "\n"
    if mode == "where":
        return sql + "\n WHERE " + pred + "\n"

    # "before": split at the LAST occurrence of the trailing clause, so the
    # predicate lands in the WHERE and not after an aggregate.
    kw = DELTA_BEFORE[name]
    i = sql.upper().rfind("\n" + " " * (len(sql) - len(sql.lstrip())) + kw)
    if i < 0:
        i = sql.upper().rfind(kw)
        i = sql.rfind("\n", 0, i)
    if i < 0:
        raise AssertionError("%s: cannot find %s to insert before" % (name, kw))
    return sql[:i] + "\n   AND " + pred + sql[i:] + "\n"


for _ex in ALL_EXTRACTS:
    _ex["sql"] = _attach_delta(_ex)
