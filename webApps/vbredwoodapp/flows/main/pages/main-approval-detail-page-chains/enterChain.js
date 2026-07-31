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
        await Actions.callChain(context, {
          chain: 'shell/navigateToPageChain', params: { page: 'main-team-approvals' },
        });
        return;
      }

      if (!$application.variables.selectedEmployeeId) {
        await Actions.callChain(context, {
          chain: 'shell/navigateToPageChain', params: { page: 'main-view-timesheet' },
        });
        return;
      }

      await Actions.callChain(context, { chain: 'loadWeeksChain' });
    }
  }

  return enterChain;
});
