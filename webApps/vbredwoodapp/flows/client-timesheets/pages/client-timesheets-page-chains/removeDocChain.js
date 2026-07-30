/* PAGE-002 Client Timesheets — remove an attached document (confirmed) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Deletes the document the confirmation dialog was opened for.
   *
   * The confirmation itself lives in askRemoveDocChain + the oj-dialog; this
   * chain runs only once the user has said yes, so it does no prompting of its
   * own. window.confirm is not an option — JET's SES lockdown blocks browser
   * globals inside chains (knowledge/14 §7).
   */
  class removeDocChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const docId = $page.variables.confirmDocId;
      if (!docId) { return; }

      const doc  = ($page.variables.docs || []).find((d) => d.docId === docId);
      const name = doc ? doc.docName : 'the document';

      $page.variables.busy = true;

      try {
        await Actions.callComponentMethod(context, {
          selector: '#removeDocDlg',
          method: 'close',
        });

        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/deleteClientDoc',
          uriParams: { id: docId },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Document removed',
            message: name + ' removed.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadDocsChain' });
          return;
        }

        if (resp.status === 404) {
          // Someone else already removed it; refresh so the table agrees.
          await Actions.fireNotificationEvent(context, {
            summary: 'Already gone',
            message: 'That document no longer exists.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadDocsChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not remove',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not remove',
          message: 'The service is unreachable. Please retry.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
        $page.variables.confirmDocId = null;
      }
    }
  }

  return removeDocChain;
});
