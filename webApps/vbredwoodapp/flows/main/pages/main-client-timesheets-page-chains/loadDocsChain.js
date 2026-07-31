/* PAGE-002 Client Timesheets — load the document list */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Lists the documents for the chosen project + billing period.
   *
   * Metadata only: the endpoint deliberately does not return the BLOB, so the
   * table stays cheap to render however many 20MB PDFs are attached. Content is
   * streamed on demand by the download link instead.
   */
  class loadDocsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $page.variables.projectId;
      const periodId  = $page.variables.periodId;

      if (!projectId || !periodId) {
        $page.variables.docs = [];
        return;
      }

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getClientDocs',
          uriParams: { projectId: projectId, periodId: periodId, _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Documents unavailable',
            message: 'Could not load the attached documents: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        $page.variables.docs = ((resp.body && resp.body.items) || []).map((d) => ({
          docId: d.doc_id,
          docName: d.doc_name,
          mimeType: d.mime_type,
          sizeKb: d.size_kb,
          displayMode: d.display_mode,
          weekIndex: d.week_index,
          uploadedBy: d.uploaded_by,
          uploadedOn: d.uploaded_on,
          remarks: d.remarks || '',
        }));

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Documents unavailable',
          message: 'The document service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return loadDocsChain;
});
