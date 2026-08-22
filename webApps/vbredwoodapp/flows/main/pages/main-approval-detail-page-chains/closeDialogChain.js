/* PAGE-005 Approval Detail — close a dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Cancels either dialog and drops what was typed.
   *
   * Both texts are consequential — the rejection remarks are shown verbatim to
   * the employee and the override reason lands in the audit trail — so
   * re-offering abandoned text on the next open would be worse than clearing it.
   */
  class closeDialogChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{which:string}} params 'reject' | 'override'
     */
    async run(context, { which }) {
      const { $page } = context;

      if (which === 'reject') {
        $page.variables.showReject    = false;
        $page.functions.setDialog('rejectDlg', false);
        $page.variables.rejectReason  = '';
        $page.variables.rejectRemarks = '';
      } else if (which === 'override') {
        $page.variables.showOverride   = false;
        $page.functions.setDialog('overrideDlg', false);
        $page.variables.overrideReason = '';
        $page.variables.overrideReasonRaw = '';
      }
    }
  }

  return closeDialogChain;
});
