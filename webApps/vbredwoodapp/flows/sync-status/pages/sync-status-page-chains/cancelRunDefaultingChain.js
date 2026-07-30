/* Run the defaulting job — dismiss the confirmation dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class cancelRunDefaultingChain extends ActionChain {

    async run(context) {
      await Actions.callComponentMethod(context, {
        selector: '#runDefaultingDlg',
        method: 'close',
      });
    }
  }

  return cancelRunDefaultingChain;
});
