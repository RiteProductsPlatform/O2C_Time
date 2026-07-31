/* PAGE-005 Approval Detail — dismiss the ACT-019 confirmation */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelApproveAllWeeksChain extends ActionChain {

    async run(context) {
      await Actions.callComponentMethod(context, {
        selector: '#approveAllDlg',
        method: 'close',
      });
    }
  }

  return cancelApproveAllWeeksChain;
});
