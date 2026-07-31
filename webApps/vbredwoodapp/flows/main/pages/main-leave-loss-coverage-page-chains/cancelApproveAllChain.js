/* Approve all assigned coverage — dismiss the confirmation dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelApproveAllChain extends ActionChain {

    async run(context) {
      await Actions.callComponentMethod(context, {
        selector: '#approveAllDlg',
        method: 'close',
      });
    }
  }

  return cancelApproveAllChain;
});
