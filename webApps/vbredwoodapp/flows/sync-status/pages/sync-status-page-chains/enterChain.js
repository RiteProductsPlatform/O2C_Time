/* PAGE-010 Sync Status — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class enterChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $application.variables.activeNav = 'sync-status';

      // Default the job period to the open one — the period an admin repairing
      // something is almost always working in.
      if (!$page.variables.runJobPeriodId) {
        $page.variables.runJobPeriodId = $application.variables.openPeriodId
                                      || $application.variables.selectedPeriodId;
      }

      await Actions.callChain(context, { chain: 'loadStatusChain' });
    }
  }

  return enterChain;
});
