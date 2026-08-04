/* PAGE-005 Approval detail — tick one week */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * oj-checkboxset carries an ARRAY value, so ticked is ['on'] and unticked is [].
   *
   * A declared listener: an inline function literal in a binding is never
   * wired up (S1), and the page module cannot reach $page on its own.
   */
  class toggleWeekPickChain extends ActionChain {
    async run(context, { tsWeekId, picked } = {}) {
      const { $page } = context;
      if (tsWeekId === undefined || tsWeekId === null) { return; }
      $page.functions.toggleWeekPick($page.variables, tsWeekId, picked);
    }
  }

  return toggleWeekPickChain;
});
