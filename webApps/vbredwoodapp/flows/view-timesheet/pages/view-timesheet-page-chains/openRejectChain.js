/* PAGE-004 View Timesheet — open the reject dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Clears the previous reason and remarks before opening.
   *
   * Carrying the last rejection's text forward would be actively harmful here:
   * the remarks are shown verbatim to the employee, so a stale message would
   * tell them to fix something unrelated.
   */
  class openRejectChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      if (!($page.variables.selectedKeys || []).length) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing selected',
          message: 'Select at least one employee.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.rejectReason  = '';
      $page.variables.rejectRemarks = '';
      $page.variables.showReject    = true;
    }
  }

  return openRejectChain;
});
