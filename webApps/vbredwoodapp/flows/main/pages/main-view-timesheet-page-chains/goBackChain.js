/* PAGE-004 View Timesheet — back to the landing page */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Returns to Team Approvals, keeping the period so the landing page reloads on
   * the month the manager was working in. The employee drill-down is cleared
   * because the landing page is a project chooser.
   */
  class goBackChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.selectedEmployeeId   = '';
      $application.variables.selectedEmployeeName = '';
      $application.variables.selectedWeekId       = null;

      $application.variables.activeNav = 'main-team-approvals';
      await Actions.navigateToPage(context, {
        page: 'main-team-approvals', history: 'push',
      });
    }
  }

  return goBackChain;
});
