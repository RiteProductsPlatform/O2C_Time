/* PAGE-005 Approval detail — select every date in the daily grid */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Approval is at DATE level, not line level, so this collects distinct dates.
   *
   * A declared listener: an inline function literal in a binding is never
   * wired up (S1), and the page module cannot reach $page on its own.
   */
  class selectAllDatesChain extends ActionChain {
    async run(context) {
      const { $page } = context;
      $page.functions.selectAllDates($page.variables);
    }
  }

  return selectAllDatesChain;
});
