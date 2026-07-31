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

  const MY_TIME = {
    title: 'My Time',
    items: [
      { page: 'main-my-timesheet',      label: 'My Timesheet',       icon: 'oj-ux-ico-calendar' },
      { page: 'main-client-timesheets', label: 'Client Timesheets',  icon: 'oj-ux-ico-file-text' },
    ],
  };

  const TEAM = {
    title: 'My Team',
    items: [
      { page: 'main-team-approvals',      label: 'Team Approvals',      icon: 'oj-ux-ico-approval' },
      { page: 'main-leave-loss-coverage', label: 'Leave Loss Coverage', icon: 'oj-ux-ico-user-group' },
      { page: 'main-salary-stopping',     label: 'Salary Stopping',     icon: 'oj-ux-ico-currency-dollar' },
    ],
  };

  const ADMIN = {
    title: 'Administration',
    items: [
      { page: 'main-calendar-sync',        label: 'Calendar (Fusion Sync)', icon: 'oj-ux-ico-calendar-clock' },
      { page: 'main-sync-status',          label: 'Sync Status',            icon: 'oj-ux-ico-activity' },
      { page: 'main-accrual-integration',  label: 'Accrual Integration',    icon: 'oj-ux-ico-data-flow' },
      { page: 'main-integrations',         label: 'Integrations',           icon: 'oj-ux-ico-plug' },
    ],
  };

  const GROUPS_BY_ROLE = {
    ROLE_TIME_ADMIN:      [MY_TIME, TEAM, ADMIN],
    ROLE_TIME_MANAGER:    [MY_TIME, TEAM],
    ROLE_TIME_EMPLOYEE:   [MY_TIME],
    ROLE_TIME_CONTRACTOR: [MY_TIME],
    ROLE_TIME_NONE:       [],
  };

  /**
   * Pages that are reachable but never appear in the menu: they are opened by
   * drilling into a row, not by choosing them. They still need entitlement,
   * which is why they are listed rather than left to fall through.
   */
  const DRILL_PAGES = {
    'main-approval-detail': ['ROLE_TIME_MANAGER', 'ROLE_TIME_ADMIN'],
    'main-view-timesheet':  ['ROLE_TIME_MANAGER', 'ROLE_TIME_ADMIN'],
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
      // Admins care about the overnight sync before their own timesheet, and a
      // manager's first job of the day is the approval queue.
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
