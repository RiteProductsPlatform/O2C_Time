/* PAGE-005 Approval Detail — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Needs a project AND an employee. Missing either means the page was reached
   * directly, so hand the user back to the level that can make the choice.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.activeNav = 'main-approval-detail';

      if (!$application.variables.selectedProjectId) {
        $application.variables.activeNav = 'main-team-approvals';
        await Actions.navigateToPage(context, {
          page: 'main-team-approvals', history: 'push',
        });
        return;
      }

      if (!$application.variables.selectedEmployeeId) {
        $application.variables.activeNav = 'main-view-timesheet';
        await Actions.navigateToPage(context, {
          page: 'main-view-timesheet', history: 'push',
        });
        return;
      }

      await Actions.callChain(context, { chain: 'loadWeeksChain' });
    }
  }

  return enterChain;
});
