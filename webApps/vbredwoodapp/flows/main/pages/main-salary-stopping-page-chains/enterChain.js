/* PAGE-007 Salary Stopping — page entry */

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

      $application.variables.activeNav = 'main-salary-stopping';

      const seed = $application.variables.selectedPeriodId
                || $application.variables.openPeriodId;

      if ($page.variables.periodId === seed) {
        await Actions.callChain(context, { chain: 'loadHoldsChain' });
      } else {
        $page.variables.periodId = seed;
      }
    }
  }

  return enterChain;
});
