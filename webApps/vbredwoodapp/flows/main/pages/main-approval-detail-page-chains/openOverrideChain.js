/* PAGE-005 Approval Detail — open the override dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Pre-fills the current hours so the manager edits from the employee's value
   * rather than an empty field — the change is a correction, not a re-entry.
   */
  class openOverrideChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{tsEntryId:number, label:string, hours:number}} params
     */
    async run(context, { row } = {}) {
      const { $page } = context;

      // See openWeekChain: the row arrives whole and the label is derived here,
      // because a listener parameter cannot invoke a page function.
      if (!row) { return; }

      const tsEntryId = row.tsEntryId;
      const hours     = row.hours;
      const label     = $page.functions.overrideLabelFor(row);

      $page.variables.overrideEntryId = tsEntryId;
      $page.variables.overrideLabel   = label || '';
      $page.variables.overrideHours   = Number(hours) || 0;
      $page.variables.overrideReason  = '';
      $page.variables.showOverride    = true;
      $page.functions.setDialog('overrideDlg', true);
    }
  }

  return openOverrideChain;
});
