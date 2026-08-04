/* PAGE-001 My Timesheet — Up/Down in an hours box */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Steps the cell by a quarter hour on Up/Down arrow.
   *
   * The visible ▲▼ buttons are out of the tab order so Tab walks box to box
   * across the week — seven presses, not twenty-one. This keeps their function
   * on the keyboard, where Up/Down in a numeric field is what people already
   * expect, and reuses the same applyCellEdit so the clamping, the 15-minute
   * snap (RULE-005) and the dirty-cell bookkeeping cannot drift apart.
   */
  class cellKeyChain extends ActionChain {

    async run(context, { cell, key } = {}) {
      const { $page } = context;

      if (!cell) { return; }
      if (key !== 'ArrowUp' && key !== 'ArrowDown') { return; }

      const row = ($page.variables.gridRows || [])
        .find((r) => r.rowKey === cell.rowKey);
      if (!row) { return; }

      const current = Number(row['d' + cell.dayIndex]) || 0;
      const delta   = (key === 'ArrowUp') ? 0.25 : -0.25;

      $page.functions.applyCellEdit($page.variables, row, cell.dayIndex,
                                    current + delta);
    }
  }

  return cellKeyChain;
});
