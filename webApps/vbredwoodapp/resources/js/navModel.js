/* O2C Timesheet Module — the navigation model (RULE-022) */

define([], () => {
  'use strict';

  /**
   * Who may open what.
   *
   * This is the single definition of the module's menu, and it is used twice:
   * buildNavChain renders the sidebar from it, and navigateToPageChain checks
   * against it before routing. Two lists would eventually disagree, and the
   * disagreement would be silent — a menu item that 403s, or worse, a page
   * reachable by URL that the menu deliberately hid.
   *
   * Entitlement is expressed by omission. A role is never handed an item it may
   * not open, so there is no such thing as a disabled menu entry here.
   *
   * `page` is the page id inside the single 'main' flow, which is also what
   * $application.variables.activeNav holds.
   */

  // Group titles and item order follow doc/O2C_Timesheet_Module.html (the
  // prototype's NAV object) so the built menu and the reference read alike.

  const MY_WORK = {
    title: 'My Work',
    items: [
      { page: 'main-my-timesheet',      label: 'My Timesheet',       icon: 'oj-ux-ico-clock' },
      { page: 'main-client-timesheets', label: 'Client Timesheets',  icon: 'oj-ux-ico-attachment' },
      // PROC-007, employee side. Under My Work, not Team: main-salary-stopping
      // in the Team group is the MANAGER's list of who is held. Two pages over
      // the same data, and the difference is whose pay it is.
      { page: 'main-my-salary-hold',    label: 'Salary on Hold',     icon: 'oj-ux-ico-warning' },
    ],
  };

  const TEAM = {
    title: 'Team',
    items: [
      { page: 'main-team-approvals',      label: 'Team Approvals',      icon: 'oj-ux-ico-approval' },
      { page: 'main-leave-loss-coverage', label: 'Leave Loss Coverage', icon: 'oj-ux-ico-contact-group' },
      { page: 'main-salary-stopping',     label: 'Salary Stopping',     icon: 'oj-ux-ico-pause' },
    ],
  };

  const SETUP = {
    title: 'Setup',
    items: [
      { page: 'main-calendar-sync', label: 'Calendar (Fusion Sync)', icon: 'oj-ux-ico-calendar' },
    ],
  };

  const OPERATIONS = {
    title: 'Operations',
    items: [
      { page: 'main-sync-status',         label: 'Sync Status',         icon: 'oj-ux-ico-activity' },
      { page: 'main-accrual-integration', label: 'Accrual Integration', icon: 'oj-ux-ico-chart-bar' },
      { page: 'main-integrations',        label: 'Integrations (REST)', icon: 'oj-ux-ico-plug' },
    ],
  };

  // PER-004 is explicit that the admin menu is "Period Control Table, Calendar
  // (Fusion Sync), Sync Status, Accrual Integration, Integrations (REST)" — the
  // admin does NOT get My Timesheet or Team Approvals. The prototype's NAV
  // agrees. Finance/Admin is a back-office role here, not a super-user of the
  // employee and manager screens; an admin who also records time signs in with
  // their worker account, which carries the worker's role.
  //
  // (Period Control is PAGE-008, removed from the app on 29-Jul and now
  // reference data only, so it has no menu entry.)
  const GROUPS_BY_ROLE = {
    ROLE_TIME_ADMIN:      [SETUP, OPERATIONS],
    ROLE_TIME_MANAGER:    [MY_WORK, TEAM],
    ROLE_TIME_EMPLOYEE:   [MY_WORK],
    ROLE_TIME_CONTRACTOR: [MY_WORK],
    ROLE_TIME_NONE:       [],
  };

  /**
   * Pages that are reachable but never appear in the menu: they are opened by
   * drilling into a row, not by choosing them. They still need entitlement,
   * which is why they are listed rather than left to fall through.
   *
   * Manager only. PER-004 gives the admin access_scope 'All', but the approval
   * chain is the manager's: RULE-015 routes a manager's own time to their
   * reporting manager, and there is no equivalent story for an admin acting as
   * an approver. Admits nobody the menu would not already admit.
   */
  const DRILL_PAGES = {
    'main-approval-detail': ['ROLE_TIME_MANAGER'],
    'main-view-timesheet':  ['ROLE_TIME_MANAGER'],
  };

  /** Pages anyone may reach, signed in or not. */
  const PUBLIC_PAGES = ['main-login', 'main-set-password'];

  return {
    /** The sidebar for a role: an array of { title, items[] }. */
    groupsFor(role) {
      return GROUPS_BY_ROLE[role] || [];
    },

    /** Where a role lands after signing in. Null means nowhere is permitted. */
    landingFor(role) {
      const groups = GROUPS_BY_ROLE[role] || [];
      // An admin's first question of the day is whether the overnight
      // population job ran, and a manager's is what is waiting for approval —
      // neither is the first item in their menu.
      if (role === 'ROLE_TIME_ADMIN')   { return 'main-sync-status'; }
      if (role === 'ROLE_TIME_MANAGER') { return 'main-team-approvals'; }
      return groups.length ? groups[0].items[0].page : null;
    },

    /** RULE-022, applied to a page id — including one typed into the URL. */
    canOpen(role, page) {
      if (!page || PUBLIC_PAGES.indexOf(page) !== -1) {
        return true;
      }
      if (DRILL_PAGES[page]) {
        return DRILL_PAGES[page].indexOf(role) !== -1;
      }
      return (GROUPS_BY_ROLE[role] || []).some(
        (g) => g.items.some((i) => i.page === page));
    },
  };
});
