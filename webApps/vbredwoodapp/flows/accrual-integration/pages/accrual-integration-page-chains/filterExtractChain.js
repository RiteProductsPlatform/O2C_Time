/* PAGE-011 Accrual Integration — extract view filter + totals */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Splits the extract into the two things it actually contains and totals them.
   *
   * An interface batch mixes the month's actual/default rows with the day-wise
   * Reversal(-)/Adjustment(+) pairs from retro corrections. Summing them together
   * answers neither question well: "what did this month cost?" wants the actuals,
   * "what moved after the fact?" wants the pairs.
   *
   * Reversal rows carry NEGATIVE hours by design, so the adjustment total is a
   * plain sum — the sign handling is already in the data, which is what lets the
   * accrual consumer SUM the columns with no special casing.
   */
  class filterExtractChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      const all  = $page.variables.extractRaw || [];
      const view = $page.variables.extractView || 'all';

      const isAdjustment = (r) =>
        r.entryType === 'Reversal' || r.entryType === 'Adjustment';

      $page.variables.extract =
        view === 'actual'     ? all.filter((r) => !isAdjustment(r))
      : view === 'adjustment' ? all.filter(isAdjustment)
      :                         all.slice();

      const round = (n) => Math.round(n * 100) / 100;
      const sum   = (rows, f) => round(rows.reduce((s, r) => s + (Number(r[f]) || 0), 0));

      // Totals always describe the whole batch, not the current view — the point
      // of the strip is the month's position, and it should not move when the
      // user flips between views.
      const actual = all.filter((r) => !isAdjustment(r));
      const adj    = all.filter(isAdjustment);

      $page.variables.sumBilled   = sum(actual, 'billed');
      $page.variables.sumUnbilled = sum(actual, 'unbilled');
      $page.variables.sumLeave    = sum(actual, 'leaveHours');

      $page.variables.sumAdjustment = round(
        sum(adj, 'billed') + sum(adj, 'unbilled') + sum(adj, 'leaveHours'));
    }
  }

  return filterExtractChain;
});
