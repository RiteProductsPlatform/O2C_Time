/* PAGE-004 View Timesheet — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Requires a project selection. Arriving without one means the user deep-linked
   * or the session was cleared, so send them back to the landing page rather than
   * showing an empty summary they cannot explain.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.activeNav = 'main-view-timesheet';

      if (!$application.variables.selectedProjectId) {
        $application.variables.activeNav = 'main-team-approvals';
        await Actions.navigateToPage(context, {
          page: 'main-team-approvals', history: 'push',
        });
        return;
      }

      await Actions.callChain(context, { chain: 'loadSummaryChain' });
    }
  }

  return enterChain;
});
