--==============================================================
-- time/10_seed.sql
-- O2C Timesheet Module — Reference seed data
--
-- Everything here comes verbatim from the Data_Dictionaries and
-- Environment_Config sheets. Re-runnable: every insert is guarded by a NOT
-- EXISTS so re-seeding never duplicates and never overwrites a value finance
-- has since changed.
--
-- Seeds:
--   1  timesheet_status      9 statuses
--   2  flag                  8 workflow flags
--   3  rejection_reason      Manager / Client / Absence
--   4  unbilled_reason       common tasks + Billing Loss
--   5  shift_type            Regular / Night / Early / Split
--   6  accrual_entry_type    Actual / Default / Reversal / Adjustment
--   7  cutoff_type, period_status, billing_type, project_model, project_type
--   8  INTEGRATION           the PAGE-012 reference catalogue (INT-001..015)
--   9  OC_TIME_TASK          the 4 common non-billable tasks + Leave
--  10  OC_TIME_PROJECT       the Organization (Non-Billable) project, PRJ-ORG
--  11  OC_TIME_CONFIG        CFG-010 .. CFG-015
--
-- Idempotent. Depends on: time/01 .. time/09
--==============================================================
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT ============================================================
PROMPT [1/11] timesheet_status — the 7 statuses
PROMPT ============================================================

-- Revised 30-Jul-2026, down from 9. 'Late submission' became a FLAG (the week is
-- still 'Submitted' because the manager must act on it), and 'Manager Defaulted'
-- folded into 'Defaulted' with DEFAULTED_BY recording which cut-off was missed.
DECLARE
  TYPE t_row IS RECORD (c VARCHAR2(60), m VARCHAR2(200), n VARCHAR2(400), o NUMBER);
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('Not yet submitted',       'Employee has not submitted',                     'Time (7 statuses)', 10),
    t_row('Submitted',               'Submitted, pending manager',                     'Time', 20),
    t_row('Approved',                'Approved by manager',                            'Time', 30),
    t_row('Rejected',                'Rejected by manager, back with the employee',    'Time', 40),
    t_row('Defaulted',               'A cut-off was missed - see DEFAULTED_BY',        'Time', 50),
    t_row('Overridden and approved', 'Manager edited then approved',                   'Time', 60),
    t_row('Closed',                  'Month confirmed / period closed',                'Time', 70));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'TIMESHEET_STATUS', v(i).c, v(i).m, v(i).n, v(i).o FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'TIMESHEET_STATUS'
                          AND lookup_code = v(i).c);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('timesheet_status seeded.');
END;
/

PROMPT ============================================================
PROMPT [2/11] flag — the 6 workflow flags
PROMPT ============================================================

-- Revised 30-Jul-2026, down from 8:
--   'Cancel'                   -> renamed 'Reversal'
--   'Correction'               -> dropped; OC_TS_APPROVAL logs a 'Resubmit'
--                                 action, which IS the audit trail
--   'Contractor Unbilled hours'-> dropped; out of scope for the time module
--
-- The first four are sticky (they record that something happened). Reversal and
-- Adjustment are derived from the week's entries by TRG_OC_TSW_TOTALS.
DECLARE
  TYPE t_row IS RECORD (c VARCHAR2(60), m VARCHAR2(200), o NUMBER);
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('Defaulted',             'Weekly or delivery cut-off missed',           10),
    t_row('Late submission',       'Submitted/resubmitted after the weekly cut-off; status stays Submitted', 20),
    t_row('Advance closure',       'Approved early (month-level)',                30),
    t_row('Overridden & approved', 'Manager edited & approved',                   40),
    t_row('Reversal',              'Old line reversed (-) retro',                 50),
    t_row('Adjustment',            'New line added (+) retro',                    60));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'WORKFLOW_FLAG', v(i).c, v(i).m, 'Flags', v(i).o FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'WORKFLOW_FLAG' AND lookup_code = v(i).c);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('workflow flags seeded.');
END;
/

PROMPT ============================================================
PROMPT [3/11] rejection_reason (FLD-057 / RULE-013)
PROMPT ============================================================

DECLARE
  TYPE t_tab IS TABLE OF VARCHAR2(60);
  v t_tab := t_tab('Manager','Client','Absence');
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'REJECTION_REASON', v(i), v(i) || '-driven rejection', 'Approval', i * 10 FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'REJECTION_REASON' AND lookup_code = v(i));
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [4/11] unbilled_reason
PROMPT ============================================================

-- 'Billing Loss' is SELECTABLE='N': it is the automatic shortfall reason and is
-- never editable (RULE-009 / FLD-015).
DECLARE
  TYPE t_row IS RECORD (c VARCHAR2(60), m VARCHAR2(200), s VARCHAR2(1), o NUMBER);
  TYPE t_tab IS TABLE OF t_row;
  v t_tab := t_tab(
    t_row('Onboarding',     'Onboarding (non-billable)',        'Y', 10),
    t_row('Training',       'Training (non-billable)',          'Y', 20),
    t_row('Travel',         'Travel (non-billable)',            'Y', 30),
    -- Code left as 'Client Holiday'. The functional owner wrote "customer
    -- holiday" (10-Aug-2026) and that is the same bucket, but this VALUE is
    -- what OC_TS_ENTRY.UNBILLED_REASON stores and what the matching common
    -- task is called (RULE-002: the reason IS the task), so renaming it is a
    -- data migration plus a task rename, not a label change. The wording is
    -- carried in the meaning instead. Confirm before renaming the code.
    t_row('Client Holiday', 'Customer site closed (non-billable)','Y', 40),
    -- The fifth SELECTABLE reason, held open deliberately (functional owner,
    -- 10-Aug-2026: "Travel, training, onboarding, customer holiday, last one is
    -- open for future use"). Seeded rather than left absent so the screen shows
    -- five buckets from day one and adding the real reason is a rename, not a
    -- release.
    t_row('Other',          'Reserved - name this before use',  'Y', 50),
    -- NOT one of the five. Billing Loss is the automatic RULE-009 shortfall,
    -- computed rather than chosen, which is why SELECTABLE is 'N'. Absence is
    -- likewise not an unbilled reason - leave is its own row from HR (RULE-008).
    t_row('Billing Loss',   'Auto shortfall - non-editable',    'N', 60));
BEGIN
  FOR i IN 1 .. v.COUNT LOOP
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note,
                                selectable, sort_order)
    SELECT 'UNBILLED_REASON', v(i).c, v(i).m, 'Time entry', v(i).s, v(i).o FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'UNBILLED_REASON' AND lookup_code = v(i).c);
  END LOOP;
END;
/

PROMPT ============================================================
PROMPT [5/11] shift_type, accrual_entry_type, and the small dictionaries
PROMPT ============================================================

DECLARE
  PROCEDURE seed(p_type VARCHAR2, p_code VARCHAR2, p_meaning VARCHAR2,
                 p_note VARCHAR2, p_order NUMBER) IS
  BEGIN
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT p_type, p_code, p_meaning, p_note, p_order FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = p_type AND lookup_code = p_code);
  END;
BEGIN
  -- SHIFT_TYPE is deliberately NOT seeded.
  --
  -- Shifts, workday patterns, work schedules and the calendar are all Fusion
  -- data (RA-005). This dictionary used to seed 'Regular / Night / Early /
  -- Split', which matches nothing in Fusion — the real categories on
  -- HTS_SHIFTS_VL.SHIFT_CATEGORY are ORA_HTS_SHIFT_DAY, ORA_HTS_SHIFT_NIGHT and
  -- customer-specific codes such as GSE_HTS_SHIFT_24HR. Invented codes in a
  -- lookup table are worse than no codes: they read as authoritative and they
  -- would never join to a real shift.
  --
  -- Nothing consumed it either. The app resolves a day's shift from
  -- OC_TIME_CALENDAR.SHIFT_CODE (OC_TIME_PKG.resolve_day), which the Fusion sync
  -- fills — the type is display metadata carried alongside, not a validation
  -- list. See integration/bip: SHIFTS, WORK_PATTERNS, WORK_SCHEDULES,
  -- WORKER_SHIFTS.

  -- accrual_entry_type (INT-014 ENTRY_TYPE)
  seed('ACCRUAL_ENTRY_TYPE','Actual',
       'Actual submitted hours','Accrual table ENTRY_TYPE',10);
  seed('ACCRUAL_ENTRY_TYPE','Default',
       'Auto-defaulted hours (missed cut-off)','Accrual table ENTRY_TYPE',20);
  seed('ACCRUAL_ENTRY_TYPE','Reversal',
       'Reversal (-) of prior entry (retro / default correction)','Accrual table ENTRY_TYPE',30);
  seed('ACCRUAL_ENTRY_TYPE','Adjustment',
       'Re-post (+) to the corrected project/task/day','Accrual table ENTRY_TYPE',40);

  -- cutoff_type
  seed('CUTOFF_TYPE','Weekly',  'Timesheet weekly cut-off','Period Definition',10);
  seed('CUTOFF_TYPE','Delivery','Manager approve by',      'Period Definition',20);
  seed('CUTOFF_TYPE','Finance', 'Finance cut-off',         'Period Definition',30);
  seed('CUTOFF_TYPE','Book',    'Book closure',            'Period Definition',40);
  seed('CUTOFF_TYPE','MEC',     'Month-end close',         'Period Definition',50);
  seed('CUTOFF_TYPE','Payroll', 'Payroll cut-off',         'Period Definition',60);
  seed('CUTOFF_TYPE','Client',  'Client cut-off (MSA; SOW overrides)','Period Definition',70);

  -- period_status
  seed('PERIOD_STATUS','Open',  'Period open (one at a time)','Period Control',10);
  seed('PERIOD_STATUS','Closed','Period closed',              'Period Control',20);

  -- billing_type
  seed('BILLING_TYPE','Billable',    'Billable time',    'Time',10);
  seed('BILLING_TYPE','Non-billable','Non-billable time','Time',20);

  -- project_model (revenue models)
  seed('PROJECT_MODEL','T&M',      'Time & Material',      'Projects',10);
  seed('PROJECT_MODEL','FCP',      'Fixed Capacity',       'Projects',20);
  seed('PROJECT_MODEL','Milestone','Milestone-based',      'Projects',30);

  -- project_type
  seed('PROJECT_TYPE','Billable',
       'Employee''s own project; log common tasks in-project','Projects',10);
  seed('PROJECT_TYPE','Organization',
       'Common project assigned to ALL employees; non-billable staff log here','Projects (PRJ-ORG)',20);

  -- calendar_precedence (single informational row rendered on PAGE-009)
  seed('CALENDAR_PRECEDENCE','Shift > Client > Project > Corporate',
       'Override order','Calendar (BRD 4.1)',10);

  -- access_role
  seed('ACCESS_ROLE','ROLE_TIME_EMPLOYEE',  'Employee',  'Personas',10);
  seed('ACCESS_ROLE','ROLE_TIME_CONTRACTOR','Contractor','Personas',20);
  seed('ACCESS_ROLE','ROLE_TIME_MANAGER',   'Manager',   'Personas',30);
  seed('ACCESS_ROLE','ROLE_TIME_ADMIN',     'Admin',     'Personas',40);
  seed('ACCESS_ROLE','ROLE_TIME_NONE',      'None',      'Personas',50);

  DBMS_OUTPUT.PUT_LINE('small dictionaries seeded.');
END;
/

PROMPT ============================================================
PROMPT [6/11] INTEGRATION — PAGE-012 reference catalogue
PROMPT ============================================================

-- MEANING is a pipe-delimited quad that V_OC_TIME_INTEGRATION splits into
-- FLD-110..FLD-113: fusion_source | object_usage | rest_resource | load_pattern
-- LOOKUP_CODE is 'INT-xxx|Area'.
DECLARE
  PROCEDURE seed(p_code VARCHAR2, p_meaning VARCHAR2, p_note VARCHAR2, p_order NUMBER) IS
  BEGIN
    INSERT INTO oc_time_lookup (lookup_type, lookup_code, meaning, usage_note, sort_order)
    SELECT 'INTEGRATION', p_code, p_meaning, p_note, p_order FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_lookup
                        WHERE lookup_type = 'INTEGRATION' AND lookup_code = p_code);
  END;
BEGIN
  seed('INT-001|Prepopulate',
       'Fusion HCM|Worker & assignment master|/hcmRestApi/../workers|Incremental upsert on PersonNumber',
       'Use workers (not emps) for contingent/terminated. PersonNumber->PersonId hop.', 10);
  seed('INT-002|Prepopulate',
       'Fusion PPM|WBS tasks - the chargeable COLUMNS of the grid|/fscmRestApi/../projects/{ProjectId}/child/Tasks|Incremental upsert on task id',
       'Project x WBS task.', 20);
  seed('INT-003|Prepopulate',
       'Fusion PPM|Project resource assignments - what each employee can charge to|/fscmRestApi/../projectResourceAssignments|Incremental upsert on assignment id',
       'Combine with Tasks to build the grid.', 30);
  seed('INT-004|Prepopulate',
       'Fusion HCM|Work schedules - which days & expected hours|/hcmRestApi/../timeRecordGroups?groupType=Schedule|Scheduled sync',
       'Confirm read path via /describe; scheduleRequests may be write-only.', 40);
  seed('INT-005|Prepopulate',
       'Fusion HCM|Org / absence calendars - holidays & working patterns|/hcmRestApi/../absenceCalendars|Scheduled sync',
       'Needed only if the app computes expected hours itself.', 50);
  seed('INT-006|Prepopulate',
       'Fusion HCM|Approved absences so employees do not double-enter|/hcmRestApi/../absences|Incremental by personId + startDate',
       'Feeds Leave rows & Leave-Loss. Leave is HR-sourced, not selectable.', 60);
  seed('INT-007|Push',
       'Fusion OTL (HCM)|SYSTEM OF RECORD - push approved time|/hcmRestApi/../timeRecordEventRequests|POST processMode TIME_SUBMIT',
       'Primary surface. OTL then feeds Project Costing & Payroll natively.', 70);
  seed('INT-008|Readback',
       'Fusion OTL (HCM)|Statuses / messages / attributes back from OTL|/hcmRestApi/../timeRecordGroups (+ timeRecords, timeAttributes)|GET by personNumber & date range',
       'Reconciliation read-back.', 80);
  seed('INT-009|Push',
       'Fusion OTL (HCM)|Mark entries transferred after a consumer takes the data|/hcmRestApi/../statusChangeRequests|POST consumerCode e.g. PYR',
       'Status reconcile.', 90);
  seed('INT-010|Audit',
       'Fusion PPM|Project costing - auto-populated once OTL is interfaced|/fscmRestApi/../projectCosts, /projectExpenditureBatches|GET only (no external create)',
       'Query/audit only.', 100);
  seed('INT-011|Reference',
       'Fusion HCM|Payroll reference / validation|/hcmRestApi/../payrollRelationships/../payrollAssignments|GET reference',
       'Payroll consumes via OTL extract/load, not a direct write.', 110);
  seed('INT-012|Audit',
       'Fusion Financials|AR / GL audit visibility|/fscmRestApi/../receivablesInvoices, /journalBatches/child/journalHeaders|GET audit',
       'Confirms approved time reached billing/GL.', 120);
  seed('INT-013|Investigate',
       'Fusion Enterprise Contracts|CLM - NOT a direct time consumer|(contracts / project billing config)|GET (investigate)',
       'Contract-billing terms live in Projects/Project Billing.', 130);
  seed('INT-014|Accrual',
       'O2C Accrual (this platform)|Consolidated timesheet + day-wise adjustments|ACCRUAL.XX_O2C_TIMESHEET_ACCRUAL_IF|Interface table filled on confirm; accrual PULLS',
       'Manager-confirmed months only. Default-hour corrections post as adjustments.', 140);
  seed('INT-015|Persistence',
       'O2C Time (ATP)|The app''s own transactional store|ORDS oc.time / oc.time.approval / oc.time.admin|Bidirectional REST',
       'Harden anonymous -> key/OAuth for PROD (RA-002).', 150);
  DBMS_OUTPUT.PUT_LINE('integration catalogue seeded.');
END;
/

PROMPT ============================================================
PROMPT [7/11] OC_TIME_TASK — common non-billable tasks
PROMPT ============================================================

-- These four appear in EVERY project and in the Organization project
-- (V_OC_TS_TASK_LOV cross-joins them). 'Leave' is seeded too but with
-- SELECTABLE_FLAG='N' so it can hold HR-sourced absence hours while never
-- appearing in the employee LOV (RULE-008).
DECLARE
  PROCEDURE seed(p_code VARCHAR2, p_name VARCHAR2, p_sel VARCHAR2, p_order NUMBER) IS
  BEGIN
    INSERT INTO oc_time_task (project_id, task_code, task_name, task_type,
                              billable_type, unbilled_reason, selectable_flag,
                              sort_order, created_by)
    SELECT NULL, p_code, p_name, 'COMMON', 'Non-billable', p_name, p_sel,
           p_order, 'SEED'
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_task
                        WHERE task_type = 'COMMON'
                          AND UPPER(task_code) = UPPER(p_code));
  END;
BEGIN
  seed('ONBOARDING',     'Onboarding',     'Y', 10);
  seed('TRAINING',       'Training',       'Y', 20);
  seed('TRAVEL',         'Travel',         'Y', 30);
  seed('CLIENT_HOLIDAY', 'Client Holiday', 'Y', 40);
  seed('LEAVE',          'Leave',          'N', 50);   -- HR-sourced only
  seed('BILLING_LOSS',   'Billing Loss',   'N', 60);   -- automatic shortfall
  DBMS_OUTPUT.PUT_LINE('common tasks seeded.');
END;
/

PROMPT ============================================================
PROMPT [8/11] OC_TIME_PROJECT — nothing seeded (PRJ-ORG removed)
PROMPT ============================================================

-- PRJ-ORG IS NO LONGER SEEDED. Decided 11-Aug-2026.
--
-- It was the Organization (Non-Billable) project, implicitly everyone's
-- (FLD-006) -- the place non-project time was booked. Every project in this
-- schema is now to come from Fusion, and PRJ-ORG never did: it existed only
-- here, so it could not be costed, reported on, or reconciled against PPM.
--
-- The time it carried does not disappear -- it moves. Non-project hours are now
-- booked against the employee's REAL project with an UNBILLED_REASON saying why
-- they are not billable, which is a better record than a synthetic project:
-- the hours stay attached to the engagement they were incurred on, and the
-- reason is per line rather than per project.
--
-- 23_unbilled_reason_per_line.sql makes the reason settable on any line and
-- lets it drive BILLABLE_TYPE. Removing this seed without that change would
-- leave non-project time with nowhere to go at all.
BEGIN
  NULL;   -- intentionally nothing; see above
END;
/

PROMPT ============================================================
PROMPT [9/11] OC_TIME_CONFIG — business configuration
PROMPT ============================================================

DECLARE
  PROCEDURE seed(p_name VARCHAR2, p_type VARCHAR2, p_value VARCHAR2, p_desc VARCHAR2) IS
  BEGIN
    INSERT INTO oc_time_config (config_name, config_type, config_value, description, created_by)
    SELECT p_name, p_type, p_value, p_desc, 'SEED' FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_config
                        WHERE config_name = p_name AND scope_key = 'GLOBAL');
  END;
BEGIN
  seed('weeklyCutoffDayTime',   'business',    'Monday 17:00',
       'CFG-010 Timesheet cut-off; the defaulting job runs in base-location local time.');
  seed('backdatingWindowMonths','business',    '3',
       'CFG-011 Adjustment / backdated Project-WBS window (BRD 4.2.1).');
  seed('salaryHoldReleaseDays', 'business',    '60',
       'CFG-012 Days an employee/contractor can resubmit a defaulted timesheet.');
  seed('standardHoursSource',   'business',    'HCM/Corporate by country',
       'CFG-013 Standard hours by country of work.');
  seed('apiTimeoutMs',          'timeout',     '8000',
       'CFG-014 Default REST timeout.');
  seed('featureWeekendEditable','feature_flag','true',
       'CFG-015 Sat/Sun editable, default 0 (RULE-012).');
  seed('contractorResubmitDays','business',    '60',
       'FLD-087 Days a contractor can resubmit a defaulted timesheet.');
  seed('maxClientDocBytes',     'business',    '26214400',
       'Security PAGE-002 attachment policy: 25MB ceiling.');
  -- POET's E. Configuration rather than a per-task value, and that is a finding
  -- rather than a shortcut: expenditure type is not an attribute of the task in
  -- Fusion, it comes from transaction controls — and PJF_TXN_CONTROLS does not
  -- exist on this pod (verified 02-Aug-2026; only PJC_TXN_CONTROLS_STAGE, a
  -- staging table). So there is nothing per task to read.
  --
  -- 'Regular Labor' is one of 30 types on the pod carrying UOM = HOURS, which is
  -- the constraint that matters: several types named '...Labor' are DOLLARS
  -- (Craft Labor Straight Time, Consultant Labor...) and would be wrong for a
  -- timesheet. Run the EXP_TYPES extract to see the legal values before
  -- changing this.
  seed('defaultExpenditureType','business',    'Regular Labor',
       'POET expenditure type for the OTL push (INT-007). Must be a Fusion '
       || 'expenditure type with UOM = HOURS; see the EXP_TYPES extract.');
  DBMS_OUTPUT.PUT_LINE('config seeded.');
END;
/

PROMPT ============================================================
PROMPT [10/11] OC_TIME_PERIOD — the current and next period
PROMPT ============================================================

-- Bootstrap so the app is usable immediately: the current month Open and the
-- next month Closed. RULE-017 guarantees only one Open row, so the guard also
-- protects against seeding a second Open period into a live environment.
DECLARE
  v_open NUMBER;

  PROCEDURE seed_period(p_base DATE, p_status VARCHAR2) IS
    v_start DATE := TRUNC(p_base,'MM');
    v_end   DATE := LAST_DAY(TRUNC(p_base,'MM'));
    v_name  VARCHAR2(30) := UPPER(TO_CHAR(v_start,'MON-YYYY'));
  BEGIN
    INSERT INTO oc_time_period (
      period_name, period_year, period_month, status,
      start_date, end_date, accounting_date,
      ts_cutoff_day, ts_cutoff_time,
      delivery_cutoff, finance_cutoff, book_closure, mec_close,
      client_cutoff, payroll_cutoff,
      advance_close, contractor_resubmit_days, hold_release_days,
      adjustment_months, backdated_months, created_by)
    SELECT v_name,
           EXTRACT(YEAR FROM v_start), EXTRACT(MONTH FROM v_start), p_status,
           v_start, v_end, v_end,
           'Monday', '17:00',
           v_end + 3,     -- delivery cut-off
           v_end + 5,     -- finance cut-off
           v_end + 7,     -- book closure
           v_end + 8,     -- MEC close
           v_end + 10,    -- client cut-off
           v_end + 2,     -- payroll cut-off
           'N', 60, 60, 3, 3, 'SEED'
      FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM oc_time_period WHERE period_name = v_name);
  END;
BEGIN
  SELECT COUNT(*) INTO v_open FROM oc_time_period WHERE status = 'Open';

  -- Only claim 'Open' if nothing is open yet. Kept after RULE-017 was relaxed
  -- (04-Aug-2026): several months MAY now be open, but a seed run should not
  -- decide that — opening a month is a deliberate act, see 13_open_periods.sql.
  seed_period(SYSDATE, CASE WHEN v_open = 0 THEN 'Open' ELSE 'Closed' END);
  seed_period(ADD_MONTHS(SYSDATE, 1),  'Closed');
  seed_period(ADD_MONTHS(SYSDATE, -1), 'Closed');
  DBMS_OUTPUT.PUT_LINE('periods seeded.');
END;
/

PROMPT ============================================================
PROMPT [11/11] Corporate calendar — NOT seeded (sourced from Fusion)
PROMPT ============================================================

-- Deliberately empty.
--
-- Working days, shifts, work patterns and holidays are Fusion data (RA-005:
-- "calendars are sourced from Oracle Fusion; no calendar authoring in the Time
-- module"). Seeding a Mon-Fri baseline here would put rows in the CORPORATE
-- layer that look authoritative but are invented, and because the loader
-- upserts on (layer, scope_key, cal_date) those invented rows would then block
-- the real ones for the same days.
--
-- The four Fusion sources and how they arrive:
--
--   work shift      HTS_SHIFTS_VL               -> SHIFTS extract
--   work pattern    HTS_WORK_PATTERNS_VL        -> WORK_PATTERNS extract
--                   + HTS_WORK_PATTERN_SHIFTS
--   work schedule   PER_SCHEDULE_ASSIGNMENTS    -> WORK_SCHEDULES extract
--   work calendar   PER_CALENDAR_EVENTS         -> CALENDAR extract
--
--   resolved day    HTS_SCHEDULE_SHIFTS_VL      -> WORKER_SHIFTS extract
--                   (person x date x shift, already expanded by Fusion)
--
-- Load them with integration/bip/run_extract.py, then
--   POST /oc/time/admin/calendar/sync/{CORPORATE|PROJECT|CLIENT|SHIFT}
--
-- For a local dev database with no Fusion behind it, 90_test_seed.sql has a
-- Mon-Fri fallback. It is test data and is not part of this installer.

DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM oc_time_calendar;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE(
      'calendar: empty - load from Fusion before running population, or run '
      || '90_test_seed.sql for a dev fallback.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('calendar: ' || v_n || ' day(s) already present.');
  END IF;
END;
/

COMMIT;

PROMPT
PROMPT ============================================================
PROMPT time/10_seed complete.
PROMPT ============================================================
