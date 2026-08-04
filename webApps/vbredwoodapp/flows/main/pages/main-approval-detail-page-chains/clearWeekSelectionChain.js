/* PAGE-005 Approval detail — clear the week selection */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Clears the bulk week selection.
   *
   * A declared listener: an inline function literal in a binding is never
   * wired up (S1), and the page module cannot reach $page on its own.
   */
  class clearWeekSelectionChain extends ActionChain {
    async run(context) {
      const { $page } = context;
      $page.functions.clearWeekSelection($page.variables);
    }
  }

  return clearWeekSelectionChain;
});
