/* O2C Timesheet Module — single navigation entry point */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Every nav selection and every in-page "go to" routes through here, so the
   * route, the drawer state and the activeNav highlight are set in one place and
   * cannot drift apart.
   *
   * RULE-022 is enforced a second time here, not only by the menu contents: a
   * hand-typed URL must not reach a page the role is not entitled to. The menu
   * omits the item; this chain refuses the navigation.
   *
   * Each destination is its own flow with a single page of the same name,
   * addressed relative to the shell — see the note on the navigate call below
   * for why this is navigateToPage and not navigateToFlow.
   */
  class navigateChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{target:string}} params
     */
    async run(context, { target }) {
      const { $page, $application } = context;
      const role = $application.variables.currentRole;

      if (!target) {
        return;
      }

      const EMPLOYEE = ['my-timesheet', 'client-timesheets'];
      const MANAGER  = EMPLOYEE.concat([
        'team-approvals', 'view-timesheet', 'approval-detail',
        'leave-loss-coverage', 'salary-stopping',
      ]);
      const ADMIN    = MANAGER.concat([
        'calendar-sync', 'sync-status', 'accrual-integration', 'integrations',
      ]);

      const allowed = role === 'ROLE_TIME_ADMIN'   ? ADMIN
                    : role === 'ROLE_TIME_MANAGER' ? MANAGER
                    : (role === 'ROLE_TIME_EMPLOYEE' || role === 'ROLE_TIME_CONTRACTOR')
                        ? EMPLOYEE
                        : [];

      if (allowed.indexOf(target) === -1) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Not authorized',
          message: 'You are not authorized to access this page.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
        return;
      }

      // Recorded before the navigate so onNavSelectionChain can tell a real user
      // selection from the selection write this chain is about to cause.
      $page.variables.currentRoute = target;
      $application.variables.activeNav = target;
      $page.variables.isDrawerOpen = false;

      // 'shell/<flow>/<page>', not navigateToFlow.
      //
      // These flows are hosted by the SHELL PAGE's router outlet (the
      // oj-vb-content in shell-page.html), so they are children of the shell
      // page, not application-level flows. navigateToFlow drives the
      // application router, which is not what renders here — it resolves to
      // nothing and the content area simply stays blank, with no error.
      //
      // Each flow has a single page of the same name, hence the repeat.
      await Actions.navigateToPage(context, {
        page: 'shell/' + target + '/' + target,
        history: 'push',
      });
    }
  }

  return navigateChain;
});
