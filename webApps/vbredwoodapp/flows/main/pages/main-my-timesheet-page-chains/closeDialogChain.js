/* PAGE-001 My Timesheet — close a dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Closes one of the page's three dialogs.
   *
   * A named chain rather than an inline `function(){ ... }` in the markup: the
   * coding standards keep listener wiring in the page JSON so every handler is
   * greppable and reviewable, and inline mutation in HTML is the one thing that
   * cannot be found later.
   */
  class closeDialogChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{which:string}} params 'allocation' | 'addLine' | 'adjustment'
     */
    async run(context, { which }) {
      const { $page } = context;

      if (which === 'allocation')      { $page.variables.showAllocation = false; }
      else if (which === 'addLine')    { $page.variables.showAddLine    = false; }
      else if (which === 'adjustment') { $page.variables.showAdjustment = false; }
    }
  }

  return closeDialogChain;
});
