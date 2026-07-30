/* Advance-approve month — dismiss the confirmation dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelAdvanceApproveChain extends ActionChain {

    async run(context) {
      await Actions.callComponentMethod(context, {
        selector: '#advanceApproveDlg',
        method: 'close',
      });
    }
  }

  return cancelAdvanceApproveChain;
});
