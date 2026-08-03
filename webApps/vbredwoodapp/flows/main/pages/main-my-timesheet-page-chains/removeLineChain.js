/* PAGE-001 My Timesheet — ACT-004 remove a grid line */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Removes one project/task line from the grid in memory.
   *
   * Replaces an inline `function(){ ... }` in on-oj-action. The button rendered
   * — the oj-bind-if around it evaluated fine — but the handler was never
   * attached, so clicking the bin did nothing at all.
   *
   * The line is only gone from the server once Save draft posts the grid; the
   * page function marks the week unsaved so leaving without saving still warns.
   *
   * @param {Object} context
   * @param {{row:Object}} params
   */
  class removeLineChain extends ActionChain {

    async run(context, { row } = {}) {
      const { $page } = context;

      if (!row) { return; }

      $page.functions.removeRow(row);
    }
  }

  return removeLineChain;
});
