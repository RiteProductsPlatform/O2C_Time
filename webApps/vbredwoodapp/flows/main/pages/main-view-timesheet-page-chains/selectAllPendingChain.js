/* PAGE-004 Monthly Summary — selectAllEmployees */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Select every employee that is not already Approved (BRD: approve all or some). Approved rows are skipped so an approve-all never re-sends settled work.
   *
   * A declared listener, not an inline function in the markup: an inline
   * function literal in a binding is never wired up (S1).
   */
  class selectAllPendingChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      // The acting manager, not the signed-in user: ACT-011 lets a manager act
      // for another, and it is the ACTOR whose own row RULE-015 will refuse.
      $page.functions.selectAllEmployees(
        $page.variables, $application.variables.actingManagerId);
    }
  }

  return selectAllPendingChain;
});
