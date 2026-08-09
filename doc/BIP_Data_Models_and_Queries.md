# BIP data models and queries — O2C Timesheet inbound sync

Generated from `integration/bip/extracts.py` on 09-Aug-2026. Everything here is what the code actually sends, not a transcription.

**Catalog folder:** `/Custom/O2C_TIME`  ·  **Naming:** `O2C_<ENTITY>.xdm`  ·  **Bind:** `:P_EFFECTIVE_DATE` (`YYYY-MM-DD`), auto-declared by `build_data_model`

| # | Extract | Data model | Target | In scheduled sync |
|---|---|---|---|---|
| 1 | `WORKERS` | `/Custom/O2C_TIME/O2C_WORKERS.xdm` | `OC_TIME_WORKER` | yes |
| 2 | `PROJECTS` | `/Custom/O2C_TIME/O2C_PROJECTS.xdm` | `OC_TIME_PROJECT` | yes |
| 3 | `TASKS` | `/Custom/O2C_TIME/O2C_TASKS.xdm` | `OC_TIME_TASK` | yes |
| 4 | `ALLOCATIONS` | `/Custom/O2C_TIME/O2C_ALLOCATIONS.xdm` | `OC_TIME_ALLOCATION` | yes |
| 5 | `ABSENCES` | `/Custom/O2C_TIME/O2C_ABSENCES.xdm` | `OC_TIME_ABSENCE` | **no — live** |
| 6 | `CALENDAR` | `/Custom/O2C_TIME/O2C_CALENDAR.xdm` | `OC_TIME_CALENDAR` | yes |
| 7 | `SHIFTS` | `/Custom/O2C_TIME/O2C_SHIFTS.xdm` | `OC_TIME_CALENDAR (SHIFT layer)` | yes |
| 8 | `WORK_PATTERNS` | `/Custom/O2C_TIME/O2C_WORK_PATTERNS.xdm` | `OC_TIME_CALENDAR (pattern reference)` | yes |
| 9 | `WORK_SCHEDULES` | `/Custom/O2C_TIME/O2C_WORK_SCHEDULES.xdm` | `OC_TIME_CALENDAR (schedule assignment)` | yes |
| 10 | `WORKER_SHIFTS` | `/Custom/O2C_TIME/O2C_WORKER_SHIFTS.xdm` | `OC_TIME_CALENDAR (SHIFT layer)` | yes |
| 11 | `EXP_TYPES` | `/Custom/O2C_TIME/O2C_EXP_TYPES.xdm` | `(reference — the legal values for DEFAULT_EXPENDITURE_TYPE)` | yes |

---

## WORKERS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_WORKERS.xdm` |
| Target table | `OC_TIME_WORKER` |
| Integration id | INT-001 |
| Natural key | `EMPLOYEE_ID` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/sync/worker |
| Columns (12) | `EMPLOYEE_ID`, `EMPLOYEE_NAME`, `EMAIL`, `WORKER_TYPE`, `BASE_COUNTRY`, `STD_HOURS_PER_DAY`, `MANAGER_EMP_ID`, `LEGAL_EMPLOYER`, `EXPENDITURE_ORG`, `HIRE_DATE`, `TERMINATION_DATE`, `STATUS` |

```sql
SELECT papf.person_number                                AS employee_id,
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
             OR pos.actual_termination_date >= TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')
            THEN 'Active' ELSE 'Terminated' END          AS status
  FROM per_all_people_f papf
  JOIN per_all_assignments_m paam
    ON paam.person_id = papf.person_id
   AND paam.primary_flag = 'Y'
   AND paam.assignment_type IN ('E','C')
   AND paam.effective_latest_change = 'Y'
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN paam.effective_start_date AND paam.effective_end_date
  JOIN per_person_names_f ppnf
    ON ppnf.person_id = papf.person_id
   AND ppnf.name_type = 'GLOBAL'
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN ppnf.effective_start_date AND ppnf.effective_end_date
  -- Work email is the join to the app: getMe looks the worker up by it.
  LEFT JOIN per_email_addresses pea
    ON pea.person_id = papf.person_id AND pea.email_type = 'W1'
  LEFT JOIN per_periods_of_service pos
    ON pos.period_of_service_id = paam.period_of_service_id
  LEFT JOIN hr_locations_all_f loc
    ON loc.location_id = paam.location_id
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN loc.effective_start_date AND loc.effective_end_date
  LEFT JOIN hr_all_organization_units_f_vl org
    ON org.organization_id = paam.legal_entity_id
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN org.effective_start_date AND org.effective_end_date
  -- Same table, different key: the assignment's own organization rather than
  -- its legal entity. _F_VL because the base _F has no NAME (note 7 below).
  LEFT JOIN hr_all_organization_units_f_vl expo
    ON expo.organization_id = paam.organization_id
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN expo.effective_start_date AND expo.effective_end_date
  -- RULE-015 depends on this: a manager's own time is approved by THIS person.
  LEFT JOIN per_assignment_supervisors_f sup
    ON sup.assignment_id = paam.assignment_id
   AND sup.manager_type = 'LINE_MANAGER' AND sup.primary_flag = 'Y'
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN sup.effective_start_date AND sup.effective_end_date
  LEFT JOIN per_all_people_f mgr
    ON mgr.person_id = sup.manager_id
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN mgr.effective_start_date AND mgr.effective_end_date
 WHERE TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN papf.effective_start_date AND papf.effective_end_date
```

---

## PROJECTS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_PROJECTS.xdm` |
| Target table | `OC_TIME_PROJECT` |
| Integration id | INT-002 |
| Natural key | `PROJECT_NUMBER` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/sync/project |
| Columns (11) | `PROJECT_ID`, `PROJECT_NUMBER`, `PROJECT_NAME`, `PROJECT_TYPE`, `CUSTOMER_NAME`, `PROJECT_STATUS`, `START_DATE`, `END_DATE`, `ORGANIZATION`, `PROJECT_MANAGER_ID`, `TIME_ENTRY_ENABLED` |

```sql
SELECT p.project_id                            AS project_id,
       p.segment1                              AS project_number,
       ptl.name                                AS project_name,
       pt.project_type                         AS project_type,
       cust.party_name                         AS customer_name,
       p.project_status_code                   AS project_status,
       TO_CHAR(p.start_date,'YYYY-MM-DD')      AS start_date,
       TO_CHAR(p.completion_date,'YYYY-MM-DD') AS end_date,
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
           AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN pm.effective_start_date AND pm.effective_end_date
         WHERE mpp.project_id = p.project_id
           AND mpp.project_party_type = 'IN'
           AND r.name = 'Project Manager'
           AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN NVL(mpp.start_date_active, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'))
                        AND NVL(mpp.end_date_active,   TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')))
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
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN org.effective_start_date AND org.effective_end_date
  -- Customer comes through the project party. The party type code is 'CO'
  -- (customer); 'IN' is an internal team member. A project has many parties, so
  -- the type filter is what keeps this one row.
  LEFT JOIN pjf_project_parties cpp
    ON cpp.project_id = p.project_id AND cpp.project_party_type = 'CO'
  LEFT JOIN hz_parties cust
    ON cust.party_id = cpp.resource_source_id
 WHERE 
   EXISTS (SELECT 1
             FROM pjf_projects_all_b sp
            WHERE sp.project_id = p.project_id
              -- Recency lives HERE, not in each extract's own WHERE. The three
              -- used to test different dates for the same idea — the project's
              -- completion date in PROJECTS, the task's in TASKS, the party's
              -- end date in ALLOCATIONS — so a project completed 18 months ago
              -- was dropped from PROJECTS while its still-open tasks sailed
              -- through, and 89 rows failed their FK lookup. One test, one
              -- answer, for all three.
              AND NVL(sp.completion_date, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')) >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -12)
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
                             AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN mpp.effective_start_date
                                          AND mpp.effective_end_date
                           WHERE mp.project_id = sp.project_id
                             AND mp.project_party_type = 'IN'
                             AND mr.name = 'Project Manager'))
```

---

## TASKS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_TASKS.xdm` |
| Target table | `OC_TIME_TASK` |
| Integration id | INT-002 |
| Natural key | `TASK_ID` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/sync/task |
| Columns (12) | `TASK_ID`, `PROJECT_ID`, `PROJECT_NUMBER`, `TASK_NUMBER`, `TASK_NAME`, `CHARGEABLE_FLAG`, `BILLABLE_FLAG`, `WBS_LEVEL`, `PARENT_TASK_ID`, `START_DATE`, `END_DATE`, `EXPENDITURE_TYPE` |

```sql
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
   AND 
   EXISTS (SELECT 1
             FROM pjf_projects_all_b sp
            WHERE sp.project_id = e.project_id
              -- Recency lives HERE, not in each extract's own WHERE. The three
              -- used to test different dates for the same idea — the project's
              -- completion date in PROJECTS, the task's in TASKS, the party's
              -- end date in ALLOCATIONS — so a project completed 18 months ago
              -- was dropped from PROJECTS while its still-open tasks sailed
              -- through, and 89 rows failed their FK lookup. One test, one
              -- answer, for all three.
              AND NVL(sp.completion_date, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')) >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -12)
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
                             AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN mpp.effective_start_date
                                          AND mpp.effective_end_date
                           WHERE mp.project_id = sp.project_id
                             AND mp.project_party_type = 'IN'
                             AND mr.name = 'Project Manager'))
```

---

## ALLOCATIONS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_ALLOCATIONS.xdm` |
| Target table | `OC_TIME_ALLOCATION` |
| Integration id | INT-003 |
| Natural key | `PROJECT_ID`, `EMPLOYEE_ID` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/sync/allocation |
| Columns (9) | `PROJECT_ID`, `PROJECT_NUMBER`, `EMPLOYEE_ID`, `START_DATE`, `END_DATE`, `ALLOC_PCT`, `CAP_HOURS`, `TRACK_TIME_FLAG`, `STATUS` |

```sql
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
       CASE WHEN MAX(NVL(pp.end_date_active, DATE '4712-12-31')) >= TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')
            THEN 'Active' ELSE 'Inactive' END          AS status
  FROM pjf_project_parties pp
  JOIN pjf_projects_all_b prj
    ON prj.project_id = pp.project_id
  JOIN per_all_people_f papf
    ON papf.person_id = pp.resource_source_id
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN papf.effective_start_date AND papf.effective_end_date
  LEFT JOIN (SELECT project_id,
                    resource_id,
                    SUM(billable_percent) AS alloc_pct,
                    MAX(hours_per_day)    AS hours_per_day
               FROM pjr_assignment
              WHERE TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN start_date AND NVL(end_date, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'))
              GROUP BY project_id, resource_id) asg
    ON asg.project_id = pp.project_id
   AND asg.resource_id = pp.resource_id
 WHERE pp.project_party_type = 'IN'   -- internal team member ('CO' = customer)
   AND 
   EXISTS (SELECT 1
             FROM pjf_projects_all_b sp
            WHERE sp.project_id = pp.project_id
              -- Recency lives HERE, not in each extract's own WHERE. The three
              -- used to test different dates for the same idea — the project's
              -- completion date in PROJECTS, the task's in TASKS, the party's
              -- end date in ALLOCATIONS — so a project completed 18 months ago
              -- was dropped from PROJECTS while its still-open tasks sailed
              -- through, and 89 rows failed their FK lookup. One test, one
              -- answer, for all three.
              AND NVL(sp.completion_date, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')) >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -12)
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
                             AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN mpp.effective_start_date
                                          AND mpp.effective_end_date
                           WHERE mp.project_id = sp.project_id
                             AND mp.project_party_type = 'IN'
                             AND mr.name = 'Project Manager'))

 GROUP BY pp.project_id, prj.segment1, papf.person_number
```

---

## ABSENCES

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_ABSENCES.xdm` |
| Target table | `OC_TIME_ABSENCE` |
| Integration id | INT-006 |
| Natural key | `EMPLOYEE_ID`, `ABSENCE_DATE`, `ABSENCE_TYPE` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/sync/absence  (live per person now) |
| Columns (6) | `EMPLOYEE_ID`, `ABSENCE_DATE`, `ABSENCE_TYPE`, `DURATION_HOURS`, `APPROVAL_STATUS`, `ABSENCE_STATUS` |

```sql
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
   AND d.absence_date >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -12)
   AND d.absence_date <  ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'),   3)
```

---

## CALENDAR

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_CALENDAR.xdm` |
| Target table | `OC_TIME_CALENDAR` |
| Integration id | INT-004 / INT-005 |
| Natural key | `LAYER`, `SCOPE_KEY`, `CALENDAR_DATE` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/calendar/sync/CORPORATE |
| Columns (7) | `LAYER`, `SCOPE_KEY`, `CALENDAR_DATE`, `IS_WORKING_DAY`, `HOLIDAY_NAME`, `SHIFT_CODE`, `STANDARD_HOURS` |

```sql
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
   AND TRUNC(ce.start_date_time) + lvl.n >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -3)
   AND TRUNC(ce.start_date_time) + lvl.n <  ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), 12)
```

---

## SHIFTS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_SHIFTS.xdm` |
| Target table | `OC_TIME_CALENDAR (SHIFT layer)` |
| Integration id | INT-004 |
| Natural key | `SHIFT_CODE` |
| Binds | none |
| Loader endpoint | reference only - feeds the SHIFT layer |
| Columns (6) | `SHIFT_CODE`, `SHIFT_NAME`, `WORK_DURATION`, `BREAK_DURATION`, `SHIFT_CATEGORY`, `ACTIVE_FLAG` |

```sql
-- RULE-011: shift is display-only, one per day. This is the reference list;
-- the per-worker assignment comes from HTS_WORKERS_WITH_SHIFTS_V.
SELECT s.shift_code      AS shift_code,
       s.shift_name      AS shift_name,
       s.work_duration   AS work_duration,
       s.break_duration  AS break_duration,
       s.shift_category  AS shift_category,
       s.active_flag     AS active_flag
  FROM hts_shifts_vl s
```

---

## WORK_PATTERNS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_WORK_PATTERNS.xdm` |
| Target table | `OC_TIME_CALENDAR (pattern reference)` |
| Integration id | INT-004 |
| Natural key | `WORK_PATTERN_ID`, `DAY_INDEX` |
| Binds | none |
| Loader endpoint | reference only - feeds the SHIFT layer |
| Columns (9) | `WORK_PATTERN_ID`, `WORK_PATTERN_NAME`, `REPEAT_CYCLE`, `REPEAT_NUM`, `DAY_INDEX`, `SHIFT_ID`, `SHIFT_NAME`, `DURATION`, `BREAK_DURATION` |

```sql
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
```

---

## WORK_SCHEDULES

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_WORK_SCHEDULES.xdm` |
| Target table | `OC_TIME_CALENDAR (schedule assignment)` |
| Integration id | INT-004 |
| Natural key | `EMPLOYEE_ID`, `SCHEDULE_ID`, `START_DATE` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | reference only - feeds the SHIFT layer |
| Columns (6) | `EMPLOYEE_ID`, `SCHEDULE_ID`, `RESOURCE_TYPE`, `START_DATE`, `END_DATE`, `PRIMARY_FLAG` |

```sql
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
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN paam.effective_start_date AND paam.effective_end_date
  JOIN per_all_people_f papf
    ON papf.person_id = paam.person_id
   AND TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD') BETWEEN papf.effective_start_date AND papf.effective_end_date
 WHERE sa.resource_type = 'ASSIGN'
   AND NVL(sa.end_date, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')) >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -12)
```

---

## WORKER_SHIFTS

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_WORKER_SHIFTS.xdm` |
| Target table | `OC_TIME_CALENDAR (SHIFT layer)` |
| Integration id | INT-004 |
| Natural key | `EMPLOYEE_ID`, `CALENDAR_DATE` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | POST /oc/time/admin/calendar/sync/SHIFT |
| Columns (7) | `LAYER`, `EMPLOYEE_ID`, `CALENDAR_DATE`, `IS_WORKING_DAY`, `SHIFT_CODE`, `SHIFT_NAME`, `STANDARD_HOURS` |

```sql
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
 WHERE ss.ref_date >= ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'), -3)
   AND ss.ref_date <  ADD_MONTHS(TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD'),  3)
 GROUP BY papf.person_number, ss.ref_date
```

---

## EXP_TYPES

| | |
|---|---|
| Data model | `/Custom/O2C_TIME/O2C_EXP_TYPES.xdm` |
| Target table | `(reference — the legal values for DEFAULT_EXPENDITURE_TYPE)` |
| Integration id | INT-002 |
| Natural key | `EXPENDITURE_TYPE_ID` |
| Binds | `:P_EFFECTIVE_DATE` |
| Loader endpoint | reference only - legal values for EXPENDITURE_TYPE |
| Columns (6) | `EXPENDITURE_TYPE_ID`, `EXPENDITURE_TYPE_NAME`, `EXPENDITURE_CATEGORY_ID`, `UNIT_OF_MEASURE`, `START_DATE`, `END_DATE` |

```sql
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
 WHERE NVL(etb.end_date_active, TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')) >= TO_DATE(:P_EFFECTIVE_DATE,'YYYY-MM-DD')
```
