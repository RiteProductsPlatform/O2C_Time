/* PAGE-005 Approval detail — tick one date */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * A date has several task lines; the tick toggles the whole date (BRD approves at date level).
   *
   * A declared listener: an inline function literal in a binding is never
   * wired up (S1), and the page module cannot reach $page on its own.
   */
  class toggleDatePickChain extends ActionChain {
    async run(context, { entryDate, picked } = {}) {
      const { $page } = context;
      if (!entryDate) { return; }
      $page.functions.toggleDatePick($page.variables, entryDate, picked);
    }
  }

  return toggleDatePickChain;
});
