/* PAGE-006 Leave Loss Coverage — ask HR again, even if we already did */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * The "Refresh absences from HR" button.
   *
   * refreshHrAbsenceChain pulls once per project-month and then short-circuits,
   * because it now runs on page load and on every project or month change --
   * without that guard, opening the page would read the whole team out of
   * Fusion twice, since enterChain settles the two variables separately.
   *
   * A manager pressing the button is saying "ask again", which is a different
   * statement from "make sure you have asked". Clearing the marker first is the
   * whole of this chain, and it exists as a chain rather than a parameter
   * because the guard has to live where the pull is, not at each call site.
   */
  class forceHrRefreshChain extends ActionChain {

    async run(context) {
      const { $page } = context;
      $page.variables.lastPull = '';
      await Actions.callChain(context, { chain: 'refreshHrAbsenceChain' });
    }
  }

  return forceHrRefreshChain;
});
