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
   * The parameter is the CELL, not the row. An eventListener cannot see a
 * data-oj-as alias — those are local to the template — so `{{ line.data }}`
 * arrived undefined. $current is bound to the innermost for-each item, so
 * each cell carries its own rowKey and dayIndex and the row is looked up
 * here.
   *
   * @param {Object} context
   * @param {{row:Object, dayIndex:number, value:*, updatedFrom:string}} params
   */
  class cellChangedChain extends ActionChain {

    async run(context, { cell, value, updatedFrom } = {}) {
      const { $page } = context;

      // The re-render that follows an edit fires value-changed straight back;
      // only a real user edit is 'internal'.
      if (updatedFrom !== 'internal' || !cell) { return; }

      const row = ($page.variables.gridRows || [])
        .find((r) => r.rowKey === cell.rowKey);
      if (!row) { return; }

      $page.functions.applyCellEdit($page.variables, row, cell.dayIndex, value);
    }
  }

  return cellChangedChain;
});
