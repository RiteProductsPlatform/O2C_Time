/* PAGE-004 View Timesheet — close the reject dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Cancels the rejection. The typed reason and remarks are dropped deliberately
   * — reopening the dialog should not silently re-offer text the manager chose
   * to abandon, because it is shown verbatim to the employee.
   */
  class closeRejectChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.showReject    = false;
      $page.functions.setDialog('rejectDlg', false);
      $page.variables.rejectReason  = '';
      $page.variables.rejectRemarks = '';
    }
  }

  return closeRejectChain;
});
