/* PAGE-002 Client Timesheets — dismiss the remove confirmation */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelRemoveDocChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.confirmDocId = null;

      await Actions.callComponentMethod(context, {
        selector: '#removeDocDlg',
        method: 'close',
      });
    }
  }

  return cancelRemoveDocChain;
});
