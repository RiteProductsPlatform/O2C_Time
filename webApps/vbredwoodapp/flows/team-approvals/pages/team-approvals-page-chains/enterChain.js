/* PAGE-003 Team Approvals — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Seeds the month from the shared session and lets loadProjectsChain do the
   * rest. Setting periodId fires it via onValueChanged.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $application.variables.activeNav = 'team-approvals';

      const seed = $application.variables.selectedPeriodId
                || $application.variables.openPeriodId;

      // Re-selecting the same period does not fire onValueChanged, so load
      // explicitly when the value is unchanged (e.g. returning from PAGE-004).
      if ($page.variables.periodId === seed) {
        await Actions.callChain(context, { chain: 'loadProjectsChain' });
      } else {
        $page.variables.periodId = seed;
      }
    }
  }

  return enterChain;
});
