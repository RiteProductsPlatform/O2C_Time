/* PAGE-005 Approval detail — select every week still awaiting a decision */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Settled weeks are skipped: re-approving them adds noise to the approval log for no change of state.
   *
   * A declared listener: an inline function literal in a binding is never
   * wired up (S1), and the page module cannot reach $page on its own.
   */
  class selectPendingWeeksChain extends ActionChain {
    async run(context) {
      const { $page } = context;
      $page.functions.selectPendingWeeks($page.variables);
    }
  }

  return selectPendingWeeksChain;
});
