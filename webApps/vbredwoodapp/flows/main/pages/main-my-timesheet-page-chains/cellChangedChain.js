/* PAGE-001 My Timesheet — a day cell was edited (ACT-005) */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Records one edited cell.
   *
   * This exists because the binding used to be an inline function literal:
   *
   *   on-value-changed="[[ function(e){ ...inline handler... } ]]"
   *
   * which S1 forbids and which was not being wired up at all — the input took
   * no value and no keystroke reached the page, and the Remove button rendered
   * but did nothing for the same reason. A declared listener per day passes the
   * day index as a literal rather than deriving it from $current.columnIndex,
   * The day index now arrives as day.index from the nested oj-bind-for-each
 * over dayHeaders, so a week clipped to the month end simply has fewer
 * columns and no cell can be off by one.
   *
   * @param {Object} context
   * @param {{row:Object, dayIndex:number, value:*, updatedFrom:string}} params
   */
  class cellChangedChain extends ActionChain {

    async run(context, { row, dayIndex, value, updatedFrom } = {}) {
      const { $page } = context;

      // The re-render that follows an edit fires value-changed straight back;
      // only a real user edit is 'internal'.
      if (updatedFrom !== 'internal' || !row) { return; }

      $page.functions.applyCellEdit($page.variables, row, dayIndex, value);
    }
  }

  return cellChangedChain;
});
