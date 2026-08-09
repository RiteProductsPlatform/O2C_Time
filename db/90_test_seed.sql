--==============================================================
-- 90_test_seed.sql
-- O2C Timesheet Module — TEST DATA ONLY
--
-- Loads the exact cast described in Time Module/TEST_SETUP_GUIDE.md straight into
-- the Fusion master-cache tables, so the SC-01..SC-25 scenarios can be run before
-- the inbound OIC flows exist.
--
-- The 12 workers and the line-manager hierarchy mirror HDL/Worker/Worker.dat as
-- actually loaded into Fusion, so when the sync is built it should produce
-- substantially this same data — which makes this a useful comparison baseline,
-- not just a fixture.
--
-- SAFE TO RE-RUN. Every statement is a MERGE or a guarded INSERT keyed on the
-- natural key. Nothing here touches the reference seed in 10_seed.sql.
--
-- NOT FOR PRODUCTION. Drop with 91_test_seed_remove.sql (or simply never run this
-- against a real environment — every row is tagged CREATED_BY = 'TEST_SEED').
--
-- Depends on: install_time.sql (schema + 10_seed.sql reference data)
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT ============================================================
PROMPT [1/8] OC_TIME_WORKER — 12 workers + line-manager hierarchy
PROMPT ============================================================

-- Hierarchy from HDL AssignmentSupervisor:
--   RI9001 Navamani  ->  manages RI2894
--   RI2894 Santosh   ->  manages the other ten
-- Santosh managing everyone AND being managed by Navamani is what makes RULE-015
-- testable with real data: Santosh's own timesheet must be approved by Navamani.
--
-- Santosh was ALSO seeded as ROLE_TIME_ADMIN, to cover "admin who is also a line
-- manager" in one row. That combination stopped being viable on 01-Aug-2026,
-- when the admin menu was narrowed to Setup + Operations (PER-004): the admin
-- role removed the manager screens from the very person who had to approve
-- PRJ-1001 and PRJ-1003, so both projects had no reachable approver and twenty
-- workers had a line manager who could not act. The combination is now
-- untestable BY DESIGN -- PER-004 says an admin who records time signs in with
-- their worker account -- so the finance persona is admin@rite.digital, seeded
-- below with no worker row, and Santosh stays a manager.
--
-- Navamani is still the top of the tree with no manager of their own, so their
-- OWN month has no approver. That is a real open decision, not a seed defect.
--
-- EMAIL matters: the shell resolves the signed-in user by email, so these must
-- match what your identity provider returns or nobody can sign in. Only
-- RI2894 and RI2824 are known-good; the rest are constructed and should be
-- corrected to the real addresses.
DECLARE
  TYPE t_w IS RECORD (
    emp   VARCHAR2(50),
    nm    VARCHAR2(200),
    email VARCHAR2(200),
    wtype VARCHAR2(20),
    role  VARCHAR2(30),
    mgr   VARCHAR2(50)
  );
  TYPE t_tab IS TABLE OF t_w;

  v t_tab := t_tab(
    --      emp        name                            email                              type          app role                 manager
    t_w('RI9001',  'Navamani Solairajan',          'navamani.solairajan@rite.digital',  'Employee',   'ROLE_TIME_MANAGER',    NULL),
    -- MANAGER, not ADMIN. This row said ROLE_TIME_ADMIN until 09-Aug-2026 and it
    -- locked the module up, because RI2894 wears three hats: project manager of
    -- PRJ-1001 and PRJ-1003, line manager of twenty workers, and the finance
    -- persona. The admin menu is deliberately Setup + Operations only (PER-004),
    -- so the admin role removed the manager screens from the one person who had
    -- to approve those two projects -- leaving them with no reachable approver
    -- at all, and twenty workers whose line manager could not act.
    --
    -- The design already separates these: admin@rite.digital is seeded below as
    -- the COMMON ADMIN with no worker row on purpose. Use that login for the
    -- finance screens; a worker who is also a manager stays a manager here.
    t_w('RI2894',  'Santosh Kumar Kanala',         'Santoshkumar.kanala@rite.digital',  'Employee',   'ROLE_TIME_MANAGER',    'RI9001'),
    t_w('RI2824',  'Sam Joshuva Paul Jeevan S',    'sampaul.jeevan@rite.digital',       'Employee',   'ROLE_TIME_EMPLOYEE',   'RI2894'),
    t_w('RI2900',  'SaiSowmith Kantipudi',         'saisowmith.kantipudi@rite.digital', 'Employee',   'ROLE_TIME_EMPLOYEE',   'RI2894'),
    t_w('RI2963',  'Shaik Wajahad Ali',            'wajahad.ali@rite.digital',          'Employee',   'ROLE_TIME_EMPLOYEE',   'RI2894'),
    t_w('RI2935',  'Shivani Rathore',              'shivani.rathore@rite.digital',      'Employee',   'ROLE_TIME_EMPLOYEE',   'RI2894'),
    t_w('RI3004',  'Gayathri Radhakrishnan',       'gayathri.radhakrishnan@rite.digital','Employee',  'ROLE_TIME_EMPLOYEE',   'RI2894'),
    t_w('RI2914',  'Venkata Bhaskar Reddy Sang',   'bhaskar.sang@rite.digital',         'Employee',   'ROLE_TIME_EMPLOYEE',   'RI2894'),
    t_w('CRI0406', 'Ranganayaki Venugopalan',      'ranganayaki.venugopalan@rite.digital','Employee', 'ROLE_TIME_EMPLOYEE',   'RI2894'),
    -- SC-11 / RULE-021: the only contingent worker. In Fusion this still needs
    -- reloading as WorkerType = C (see TEST_SETUP_GUIDE §3.4); here it is set
    -- directly so the contractor scenarios are testable now.
    t_w('CRI0398', 'Kishore Krovvidi',             'kishore.krovvidi@rite.digital',     'Contractor', 'ROLE_TIME_CONTRACTOR', 'RI2894'),
    -- SC-23: must see an empty menu.
    t_w('RI2985',  'Aadhiseshan Anandavijaya',     'aadhiseshan.a@rite.digital',        'Employee',   'ROLE_TIME_NONE',       'RI2894'),
    -- SC-22: deliberately gets NO allocation, so population records a failed row.
    t_w('RI2249',  'Saicharan Vadlakonda',         'saicharan.vadlakonda@rite.digital', 'Employee',   'ROLE_TIME_EMPLOYEE',   'RI2894')
  );
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    MERGE INTO oc_time_worker w
    USING (SELECT v(i).emp AS employee_id FROM dual) s
       ON (w.employee_id = s.employee_id)
     WHEN MATCHED THEN UPDATE
          SET w.employee_name     = v(i).nm,
              w.email             = v(i).email,
              w.worker_type       = v(i).wtype,
              w.app_role          = v(i).role,
              w.manager_emp_id    = v(i).mgr,
              w.base_country      = 'United States',
              w.std_hours_per_day = 8,
              w.status            = 'Active',
              w.updated_by        = 'TEST_SEED'
     WHEN NOT MATCHED THEN
          INSERT (employee_id, fusion_person_id, employee_name, email, worker_type,
                  app_role, base_country, std_hours_per_day, manager_emp_id,
                  legal_employer, hire_date, status, fusion_synced_on, created_by)
          VALUES (v(i).emp, 'EBS_PER_' || v(i).emp, v(i).nm, v(i).email, v(i).wtype,
                  v(i).role, 'United States', 8, v(i).mgr,
                  'US1 Legal Entity', DATE '2024-01-01', 'Active',
                  SYSTIMESTAMP, 'TEST_SEED');
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('workers: ' || v.COUNT || ' merged.');
END;
/

PROMPT ============================================================
PROMPT [2/8] OC_TIME_PROJECT — 3 test projects
PROMPT ============================================================

-- PRJ-1002 has a DIFFERENT project manager on purpose: RI2900 is split 50/50
-- across PRJ-1001 and PRJ-1002, so moving her hours between them routes the
-- adjustment to two managers — the only way to exercise the dual-approval path
-- in approve_adjustment (RA-014).
--
-- PRJ-1003 is FCP with LEAVE_LOSS_FLAG = 'Y' because that is the entry condition
-- for PROC-006; without it PAGE-006 correctly shows nothing at all.
DECLARE
  TYPE t_p IS RECORD (
    num   VARCHAR2(60),
    nm    VARCHAR2(240),
    cust  VARCHAR2(50),
    cnm   VARCHAR2(240),
    model VARCHAR2(20),
    ll    CHAR(1),
    pm    VARCHAR2(50)
  );
  TYPE t_tab IS TABLE OF t_p;

  v t_tab := t_tab(
    t_p('PRJ-1001', 'Rite O2C Implementation',    'CUST-001', 'Northwind Energy',  'T&M', 'N', 'RI2894'),
    t_p('PRJ-1002', 'Northwind Data Migration',   'CUST-001', 'Northwind Energy',  'T&M', 'N', 'RI9001'),
    t_p('PRJ-1003', 'Cianbro Managed Capacity',   'CUST-002', 'Cianbro',           'FCP', 'Y', 'RI2894')
  );
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    MERGE INTO oc_time_project p
    USING (SELECT v(i).num AS project_number FROM dual) s
       ON (p.project_number = s.project_number)
     WHEN MATCHED THEN UPDATE
          SET p.project_name       = v(i).nm,
              p.customer_id        = v(i).cust,
              p.customer_name      = v(i).cnm,
              p.revenue_model      = v(i).model,
              p.leave_loss_flag    = v(i).ll,
              p.project_manager_id = v(i).pm,
              p.status             = 'Active',
              p.updated_by         = 'TEST_SEED'
     WHEN NOT MATCHED THEN
          INSERT (fusion_project_id, project_number, project_name, customer_id,
                  customer_name, project_type, revenue_model, leave_loss_flag,
                  project_manager_id, country, project_start_date, project_end_date,
                  currency_code, status, fusion_synced_on, created_by)
          VALUES ('FUS_' || v(i).num, v(i).num, v(i).nm, v(i).cust,
                  v(i).cnm, 'Billable', v(i).model, v(i).ll,
                  v(i).pm, 'United States', DATE '2026-01-01', DATE '2026-12-31',
                  'USD', 'Active', SYSTIMESTAMP, 'TEST_SEED');
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('projects: ' || v.COUNT || ' merged.');
END;
/

PROMPT ============================================================
PROMPT [3/8] OC_TIME_TASK — WBS tasks per project
PROMPT ============================================================

-- populate_month pre-populates against the FIRST chargeable WBS task by
-- SORT_ORDER, so the intended default is given sort_order 10.
--
-- NOTE: these carry no expenditure type, because the column does not exist yet
-- (see TEST_SETUP_GUIDE §7). Add EXPENDITURE_TYPE before building the OTL push.
DECLARE
  TYPE t_t IS RECORD (
    proj VARCHAR2(60),
    code VARCHAR2(60),
    nm   VARCHAR2(240),
    ord  NUMBER
  );
  TYPE t_tab IS TABLE OF t_t;

  v t_tab := t_tab(
    t_t('PRJ-1001', 'DEV',     'Development',            10),
    t_t('PRJ-1001', 'TEST',    'Testing',                20),
    t_t('PRJ-1001', 'PM',      'Project Management',      30),
    t_t('PRJ-1002', 'MIGRATE', 'Data Migration',          10),
    t_t('PRJ-1002', 'CUTOVER', 'Cutover Support',         20),
    t_t('PRJ-1003', 'SUPPORT', 'Managed Support',         10),
    t_t('PRJ-1003', 'MAINT',   'Preventive Maintenance',  20)
  );
  v_proj NUMBER;
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    SELECT project_id INTO v_proj
      FROM oc_time_project WHERE project_number = v(i).proj;

    MERGE INTO oc_time_task t
    USING (SELECT v_proj AS project_id, v(i).code AS task_code FROM dual) s
       ON (t.project_id = s.project_id AND UPPER(t.task_code) = UPPER(s.task_code))
     WHEN MATCHED THEN UPDATE
          SET t.task_name  = v(i).nm,
              t.sort_order = v(i).ord,
              t.status     = 'Active',
              t.updated_by = 'TEST_SEED'
     WHEN NOT MATCHED THEN
          INSERT (project_id, fusion_task_id, task_code, task_name, task_type,
                  billable_type, chargeable_flag, selectable_flag, sort_order,
                  status, fusion_synced_on, created_by)
          VALUES (v_proj, 'FUS_' || v(i).proj || '_' || v(i).code,
                  v(i).code, v(i).nm, 'WBS',
                  'Billable', 'Y', 'Y', v(i).ord,
                  'Active', SYSTIMESTAMP, 'TEST_SEED');
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('tasks: ' || v.COUNT || ' merged.');
END;
/

PROMPT ============================================================
PROMPT [4/8] OC_TIME_ALLOCATION — who charges to what
PROMPT ============================================================

-- RI2249 is deliberately absent from this list: a worker with no allocation is
-- what makes populate_month write a NO_WBS_TASK failure, which is what PAGE-010's
-- retry button acts on (SC-22).
--
-- RI3004 is the ONLY 'Unbilled' member of PRJ-1003. V_OC_TS_LLC_ELIGIBLE_COVER
-- only offers unbilled colleagues on the same project, so without her the SC-12
-- cover LOV would be empty and the scenario would stall.
DECLARE
  TYPE t_a IS RECORD (
    proj VARCHAR2(60),
    emp  VARCHAR2(50),
    pct  NUMBER,
    bill VARCHAR2(20),
    role VARCHAR2(120),
    mgr  VARCHAR2(50)
  );
  TYPE t_tab IS TABLE OF t_a;

  v t_tab := t_tab(
    -- PRJ-1001 (T&M, PM = Santosh)
    t_a('PRJ-1001', 'RI2824', 100, 'Billable', 'Technical Analyst',          'RI2894'),
    t_a('PRJ-1001', 'RI2900',  50, 'Billable', 'Senior Software Engineer',   'RI2894'),
    t_a('PRJ-1001', 'RI2963', 100, 'Billable', 'Systems Associate Trainee',  'RI2894'),
    t_a('PRJ-1001', 'CRI0398', 100,'Billable', 'Systems Associate (CWK)',    'RI2894'),
    -- PRJ-1002 (T&M, PM = Navamani) — the other half of RI2900's split
    t_a('PRJ-1002', 'RI2900',  50, 'Billable', 'Senior Software Engineer',   'RI9001'),
    -- PRJ-1003 (FCP + leave loss, PM = Santosh)
    t_a('PRJ-1003', 'RI2935', 100, 'Billable', 'Systems Engineer',           'RI2894'),
    t_a('PRJ-1003', 'RI3004', 100, 'Unbilled', 'Associate Consultant',       'RI2894'),
    t_a('PRJ-1003', 'RI2914', 100, 'Billable', 'Product Engineer',           'RI2894'),
    t_a('PRJ-1003', 'CRI0406',100, 'Billable', 'Principal Architect',        'RI2894'),
    -- Santosh charges his own time too, so his timesheet exists for the RULE-015
    -- test (approved by Navamani, never by himself).
    t_a('PRJ-1001', 'RI2894',  20, 'Billable', 'Product Specialist',         'RI9001')
  );
  v_proj NUMBER;
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    SELECT project_id INTO v_proj
      FROM oc_time_project WHERE project_number = v(i).proj;

    MERGE INTO oc_time_allocation a
    USING (SELECT v_proj AS project_id, v(i).emp AS employee_id,
                  DATE '2026-01-01' AS start_date FROM dual) s
       ON (a.project_id = s.project_id AND a.employee_id = s.employee_id
       AND a.start_date = s.start_date)
     WHEN MATCHED THEN UPDATE
          SET a.alloc_pct            = v(i).pct,
              a.billing_status       = v(i).bill,
              a.client_role          = v(i).role,
              a.approving_manager_id = v(i).mgr,
              a.status               = 'Active',
              a.updated_by           = 'TEST_SEED'
     WHEN NOT MATCHED THEN
          INSERT (fusion_assignment_id, project_id, employee_id, alloc_pct,
                  billing_status, client_role, approving_manager_id,
                  cap_type, cap_hours, start_date, end_date, status,
                  fusion_synced_on, created_by)
          VALUES ('FUS_ASG_' || v(i).proj || '_' || v(i).emp, v_proj, v(i).emp,
                  v(i).pct, v(i).bill, v(i).role, v(i).mgr,
                  CASE WHEN v(i).proj = 'PRJ-1003' THEN 'Monthly' END,
                  CASE WHEN v(i).proj = 'PRJ-1003' THEN 176 END,
                  DATE '2026-01-01', DATE '2026-12-31', 'Active',
                  SYSTIMESTAMP, 'TEST_SEED');
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('allocations: ' || v.COUNT || ' merged (RI2249 intentionally excluded).');
END;
/

PROMPT ============================================================
PROMPT [5/8] CORPORATE calendar — Jun to Aug 2026, US
PROMPT ============================================================

-- SCOPE_KEY must exactly match NVL(deputed_country, base_country) on the worker,
-- because resolve_day looks it up with '=' and not a fuzzy match. Both are
-- 'United States' here; keep them identical when the real sync is built.
DECLARE
  v_from  DATE := DATE '2026-06-01';
  v_to    DATE := DATE '2026-08-31';
  v_work  VARCHAR2(1);
  v_hol   VARCHAR2(200);
  v_n     NUMBER := 0;
BEGIN
  FOR d IN 0 .. (v_to - v_from) LOOP
    DECLARE
      v_date DATE := v_from + d;
    BEGIN
      v_work := CASE WHEN TO_CHAR(v_date,'DY','NLS_DATE_LANGUAGE=ENGLISH')
                          IN ('SAT','SUN') THEN 'N' ELSE 'Y' END;
      v_hol  := NULL;

      -- 4-Jul-2026 is a Saturday, so the US observes Independence Day on
      -- Friday 3-Jul — a mid-week holiday, which is far more useful for testing
      -- than one that lands on an already non-working day.
      IF v_date = DATE '2026-07-03' THEN
        v_work := 'N'; v_hol := 'Independence Day (observed)';
      ELSIF v_date = DATE '2026-06-19' THEN
        v_work := 'N'; v_hol := 'Juneteenth';
      END IF;

      MERGE INTO oc_time_calendar c
      USING (SELECT 'CORPORATE' AS layer, 'United States' AS scope_key,
                    v_date AS cal_date FROM dual) s
         ON (c.layer = s.layer AND c.scope_key = s.scope_key AND c.cal_date = s.cal_date)
       WHEN MATCHED THEN UPDATE
            SET c.is_working_day = v_work,
                c.std_hours      = CASE WHEN v_work = 'Y' THEN 8 ELSE 0 END,
                c.holiday_name   = v_hol,
                c.source_system  = 'TEST_SEED',
                c.synced_on      = SYSTIMESTAMP,
                c.updated_by     = 'TEST_SEED'
       WHEN NOT MATCHED THEN
            INSERT (layer, precedence, scope_key, cal_date, is_working_day,
                    std_hours, holiday_name, source_system, synced_on, created_by)
            VALUES ('CORPORATE', 1, 'United States', v_date, v_work,
                    CASE WHEN v_work = 'Y' THEN 8 ELSE 0 END, v_hol,
                    'TEST_SEED', SYSTIMESTAMP, 'TEST_SEED');
      v_n := v_n + 1;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('corporate calendar: ' || v_n || ' days.');
END;
/

PROMPT ============================================================
PROMPT [6/8] PROJECT / CLIENT / SHIFT layers — precedence test (SC-21)
PROMPT ============================================================

-- Four dates in week 3 of July 2026 (Mon 13 - Sun 19), each proving one layer
-- wins. Precedence is Shift > Client > Project > Corporate.
--
--   Mon 13-Jul  corporate only                        -> working 8h
--   Tue 14-Jul  + project 9h                          -> working 9h   (project beats corporate)
--   Wed 15-Jul  + project 9h + client closed          -> NON-working   (client beats project)
--   Thu 16-Jul  + project 9h + client closed + shift  -> working 8h Night for RI2824 only
--
-- Thursday is the sharpest test: the same date resolves differently per employee,
-- because only RI2824 has a shift row. Everyone else on PRJ-1001 still sees the
-- client closure.
DECLARE
  v_proj  NUMBER;
  v_cust  VARCHAR2(50);

  PROCEDURE put_cal(p_layer VARCHAR2, p_scope VARCHAR2, p_date DATE,
                    p_work VARCHAR2, p_hours NUMBER,
                    p_holiday VARCHAR2 DEFAULT NULL,
                    p_shift VARCHAR2 DEFAULT NULL) IS
  BEGIN
    MERGE INTO oc_time_calendar c
    USING (SELECT p_layer AS layer, p_scope AS scope_key, p_date AS cal_date FROM dual) s
       ON (c.layer = s.layer AND c.scope_key = s.scope_key AND c.cal_date = s.cal_date)
     WHEN MATCHED THEN UPDATE
          SET c.is_working_day = p_work, c.std_hours = p_hours,
              c.holiday_name = p_holiday, c.shift_code = p_shift,
              c.source_system = 'TEST_SEED', c.synced_on = SYSTIMESTAMP,
              c.updated_by = 'TEST_SEED'
     WHEN NOT MATCHED THEN
          INSERT (layer, precedence, scope_key, cal_date, is_working_day, std_hours,
                  holiday_name, shift_code, source_system, synced_on, created_by)
          VALUES (p_layer, 1, p_scope, p_date, p_work, p_hours,
                  p_holiday, p_shift, 'TEST_SEED', SYSTIMESTAMP, 'TEST_SEED');
    -- PRECEDENCE is derived from LAYER by TRG_OC_TC_PRECEDENCE, so the 1 above is
    -- overwritten on the way in and callers cannot set it inconsistently.
  END;
BEGIN
  SELECT project_id, customer_id INTO v_proj, v_cust
    FROM oc_time_project WHERE project_number = 'PRJ-1001';

  -- PROJECT layer: scope key is the project id as text (see resolve_day).
  put_cal('PROJECT', TO_CHAR(v_proj), DATE '2026-07-14', 'Y', 9);
  put_cal('PROJECT', TO_CHAR(v_proj), DATE '2026-07-15', 'Y', 9);
  put_cal('PROJECT', TO_CHAR(v_proj), DATE '2026-07-16', 'Y', 9);

  -- CLIENT layer: scope key is the customer id.
  put_cal('CLIENT', v_cust, DATE '2026-07-15', 'N', 0, 'Client site closed');
  put_cal('CLIENT', v_cust, DATE '2026-07-16', 'N', 0, 'Client site closed');

  -- SHIFT layer: scope key is the employee id. RI2824 only.
  put_cal('SHIFT', 'RI2824', DATE '2026-07-16', 'Y', 8, NULL, 'Night');

  -- A normal shift week for RI2824 so FLD-008 shows something on the grid at all
  -- (RULE-011: one shift per employee per day, read-only from HCM).
  FOR d IN 0 .. 4 LOOP
    put_cal('SHIFT', 'RI2824', DATE '2026-07-06' + d, 'Y', 8, NULL, 'Regular');
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('precedence layers seeded for PRJ-1001 / ' || v_cust || ' / RI2824.');
END;
/

PROMPT ============================================================
PROMPT [7/8] OC_TIME_ABSENCE — leave, LOP and maternity
PROMPT ============================================================

-- populate_month only reads absences with APPROVAL_STATUS = 'Approved', so a
-- Submitted absence would silently never appear on a grid.
--
-- RI3004 deliberately has NO absence: she is the leave-loss COVER, and
-- V_OC_TS_LLC_ELIGIBLE_COVER excludes anyone absent on the day being covered.
DECLARE
  TYPE t_ab IS RECORD (
    emp  VARCHAR2(50),
    dt   DATE,
    typ  VARCHAR2(100),
    hrs  NUMBER,
    lop  CHAR(1),
    mat  CHAR(1)
  );
  TYPE t_tab IS TABLE OF t_ab;

  v t_tab := t_tab(
    -- SC-12: the absentee to be covered on the FCP project.
    t_ab('RI2935', DATE '2026-07-20', 'Vacation',            8, 'N', 'N'),
    t_ab('RI2935', DATE '2026-07-21', 'Vacation',            8, 'N', 'N'),
    -- Proves LOP is excluded from the leave-loss absentee list (RULE-014) and
    -- from the billing-loss numerator (RULE-008).
    t_ab('RI2914', DATE '2026-07-22', 'Leave Without Pay',   8, 'Y', 'N'),
    -- Proves maternity is likewise excluded.
    t_ab('CRI0406',DATE '2026-07-23', 'Maternity Leave',     8, 'N', 'Y'),
    -- A leave row on the primary test employee's own grid (FLD-014): read-only,
    -- not selectable, and it must not be re-sent to OTL.
    t_ab('RI2824', DATE '2026-07-10', 'Vacation',            8, 'N', 'N')
  );
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    MERGE INTO oc_time_absence a
    USING (SELECT v(i).emp AS employee_id, v(i).dt AS absence_date,
                  v(i).typ AS absence_type FROM dual) s
       ON (a.employee_id = s.employee_id AND a.absence_date = s.absence_date
       AND a.absence_type = s.absence_type)
     WHEN MATCHED THEN UPDATE
          SET a.absence_hours = v(i).hrs, a.is_lop = v(i).lop,
              a.is_maternity = v(i).mat, a.approval_status = 'Approved',
              a.updated_by = 'TEST_SEED'
     WHEN NOT MATCHED THEN
          INSERT (fusion_absence_id, employee_id, absence_date, absence_type,
                  absence_hours, is_lop, is_maternity, approval_status,
                  fusion_synced_on, created_by)
          VALUES ('FUS_ABS_' || v(i).emp || '_' || TO_CHAR(v(i).dt,'YYYYMMDD'),
                  v(i).emp, v(i).dt, v(i).typ, v(i).hrs, v(i).lop, v(i).mat,
                  'Approved', SYSTIMESTAMP, 'TEST_SEED');
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('absences: ' || v.COUNT || ' merged.');
END;
/

-- Absence classification map. OC_TIME_ABSENCE.IS_LOP / IS_MATERNITY are booleans
-- with nothing in the build mapping a Fusion absence type name onto them, so the
-- sync would otherwise hard-code the strings. Seeding the mapping as data means a
-- fourth absence type later needs no redeploy.
DECLARE
  PROCEDURE seed(p_code VARCHAR2, p_class VARCHAR2, p_ord NUMBER) IS
  BEGIN
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order, created_by)
    SELECT 'ABSENCE_CLASS', p_code, p_class,
           'Maps a Fusion absence type to IS_LOP / IS_MATERNITY', p_ord, 'TEST_SEED'
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'ABSENCE_CLASS' AND lookup_code = p_code);
  END;
BEGIN
  seed('Vacation',          'NORMAL',    10);
  seed('Sick Leave',        'NORMAL',    20);
  seed('Leave Without Pay', 'LOP',       30);
  seed('Maternity Leave',   'MATERNITY', 40);
  seed('Jury Duty',         'NORMAL',    50);
  DBMS_OUTPUT.PUT_LINE('absence classification map seeded.');
END;
/

PROMPT ============================================================
PROMPT [DEV] Corporate calendar — Mon-Fri fallback (NO Fusion behind this DB)
PROMPT ============================================================

-- TEST DATA ONLY. A Mon-Fri CORPORATE layer so population has something to
-- resolve against on a dev database with no Fusion behind it.
--
-- Never run this against an environment that syncs from Fusion. The rows are
-- invented, they are indistinguishable from real ones in the UI, and because
-- the loader upserts on (layer, scope_key, cal_date) they would block the real
-- Fusion days for the same dates. SOURCE_SYSTEM is set to 'SEED' so they can at
-- least be found and deleted:
--
--   DELETE FROM oc_time_calendar WHERE source_system = 'SEED';
DECLARE
  v_from DATE := TRUNC(ADD_MONTHS(SYSDATE,-1),'MM');
  v_to   DATE := LAST_DAY(ADD_MONTHS(SYSDATE, 1));
  TYPE t_tab IS TABLE OF VARCHAR2(60);
  v_countries t_tab := t_tab('India','United States');
  v_working   VARCHAR2(1);
BEGIN
  FOR c IN 1 .. v_countries.COUNT LOOP
    FOR d IN 0 .. (v_to - v_from) LOOP
      v_working := CASE WHEN TO_CHAR(v_from + d,'DY','NLS_DATE_LANGUAGE=ENGLISH')
                             IN ('SAT','SUN') THEN 'N' ELSE 'Y' END;

      INSERT INTO oc_time_calendar (
        layer, precedence, scope_key, cal_date, is_working_day, std_hours,
        source_system, synced_on, created_by)
      SELECT 'CORPORATE', 1, v_countries(c), v_from + d, v_working,
             CASE WHEN v_working = 'Y' THEN 8 ELSE 0 END,
             'SEED', SYSTIMESTAMP, 'SEED'
        FROM dual
       WHERE NOT EXISTS (SELECT 1 FROM oc_time_calendar
                          WHERE layer     = 'CORPORATE'
                            AND scope_key = v_countries(c)
                            AND cal_date  = v_from + d);
    END LOOP;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('corporate calendar seeded.');
END;
/


PROMPT ============================================================
PROMPT [DEV] OC_TIME_USER — a login for every test worker
PROMPT ============================================================

-- TEST DATA ONLY. One Active login per seeded worker, all with the same
-- password, so the three access levels can be demonstrated by signing in as
-- different people rather than by editing roles between clicks:
--
--   resource  RI2824  sampaul.jeevan@rite.digital        ROLE_TIME_EMPLOYEE
--   manager   RI9001  navamani.solairajan@rite.digital   ROLE_TIME_MANAGER
--   admin     RI2894  Santoshkumar.kanala@rite.digital   ROLE_TIME_ADMIN
--
-- Plus admin@rite.digital: the COMMON ADMIN. It has no worker row on purpose,
-- which is exactly why OC_TIME_USER.APP_ROLE exists as an override - it proves
-- an administrator who is not an HCM worker can still sign in and reach the
-- admin pages.
--
-- Roles are NOT set here for the worker-backed logins. They come from
-- OC_TIME_WORKER.APP_ROLE through V_OC_TIME_SIGNIN, so there is one source of
-- truth and changing a worker's role changes what they can do at next sign-in.
--
-- Password for every account below is 'Rite@123'. Fine for a demo; do not carry
-- these rows into an environment anyone else can reach.
DECLARE
  v_pwd CONSTANT VARCHAR2(30) := 'Rite@123';
  v_n   PLS_INTEGER := 0;

  -- Matched on EMAIL, not EMPLOYEE_ID. Email is the natural key of a login and
  -- is the column carrying UK_OC_TU_EMAIL, so matching on anything else lets a
  -- re-run take the NOT MATCHED branch and collide on the unique constraint.
  PROCEDURE upsert_login(p_emp   IN VARCHAR2,
                         p_email IN VARCHAR2,
                         p_name  IN VARCHAR2,
                         p_role  IN VARCHAR2) IS
    v_email VARCHAR2(255) := LOWER(p_email);
    v_hash  VARCHAR2(128) := oc_time_hash_password(LOWER(p_email), v_pwd);
  BEGIN
    MERGE INTO oc_time_user u
    USING (SELECT v_email AS email FROM dual) s
       ON (LOWER(u.email) = s.email)
     WHEN MATCHED THEN UPDATE
          SET u.employee_id   = p_emp,
              u.full_name     = p_name,
              u.app_role      = p_role,
              u.password_hash = v_hash,
              u.status        = 'Active',
              u.failed_count  = 0,
              u.updated_by    = 'TEST_SEED',
              u.updated_on    = SYSTIMESTAMP
     WHEN NOT MATCHED THEN
          INSERT (employee_id, email, full_name, app_role,
                  password_hash, status, created_by)
          VALUES (p_emp, v_email, p_name, p_role,
                  v_hash, 'Active', 'TEST_SEED');
  END upsert_login;
BEGIN
  -- One login per seeded worker. Email and name are taken from the worker row
  -- itself so the two can never disagree, and APP_ROLE is passed as NULL so the
  -- role keeps coming from OC_TIME_WORKER.
  FOR w IN (SELECT employee_id, employee_name, email
              FROM oc_time_worker
             WHERE email IS NOT NULL
               AND (created_by = 'TEST_SEED' OR updated_by = 'TEST_SEED'))
  LOOP
    upsert_login(w.employee_id, w.email, w.employee_name, NULL);
    v_n := v_n + 1;
  END LOOP;

  -- The common admin: no EMPLOYEE_ID, so the role must be set explicitly here.
  upsert_login(NULL, 'admin@rite.digital',
               'O2C Time Administrator', 'ROLE_TIME_ADMIN');

  DBMS_OUTPUT.PUT_LINE(
    'logins: ' || v_n || ' worker accounts + 1 common admin, password Rite@123.');
END;
/


COMMIT;

PROMPT ============================================================
PROMPT [8/8] Verification
PROMPT ============================================================

SET FEEDBACK OFF
COLUMN employee_id FORMAT A10
COLUMN employee_name FORMAT A28
COLUMN app_role FORMAT A22
COLUMN mgr FORMAT A24
COLUMN purpose FORMAT A34

PROMPT --- Test cast -----------------------------------------------
SELECT w.employee_id, w.employee_name, w.worker_type, w.app_role,
       NVL(m.employee_name,'(none)') AS mgr,
       CASE
         WHEN w.app_role = 'ROLE_TIME_NONE'                THEN 'SC-23 empty menu'
         WHEN w.worker_type = 'Contractor'                 THEN 'SC-11 contractor unbilled'
         WHEN NOT EXISTS (SELECT 1 FROM oc_time_allocation a
                           WHERE a.employee_id = w.employee_id)
                                                           THEN 'SC-22 failed record (no alloc)'
         WHEN w.app_role = 'ROLE_TIME_ADMIN'               THEN 'admin (see admin@rite.digital)'
         WHEN w.employee_id = 'RI2894'                     THEN 'line mgr of 10 + PM of 2'
         WHEN w.app_role = 'ROLE_TIME_MANAGER'             THEN 'RULE-015 approves RI2894'
         ELSE 'employee'
       END AS purpose
  FROM oc_time_worker w
  LEFT JOIN oc_time_worker m ON m.employee_id = w.manager_emp_id
 WHERE w.created_by = 'TEST_SEED' OR w.updated_by = 'TEST_SEED'
 ORDER BY CASE w.app_role
            WHEN 'ROLE_TIME_MANAGER' THEN 1 WHEN 'ROLE_TIME_ADMIN' THEN 2 ELSE 3 END,
          w.employee_id;

PROMPT
PROMPT --- Projects and team size ----------------------------------
COLUMN project_number FORMAT A12
COLUMN project_name FORMAT A30
COLUMN pm FORMAT A26
SELECT p.project_number, p.project_name, p.revenue_model, p.leave_loss_flag,
       m.employee_name AS pm,
       (SELECT COUNT(*) FROM oc_time_allocation a
         WHERE a.project_id = p.project_id AND a.status = 'Active') AS members,
       (SELECT COUNT(*) FROM oc_time_allocation a
         WHERE a.project_id = p.project_id AND a.billing_status = 'Unbilled') AS unbilled
  FROM oc_time_project p
  LEFT JOIN oc_time_worker m ON m.employee_id = p.project_manager_id
 WHERE p.project_number LIKE 'PRJ-%'
 ORDER BY p.project_number;

PROMPT
PROMPT --- Calendar precedence resolved (SC-21 expected results) ---
PROMPT --- 13-Jul 8h | 14-Jul 9h | 15-Jul non-working | 16-Jul 8h Night (RI2824)
COLUMN cal_date FORMAT A12
COLUMN winning_layer FORMAT A12
SELECT TO_CHAR(e.cal_date,'DD-Mon (DY)') AS cal_date,
       e.layer AS winning_layer,
       e.is_working_day,
       e.std_hours,
       e.shift_code,
       e.scope_key
  FROM v_oc_time_calendar_eff e
 WHERE e.rn = 1
   AND e.cal_date BETWEEN DATE '2026-07-13' AND DATE '2026-07-16'
   AND e.scope_key IN ('United States', 'RI2824', 'CUST-001',
                       (SELECT TO_CHAR(project_id) FROM oc_time_project
                         WHERE project_number = 'PRJ-1001'))
 ORDER BY e.cal_date, e.precedence DESC;

PROMPT
PROMPT --- Absences ------------------------------------------------
SELECT a.employee_id, w.employee_name,
       TO_CHAR(a.absence_date,'DD-Mon-YYYY') AS absence_date,
       a.absence_type, a.absence_hours, a.is_lop, a.is_maternity
  FROM oc_time_absence a
  JOIN oc_time_worker w ON w.employee_id = a.employee_id
 WHERE a.created_by = 'TEST_SEED' OR a.updated_by = 'TEST_SEED'
 ORDER BY a.absence_date, a.employee_id;

PROMPT
PROMPT --- Sign-in accounts (all password Rite@123) ----------------
PROMPT --- EFFECTIVE_ROLE is what the app sees; ROLE_SOURCE says where it came from
COLUMN email FORMAT A38
COLUMN full_name FORMAT A26
COLUMN effective_role FORMAT A22
COLUMN role_source FORMAT A14
SELECT u.email, u.full_name, u.status,
       NVL(u.app_role, NVL(w.app_role,'ROLE_TIME_NONE')) AS effective_role,
       CASE WHEN u.app_role IS NOT NULL THEN 'user override'
            WHEN w.app_role IS NOT NULL THEN 'worker'
            ELSE 'unresolved' END AS role_source
  FROM oc_time_user u
  LEFT JOIN oc_time_worker w ON w.employee_id = u.employee_id
 WHERE u.created_by = 'TEST_SEED' OR u.updated_by = 'TEST_SEED'
 ORDER BY CASE NVL(u.app_role, NVL(w.app_role,'ROLE_TIME_NONE'))
            WHEN 'ROLE_TIME_ADMIN'   THEN 1
            WHEN 'ROLE_TIME_MANAGER' THEN 2
            ELSE 3 END,
          u.email;

PROMPT
PROMPT --- Row counts ----------------------------------------------
SELECT 'workers'      AS item, COUNT(*) AS cnt FROM oc_time_worker
UNION ALL SELECT 'projects',      COUNT(*) FROM oc_time_project
UNION ALL SELECT 'tasks',         COUNT(*) FROM oc_time_task
UNION ALL SELECT 'allocations',   COUNT(*) FROM oc_time_allocation
UNION ALL SELECT 'absences',      COUNT(*) FROM oc_time_absence
UNION ALL SELECT 'calendar days', COUNT(*) FROM oc_time_calendar
UNION ALL SELECT 'open periods',  COUNT(*) FROM oc_time_period WHERE status = 'Open'
UNION ALL SELECT 'logins',        COUNT(*) FROM oc_time_user;

SET FEEDBACK ON

PROMPT
PROMPT ============================================================
PROMPT 90_test_seed complete.
PROMPT
PROMPT Next, to build the July grids and drive the scenarios:
PROMPT
PROMPT   -- find the open period id
PROMPT   SELECT period_id, period_name FROM oc_time_period WHERE status = 'Open';
PROMPT
PROMPT   -- populate, then exercise the jobs
PROMPT   POST /oc/time/admin/jobs/populate/{periodId}
PROMPT   POST /oc/time/admin/jobs/defaulting/{periodId}      -- SC-06, SC-13
PROMPT   POST /oc/time/approval/salaryhold/run/{periodId}    -- SC-13
PROMPT   POST /oc/time/approval/llc/generate                 -- SC-12
PROMPT
PROMPT Expect one FAILED record after populate: RI2249 has no allocation,
PROMPT which is deliberate and is the SC-22 retry case.
PROMPT ============================================================
