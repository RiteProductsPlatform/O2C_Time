"""
O2C Time — the six Fusion master-data extracts.

Each entry maps one Fusion source to one O2C_TIME cache table. The SELECT alias
list IS the CSV header and IS the upsert column list, so the three can never
drift apart.

Every object name and every column here was verified against a live Fusion pod
(see integration/bip/README.md). Two corrections worth remembering:

  * work schedules / shifts / work patterns live under HTS_, not ZMM_. On a
    Fusion pod ZMM_SR_* is Service Request scheduling (CX), nothing to do with
    HCM availability.
  * HR_ALL_ORGANIZATION_UNITS_F has no NAME column - the name is in the
    translated view HR_ALL_ORGANIZATION_UNITS_F_VL.

All extracts take :P_EFFECTIVE_DATE. The HCM tables are effective-dated (_F/_M),
so without it you get every historical version of every row.
"""

# ── EFFECTIVE-DATE PREDICATE ─────────────────────────────────────────────
# Fusion passes report parameters as strings; TO_DATE keeps the comparison a
# date one rather than an implicit-conversion accident.
ED = "TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')"


WORKERS = {
    "name": "WORKERS",
    "target": "OC_TIME_WORKER",
    "integration": "INT-001",
    "key": ["EMPLOYEE_ID"],
    "columns": ["EMPLOYEE_ID", "EMPLOYEE_NAME", "EMAIL", "WORKER_TYPE",
                "BASE_COUNTRY", "STD_HOURS_PER_DAY", "MANAGER_EMP_ID",
                "LEGAL_EMPLOYER", "HIRE_DATE", "TERMINATION_DATE", "STATUS"],
    "sql": """
SELECT papf.person_number                                AS employee_id,
       ppnf.display_name                                 AS employee_name,
       LOWER(pea.email_address)                          AS email,
       CASE WHEN paam.system_person_type = 'CWK' THEN 'Contractor'
            ELSE 'Employee' END                          AS worker_type,
       loc.country                                       AS base_country,
       -- NORMAL_HOURS is per FREQUENCY, so a weekly figure has to be reduced to
       -- a daily one before it can drive FLD-011 / CFG-013.
       CASE WHEN paam.frequency = 'W' AND paam.normal_hours > 0
            THEN ROUND(paam.normal_hours / 5, 2)
            ELSE paam.normal_hours END                   AS std_hours_per_day,
       mgr.person_number                                 AS manager_emp_id,
       org.name                                          AS legal_employer,
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
  -- RULE-015 depends on this: a manager's own time is approved by THIS person.
  LEFT JOIN per_assignment_supervisors_f sup
    ON sup.assignment_id = paam.assignment_id
   AND sup.manager_type = 'LINE_MANAGER' AND sup.primary_flag = 'Y'
   AND {ED} BETWEEN sup.effective_start_date AND sup.effective_end_date
  LEFT JOIN per_all_people_f mgr
    ON mgr.person_id = sup.manager_id
   AND {ED} BETWEEN mgr.effective_start_date AND mgr.effective_end_date
 WHERE {ED} BETWEEN papf.effective_start_date AND papf.effective_end_date
""".replace("{ED}", ED),
}


PROJECTS = {
    "name": "PROJECTS",
    "target": "OC_TIME_PROJECT",
    "integration": "INT-002",
    "key": ["PROJECT_NUMBER"],
    "columns": ["PROJECT_ID", "PROJECT_NUMBER", "PROJECT_NAME", "PROJECT_TYPE",
                "CUSTOMER_NAME", "PROJECT_STATUS", "START_DATE", "END_DATE",
                "ORGANIZATION"],
    "sql": """
SELECT p.project_id                            AS project_id,
       p.segment1                              AS project_number,
       ptl.name                                AS project_name,
       pt.project_type                         AS project_type,
       cust.party_name                         AS customer_name,
       p.project_status_code                   AS project_status,
       TO_CHAR(p.start_date,'YYYY-MM-DD')      AS start_date,
       TO_CHAR(p.completion_date,'YYYY-MM-DD') AS end_date,
       org.name                                AS organization
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
 WHERE NVL(p.completion_date, {ED}) >= ADD_MONTHS({ED}, -12)
""".replace("{ED}", ED),
}


TASKS = {
    "name": "TASKS",
    "target": "OC_TIME_TASK",
    "integration": "INT-002",
    "key": ["TASK_ID"],
    "columns": ["TASK_ID", "PROJECT_ID", "PROJECT_NUMBER", "TASK_NUMBER",
                "TASK_NAME", "CHARGEABLE_FLAG", "BILLABLE_FLAG",
                "WBS_LEVEL", "PARENT_TASK_ID", "START_DATE", "END_DATE"],
    "sql": """
SELECT e.proj_element_id                        AS task_id,
       e.project_id                             AS project_id,
       p.segment1                               AS project_number,
       e.element_number                         AS task_number,
       etl.name                                 AS task_name,
       -- RULE-010: only a chargeable task may appear in the grid's task LOV.
       NVL(e.chargeable_flag,'N')               AS chargeable_flag,
       NVL(e.billable_flag,'N')                 AS billable_flag,
       e.denorm_wbs_level                       AS wbs_level,
       e.denorm_parent_element_id               AS parent_task_id,
       TO_CHAR(e.start_date,'YYYY-MM-DD')       AS start_date,
       TO_CHAR(e.completion_date,'YYYY-MM-DD')  AS end_date
  FROM pjf_proj_elements_b e
  JOIN pjf_proj_elements_tl etl
    ON etl.proj_element_id = e.proj_element_id AND etl.language = USERENV('LANG')
  JOIN pjf_projects_all_b p
    ON p.project_id = e.project_id
 WHERE e.object_type = 'PJF_TASKS'   -- plural; 'PJF_TASK' matches nothing
   AND NVL(e.completion_date, {ED}) >= ADD_MONTHS({ED}, -12)
""".replace("{ED}", ED),
}


ALLOCATIONS = {
    "name": "ALLOCATIONS",
    "target": "OC_TIME_ALLOCATION",
    "integration": "INT-003",
    "key": ["PROJECT_ID", "EMPLOYEE_ID"],
    "columns": ["PROJECT_ID", "PROJECT_NUMBER", "EMPLOYEE_ID", "START_DATE",
                "END_DATE", "ALLOC_PCT", "CAP_HOURS", "TRACK_TIME_FLAG", "STATUS"],
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
SELECT pp.project_id                                   AS project_id,
       prj.segment1                                    AS project_number,
       papf.person_number                              AS employee_id,
       TO_CHAR(MIN(pp.start_date_active),'YYYY-MM-DD') AS start_date,
       TO_CHAR(MAX(pp.end_date_active),'YYYY-MM-DD')   AS end_date,
       MAX(asg.alloc_pct)                              AS alloc_pct,
       MAX(asg.hours_per_day)                          AS cap_hours,
       MAX(pp.pjs_track_time)                          AS track_time_flag,
       CASE WHEN MAX(NVL(pp.end_date_active, DATE '4712-12-31')) >= {ED}
            THEN 'Active' ELSE 'Inactive' END          AS status
  FROM pjf_project_parties pp
  JOIN pjf_projects_all_b prj
    ON prj.project_id = pp.project_id
  JOIN per_all_people_f papf
    ON papf.person_id = pp.resource_source_id
   AND {ED} BETWEEN papf.effective_start_date AND papf.effective_end_date
  LEFT JOIN (SELECT project_id,
                    resource_id,
                    SUM(billable_percent) AS alloc_pct,
                    MAX(hours_per_day)    AS hours_per_day
               FROM pjr_assignment
              WHERE {ED} BETWEEN start_date AND NVL(end_date, {ED})
              GROUP BY project_id, resource_id) asg
    ON asg.project_id = pp.project_id
   AND asg.resource_id = pp.resource_id
 WHERE pp.project_party_type = 'IN'   -- internal team member ('CO' = customer)
   AND NVL(pp.end_date_active, {ED}) >= ADD_MONTHS({ED}, -12)
 GROUP BY pp.project_id, prj.segment1, papf.person_number
""".replace("{ED}", ED),
}


ABSENCES = {
    "name": "ABSENCES",
    "target": "OC_TIME_ABSENCE",
    "integration": "INT-006",
    "key": ["EMPLOYEE_ID", "ABSENCE_DATE", "ABSENCE_TYPE"],
    "columns": ["EMPLOYEE_ID", "ABSENCE_DATE", "ABSENCE_TYPE", "DURATION_HOURS",
                "APPROVAL_STATUS", "ABSENCE_STATUS"],
    "sql": """
SELECT papf.person_number                    AS employee_id,
       TO_CHAR(d.absence_date,'YYYY-MM-DD')  AS absence_date,
       t.name                                AS absence_type,
       d.duration                            AS duration_hours,
       e.approval_status_cd                  AS approval_status,
       e.absence_status_cd                   AS absence_status
  FROM anc_per_abs_entries e
  -- Day-level detail, not the header: RULE-008 needs one Leave row per DAY so
  -- the grid can show it against the right column.
  JOIN anc_per_abs_entry_dtls d
    ON d.per_absence_entry_id = e.per_absence_entry_id
  JOIN per_all_people_f papf
    ON papf.person_id = e.person_id
   AND d.absence_date BETWEEN papf.effective_start_date AND papf.effective_end_date
  LEFT JOIN anc_absence_types_vl t
    ON t.absence_type_id = e.absence_type_id
 WHERE e.approval_status_cd = 'APPROVED'
   AND d.absence_date >= ADD_MONTHS({ED}, -12)
   AND d.absence_date <  ADD_MONTHS({ED},   3)
""".replace("{ED}", ED),
}


CALENDAR = {
    "name": "CALENDAR",
    "target": "OC_TIME_CALENDAR",
    "integration": "INT-004 / INT-005",
    "key": ["LAYER", "SCOPE_KEY", "CALENDAR_DATE"],
    "columns": ["LAYER", "SCOPE_KEY", "CALENDAR_DATE", "IS_WORKING_DAY",
                "HOLIDAY_NAME", "SHIFT_CODE", "STANDARD_HOURS"],
    "sql": """
-- CORPORATE layer only: public holidays from HCM calendar events, expanded to
-- one row per day. PROJECT / CLIENT / SHIFT layers are loaded separately -
-- OC_TIME_CALENDAR resolves them by precedence (SHIFT 4 > CLIENT 3 >
-- PROJECT 2 > CORPORATE 1).
SELECT 'CORPORATE'                                       AS layer,
       NVL(ce.short_code,'GLOBAL')                       AS scope_key,
       TO_CHAR(TRUNC(ce.start_date_time) + lvl.n,'YYYY-MM-DD') AS calendar_date,
       'N'                                               AS is_working_day,
       ce.short_code                                     AS holiday_name,
       CAST(NULL AS VARCHAR2(20))                        AS shift_code,
       0                                                 AS standard_hours
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
""",
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
""",
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
    "key": ["EMPLOYEE_ID", "CALENDAR_DATE"],
    "columns": ["LAYER", "EMPLOYEE_ID", "CALENDAR_DATE", "IS_WORKING_DAY",
                "SHIFT_CODE", "SHIFT_NAME", "STANDARD_HOURS"],
    "sql": """
-- The SHIFT layer, resolved. Fusion has already expanded work pattern x work
-- schedule into concrete person x date x shift rows, so this reads the answer
-- rather than recomputing the cycle.
--
-- RULE-011 is one shift per day, so the aggregate collapses any split shift to
-- a single row and sums the duration. WORK_DURATION is MINUTES in HTS - hence
-- the /60; taking it as hours would give every worker a 480-hour day.
SELECT 'SHIFT'                                     AS layer,
       papf.person_number                          AS employee_id,
       TO_CHAR(ss.ref_date,'YYYY-MM-DD')           AS calendar_date,
       'Y'                                         AS is_working_day,
       MIN(TO_CHAR(ss.shift_id))                   AS shift_code,
       MIN(ss.shift_name)                          AS shift_name,
       ROUND(SUM(NVL(ss.work_duration,0)) / 60, 2) AS standard_hours
  FROM hts_schedule_shifts_vl ss
  JOIN per_all_people_f papf
    ON papf.person_id = ss.person_id
   AND ss.ref_date BETWEEN papf.effective_start_date AND papf.effective_end_date
 WHERE ss.ref_date >= ADD_MONTHS({ED}, -3)
   AND ss.ref_date <  ADD_MONTHS({ED},  3)
 GROUP BY papf.person_number, ss.ref_date
""".replace("{ED}", ED),
}


ALL_EXTRACTS = [WORKERS, PROJECTS, TASKS, ALLOCATIONS, ABSENCES,
                CALENDAR, SHIFTS, WORK_PATTERNS, WORK_SCHEDULES, WORKER_SHIFTS]
BY_NAME = {e["name"]: e for e in ALL_EXTRACTS}
