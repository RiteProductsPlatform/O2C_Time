/* PAGE-007 Salary Stopping — open the release dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Opens the dialog and pre-computes whether release is even possible.
   *
   * ACT-026 requires the defaulted timesheet to be corrected first. Rather than
   * let the manager type remarks and then be refused by the server, the dialog
   * says up front that the week still needs fixing and keeps the button disabled.
   */
  class openReleaseChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{holdId:number, label:string, weeksDefaulted:number}} params
     */
    async run(context, { holdId, label, weeksDefaulted }) {
      const { $page } = context;

      $page.variables.releaseHoldId  = holdId;
      $page.variables.releaseLabel   = label || '';
      $page.variables.releaseRemarks = '';
      // Still-defaulted weeks block the release (ACT-026 precondition).
      $page.variables.releaseBlocked = (Number(weeksDefaulted) || 0) > 0;
      $page.variables.showRelease    = true;
    }
  }

  return openReleaseChain;
});
