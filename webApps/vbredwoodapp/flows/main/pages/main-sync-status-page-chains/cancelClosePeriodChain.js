/* Close a period — dismiss the confirmation dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelClosePeriodChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      await Actions.callComponentMethod(context, {
        selector: '#closePeriodDlg',
        method: 'close',
      });

      $page.variables.closePeriodId = null;
    }
  }

  return cancelClosePeriodChain;
});
