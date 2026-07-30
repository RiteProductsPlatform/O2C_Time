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
    async run(context, { tsEntryId, label, hours }) {
      const { $page } = context;

      $page.variables.overrideEntryId = tsEntryId;
      $page.variables.overrideLabel   = label || '';
      $page.variables.overrideHours   = Number(hours) || 0;
      $page.variables.overrideReason  = '';
      $page.variables.showOverride    = true;
    }
  }

  return openOverrideChain;
});
