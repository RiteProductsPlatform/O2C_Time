/* PAGE-004 Monthly Summary -- toggleAllPick */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * The tick in the checkbox column header. Selects every employee that is not
   * already Approved, or clears the selection if they all already are.
   *
   * Replaces the "Select all pending" and "Clear" buttons that sat in the page
   * header. Same rule -- Approved rows are skipped so an approve-all never
   * re-sends settled work -- reached from where the rows are.
   *
   * A declared listener, not an inline function in the markup: an inline
   * function literal in a binding is never wired up (S1).
   */
  class toggleAllPickChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {Object} params
     * @param {Array}  params.value the checkboxset value: ['on'] or []
     */
    async run(context, { value }) {
      const { $page } = context;
      const ticked = Array.isArray(value) && value.indexOf('on') >= 0;
      $page.functions.toggleAllPick($page.variables, ticked);
    }
  }

  return toggleAllPickChain;
});
