/* PAGE-007 Salary Stopping — close a dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  class closeDialogChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{which:string}} params 'weeks' | 'release'
     */
    async run(context, { which }) {
      const { $page } = context;

      if (which === 'weeks') {
        $page.variables.showWeeks = false;
        $page.functions.setDialog('weeksDlg', false);
      } else if (which === 'release') {
        $page.variables.showRelease    = false;
        $page.functions.setDialog('releaseDlg', false);
        $page.variables.releaseRemarks = '';
      }
    }
  }

  return closeDialogChain;
});
