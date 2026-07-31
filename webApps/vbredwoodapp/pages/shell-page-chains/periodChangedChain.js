/* O2C Timesheet Module — the selected month changed */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Keeps the derived period facts beside the id.
   *
   * Pages ask "may I edit this month?" (RULE-004 / RULE-007) and "may I raise a
   * retro adjustment?" (RULE-019) constantly. Resolving that here, once per
   * change, means no page has to re-read the period list to answer, and no two
   * pages can answer differently.
   */
  class periodChangedChain extends ActionChain {

    async run(context, { periodId } = {}) {
      const { $application } = context;

      const rows = $application.variables.periodOptionsArray || [];
      const row  = rows.find((r) => r.value === periodId);

      if (!row) {
        // Cleared, or a period that is no longer in the list. Fall back to the
        // safe answer: nothing is editable until a real period is chosen.
        $application.variables.selectedPeriodName = '';
        $application.variables.periodEditable     = 'N';
        $application.variables.adjustmentAllowed  = 'N';
        return;
      }

      $application.variables.selectedPeriodName = row.label;
      $application.variables.periodEditable     = row.editableFlag || 'N';
      $application.variables.adjustmentAllowed  = row.adjustmentAllowed || 'N';
    }
  }

  return periodChangedChain;
});
