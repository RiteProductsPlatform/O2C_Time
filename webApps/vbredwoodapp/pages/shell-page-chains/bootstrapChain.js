/* O2C Timesheet Module — shell bootstrap */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Resolves the signed-in worker and establishes the session context every
   * other page depends on:
   *
   *   employeeId / employeeName / currentRole / managerEmpId / workerType
   *   openPeriodId / selectedPeriodId  (the single Open period, RULE-017)
   *   periodOptionsArray               (the month LOV, RULE-004 / RULE-007)
   *   actingManagerId + managerOptions (ACT-011 switcher, managers only)
   *   navItemsArray                    (the RBAC menu, RULE-022)
   *
   * RULE-022: the role decides the whole menu. An email that does not resolve
   * to an active worker is treated as ROLE_TIME_NONE — an empty menu and a
   * clear message — never as a default employee, because guessing here would
   * expose someone else's time data.
   */
  class bootstrapChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const email = $page.functions.currentUserEmail();
      $application.variables.currentEmail = email;

      if (!email) {
        $application.variables.currentRole = 'ROLE_TIME_NONE';
        $page.variables.signInError =
          'Could not determine the signed-in user. Please sign in again.';
        $page.variables.navItemsArray = [];
        $page.variables.navReady = true;
        return;
      }

      // ── 1. Resolve the worker ────────────────────────────────
      // OC_TIME_WORKER is keyed on PersonNumber, so look the worker up by the
      // email the identity provider gave us. Cache-busted: the role must never
      // be served from a 304 after an administrator changes it.
      let worker = null;
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMe',
          uriParams: { employeeId: email, _t: Date.now() },
        });

        if (resp.ok && resp.body && resp.body.items && resp.body.items.length) {
          worker = resp.body.items[0];
        } else if (!resp.ok) {
          $application.variables.currentRole = 'ROLE_TIME_NONE';
          $page.variables.signInError =
            'The timesheet service refused the sign-in lookup (' +
            (resp.status || 'no status') + '). Please contact your administrator.';
          $page.variables.navItemsArray = [];
          $page.variables.navReady = true;
          return;
        }
      } catch (e) {
        $application.variables.currentRole = 'ROLE_TIME_NONE';
        $page.variables.signInError =
          'The timesheet service is unavailable. Please try again shortly.';
        $page.variables.navItemsArray = [];
        $page.variables.navReady = true;
        return;
      }

      if (!worker) {
        $application.variables.currentRole = 'ROLE_TIME_NONE';
        $page.variables.signInError =
          'No active worker record was found for ' + email +
          '. Contact your administrator to be set up in the Time module.';
        $page.variables.navItemsArray = [];
        $page.variables.navReady = true;
        return;
      }

      $application.variables.employeeId     = worker.employee_id || worker.EMPLOYEE_ID;
      $application.variables.employeeName   = worker.employee_name || worker.EMPLOYEE_NAME;
      $application.variables.currentRole    = worker.app_role || worker.APP_ROLE || 'ROLE_TIME_NONE';
      $application.variables.managerEmpId   = worker.manager_emp_id || worker.MANAGER_EMP_ID || '';
      $application.variables.workerType     = worker.worker_type || worker.WORKER_TYPE || 'Employee';
      $application.variables.stdHoursPerDay = worker.std_hours_per_day || worker.STD_HOURS_PER_DAY || 8;
      $application.variables.totalAllocPct  = worker.total_alloc_pct || worker.TOTAL_ALLOC_PCT || 0;
      $application.variables.openPeriodId   = worker.open_period_id || worker.OPEN_PERIOD_ID || null;

      // A manager reviews their own team by default (ACT-011 can change this).
      $application.variables.actingManagerId = $application.variables.employeeId;

      const role = $application.variables.currentRole;

      // ── 2. Build the RBAC menu (RULE-022) ────────────────────
      // Entitlement is expressed by omission: the role simply never receives an
      // item it may not open. navigateChain repeats the check for typed URLs.
      const MY_TIME = [
        { id: 'my-timesheet',        label: 'My Timesheet',          icon: 'oj-ux-ico-calendar' },
        { id: 'client-timesheets',   label: 'Client Timesheets',     icon: 'oj-ux-ico-file-text' },
      ];
      const TEAM = [
        { id: 'team-approvals',      label: 'Team Approvals',        icon: 'oj-ux-ico-approval' },
        { id: 'leave-loss-coverage', label: 'Leave Loss Coverage',   icon: 'oj-ux-ico-user-group' },
        { id: 'salary-stopping',     label: 'Salary Stopping',       icon: 'oj-ux-ico-currency-dollar' },
      ];
      const ADMIN = [
        { id: 'calendar-sync',       label: 'Calendar (Fusion Sync)', icon: 'oj-ux-ico-calendar-clock' },
        { id: 'sync-status',         label: 'Sync Status',            icon: 'oj-ux-ico-activity' },
        { id: 'accrual-integration', label: 'Accrual Integration',    icon: 'oj-ux-ico-data-flow' },
        { id: 'integrations',        label: 'Integrations',           icon: 'oj-ux-ico-plug' },
      ];

      let navItems = [];
      if (role === 'ROLE_TIME_ADMIN') {
        navItems = MY_TIME.concat(TEAM, ADMIN);
      } else if (role === 'ROLE_TIME_MANAGER') {
        navItems = MY_TIME.concat(TEAM);
      } else if (role === 'ROLE_TIME_EMPLOYEE' || role === 'ROLE_TIME_CONTRACTOR') {
        navItems = MY_TIME.slice();
      }
      // iconClass is precomputed so the nav template binds a plain field —
      // S1 forbids string concatenation inside a binding.
      $page.variables.navItemsArray = navItems.map((n) => ({
        id: n.id,
        label: n.label,
        icon: n.icon,
        iconClass: n.icon + ' oj-navigationlist-item-icon',
      }));

      // ── 3. Period LOV ────────────────────────────────────────
      try {
        const per = await Actions.callRest(context, {
          endpoint: 'oc_time/getPeriods',
          uriParams: { _t: Date.now() },
        });

        if (per.ok && per.body && per.body.items) {
          const rows = per.body.items;

          $application.variables.periodOptionsArray = rows.map((r) => ({
            value: r.period_id || r.PERIOD_ID,
            label: r.period_name || r.PERIOD_NAME,
            periodState: r.period_state || r.PERIOD_STATE,
            editableFlag: r.editable_flag || r.EDITABLE_FLAG,
            adjustmentAllowed: r.adjustment_allowed || r.ADJUSTMENT_ALLOWED,
          }));

          // Default to the Open period; fall back to the newest row so the page
          // is never left with an empty selector.
          const open = rows.find((r) => (r.period_state || r.PERIOD_STATE) === 'Open') || rows[0];
          if (open) {
            $application.variables.selectedPeriodId   = open.period_id || open.PERIOD_ID;
            $application.variables.selectedPeriodName = open.period_name || open.PERIOD_NAME;
            $application.variables.periodEditable     = open.editable_flag || open.EDITABLE_FLAG;
            $application.variables.adjustmentAllowed  = open.adjustment_allowed || open.ADJUSTMENT_ALLOWED;
            if (!$application.variables.openPeriodId &&
                (open.period_state || open.PERIOD_STATE) === 'Open') {
              $application.variables.openPeriodId = open.period_id || open.PERIOD_ID;
            }
          }
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Periods unavailable',
            message: 'Could not load the period list. Cut-off dates may not be shown.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        // A missing period list is not fatal — the user can still see their
        // weeks — but it must be visible rather than silent.
        await Actions.fireNotificationEvent(context, {
          summary: 'Periods unavailable',
          message: 'Could not load the period list. Cut-off dates may not be shown.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
      }

      // ── 4. Manager switcher, managers and admins only ────────
      if (role === 'ROLE_TIME_MANAGER' || role === 'ROLE_TIME_ADMIN') {
        try {
          const mgr = await Actions.callRest(context, {
            endpoint: 'oc_time/getManagers',
            uriParams: { employeeId: $application.variables.employeeId, _t: Date.now() },
          });

          if (mgr.ok && mgr.body && mgr.body.items) {
            $page.variables.managerOptionsArray = mgr.body.items.map((m) => ({
              value: m.employee_id || m.EMPLOYEE_ID,
              label: m.employee_name || m.EMPLOYEE_NAME,
            }));
          }
        } catch (e) {
          // The switcher is a convenience; without it the manager still reviews
          // their own team, so this degrades quietly by design.
        }
      }

      // ── 5. Land on the right page for the role ───────────────
      $page.variables.navReady = true;

      const landing = (role === 'ROLE_TIME_ADMIN')   ? 'sync-status'
                    : (role === 'ROLE_TIME_MANAGER') ? 'team-approvals'
                    : (role === 'ROLE_TIME_NONE')    ? null
                    : 'my-timesheet';

      if (landing) {
        await Actions.callChain(context, {
          chain: 'navigateChain',
          params: { target: landing },
        });
      } else {
        $page.variables.signInError =
          'You are not authorized to access this application. Contact your administrator.';
      }
    }
  }

  return bootstrapChain;
});
