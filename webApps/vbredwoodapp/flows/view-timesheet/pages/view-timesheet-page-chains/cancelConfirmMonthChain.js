/* Confirm month to accrual — dismiss the confirmation dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelConfirmMonthChain extends ActionChain {

    async run(context) {
      await Actions.callComponentMethod(context, {
        selector: '#confirmMonthDlg',
        method: 'close',
      });
    }
  }

  return cancelConfirmMonthChain;
});
