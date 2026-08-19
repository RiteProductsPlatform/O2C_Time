/* PAGE-001 My Timesheet — show or hide the approval workflow trail */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Flips the approval-workflow panel open and shut.
   *
   * A declared listener rather than an expression in the binding: an inline
   * function literal is never wired up (S1), and the page module cannot reach
   * $page on its own.
   *
   * Deliberately not reset by loadGridChain when the week changes. Somebody who
   * opened the trail is usually comparing one week against the next, and having
   * it shut itself on every week change would be the wrong default for exactly
   * the person who asked for it.
   */
  class toggleActivityChain extends ActionChain {
    async run(context) {
      const { $page } = context;
      $page.variables.showActivity = !$page.variables.showActivity;
    }
  }

  return toggleActivityChain;
});
