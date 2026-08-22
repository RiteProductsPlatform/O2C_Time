/* PAGE-005 Approval Detail -- toggleAllDatePick */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * The tick in the day table's first column header. Selects every date in the
   * grid, or clears the selection if they are all already selected.
   *
   * Replaces the "Select all dates" and "Clear" buttons that sat in the
   * toolbar. Same behaviour, reached from where the rows are.
   *
   * A declared listener, not an inline function in the markup: an inline
   * function literal in a binding is never wired up (S1).
   */
  class toggleAllDatePickChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {Object} params
     * @param {Array}  params.value the checkboxset value: ['on'] or []
     */
    async run(context, { value }) {
      const { $page } = context;
      const ticked = Array.isArray(value) && value.indexOf('on') >= 0;
      $page.functions.toggleAllDatePick($page.variables, ticked);
    }
  }

  return toggleAllDatePickChain;
});
