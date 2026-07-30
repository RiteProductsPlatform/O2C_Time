/* PAGE-002 Client Timesheets — ask before removing a document */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Stages the document and opens the confirmation dialog.
   *
   * Deliberately two steps: these are signed billing evidence under a 7-year
   * retention policy, so removal should not be a single click next to the
   * download link.
   */
  class askRemoveDocChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{docId:number}} params
     */
    async run(context, { docId }) {
      const { $page } = context;

      if (!docId) { return; }

      const doc = ($page.variables.docs || []).find((d) => d.docId === docId);

      $page.variables.confirmDocId   = docId;
      $page.variables.confirmMessage =
        'Remove ' + (doc ? doc.docName : 'this document') + '?';

      await Actions.callComponentMethod(context, {
        selector: '#removeDocDlg',
        method: 'open',
      });
    }
  }

  return askRemoveDocChain;
});
