/* PAGE-004 Monthly Summary — clearSelection */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Clear the bulk selection.
   *
   * A declared listener, not an inline function in the markup: an inline
   * function literal in a binding is never wired up (S1).
   */
  class clearSelectionChain extends ActionChain {

    async run(context) {
      const { $page } = context;
      $page.functions.clearSelection($page.variables);
    }
  }

  return clearSelectionChain;
});
