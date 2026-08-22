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
     * @param {Array}  params.picked the checkboxset value: ['on'] or []
     *
     * `picked`, NOT `value`. The listener was cloned from the row picker,
     * which sends `picked` plus a $current.row id -- so this destructured a
     * name nothing sent and read undefined every time. The header tick went
     * on, and nothing happened: it is not the checkbox that failed, it is the
     * wiring behind it, which looks identical in the markup.
     */
    async run(context, { picked } = {}) {
      const { $page } = context;
      const ticked = Array.isArray(picked) && picked.indexOf('on') >= 0;
      $page.functions.toggleAllDatePick($page.variables, ticked);
    }
  }

  return toggleAllDatePickChain;
});
