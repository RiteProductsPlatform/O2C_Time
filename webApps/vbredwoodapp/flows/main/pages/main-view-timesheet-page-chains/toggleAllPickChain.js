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
      $page.functions.toggleAllPick($page.variables, ticked);
    }
  }

  return toggleAllPickChain;
});
