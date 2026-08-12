/* H8 — dismiss the change-task dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelChangeTaskChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      await Actions.callComponentMethod(context, {
        selector: '#changeTaskDlg',
        method: 'close',
      });

      $page.variables.chgNewTaskId = null;
    }
  }

  return cancelChangeTaskChain;
});
