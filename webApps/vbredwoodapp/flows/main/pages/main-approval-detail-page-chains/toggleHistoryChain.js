/* PAGE-005 Approval detail — show or hide the change history */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Flips the change-history panel open and shut.
   *
   * A declared listener rather than an expression in the binding: an inline
   * function literal is never wired up (S1), and the page module cannot reach
   * $page on its own.
   *
   * The panel is collapsed on entry and this is the only thing that opens it.
   * It is not reset when the week changes — a manager who opened the history
   * once is working through weeks comparing them, and shutting it on every
   * navigation would fight them.
   */
  class toggleHistoryChain extends ActionChain {
    async run(context) {
      const { $page } = context;
      $page.variables.showHistory = !$page.variables.showHistory;
    }
  }

  return toggleHistoryChain;
});
