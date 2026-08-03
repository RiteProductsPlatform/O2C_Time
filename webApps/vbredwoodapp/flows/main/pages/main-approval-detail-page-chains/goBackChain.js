/* PAGE-005 Approval Detail — back to the monthly summary */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class goBackChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.selectedWeekId = null;

      $application.variables.activeNav = 'main-view-timesheet';
      await Actions.navigateToPage(context, {
        page: 'main-view-timesheet', history: 'push',
      });
    }
  }

  return goBackChain;
});
