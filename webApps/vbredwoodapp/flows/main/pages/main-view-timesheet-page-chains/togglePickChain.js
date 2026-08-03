/* PAGE-004 Monthly Summary — the row tick */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Mirrors one row's checkbox back into the selected-id array.
   *
   * oj-checkboxset carries an ARRAY value, so ticked is ['on'] and unticked is
   * []. The employee id comes from $current.row rather than a data-oj-as alias,
   * which an eventListener cannot see.
   */
  class togglePickChain extends ActionChain {

    async run(context, { employeeId, picked } = {}) {
      const { $page } = context;

      if (!employeeId) { return; }

      $page.functions.togglePick($page.variables, employeeId, picked);
    }
  }

  return togglePickChain;
});
