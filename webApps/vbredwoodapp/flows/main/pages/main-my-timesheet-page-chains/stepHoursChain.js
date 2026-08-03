/* PAGE-001 My Timesheet — the up/down arrows on a day cell (ACT-005) */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Nudges one cell by a quarter of an hour.
   *
   * The arrows are explicit buttons rather than an oj-input-number spinner, as
   * in doc/O2C_Timesheet_Module.html: the spinner does not fit a day column and
   * pushed the value out of view entirely. Stepping therefore has to be wired
   * up by hand, which is this.
   *
   * RULE-005 (15-minute blocks) is why delta is +/- 0.25; applyCellEdit still
   * clamps to 0..24 and re-snaps, and the server validates again on save, so
   * this is convenience rather than the control.
   *
   * @param {Object} context
   * @param {{row:Object, dayIndex:number, delta:number}} params
   */
  class stepHoursChain extends ActionChain {

    async run(context, { row, dayIndex, delta } = {}) {
      const { $page } = context;

      if (!row || dayIndex === undefined || dayIndex === null) { return; }

      const current = Number(row['d' + dayIndex]) || 0;

      $page.functions.applyCellEdit($page.variables, row, dayIndex,
                                    current + (Number(delta) || 0));
    }
  }

  return stepHoursChain;
});
