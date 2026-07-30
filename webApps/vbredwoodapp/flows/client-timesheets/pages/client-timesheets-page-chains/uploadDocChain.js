/* PAGE-002 Client Timesheets — ACT-010 attach a signed timesheet */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Uploads the selected file.
   *
   * The base64 payload is decoded server-side in chunks (OC_TIME_B64_TO_BLOB),
   * where the 25MB ceiling and the MIME whitelist are table constraints — so a
   * caller that bypasses this page still cannot store a 40MB executable.
   */
  class uploadDocChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      if (!$page.variables.pendingBase64) {
        await Actions.fireNotificationEvent(context, {
          summary: 'No file selected',
          message: 'Choose a file to attach first.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      if ($page.variables.displayMode === 'Week-wise' && !$page.variables.weekIndex) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Week number required',
          message: 'Enter the week number for a week-wise document.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/uploadClientDoc',
          body: {
            projectId: $page.variables.projectId,
            periodId: $page.variables.periodId,
            displayMode: $page.variables.displayMode,
            weekIndex: $page.variables.displayMode === 'Week-wise'
                         ? $page.variables.weekIndex : null,
            docName: $page.variables.pendingFileName,
            mimeType: $page.variables.pendingMimeType,
            content: $page.variables.pendingBase64,
            remarks: $page.variables.remarks || null,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          const name = $page.variables.pendingFileName;

          // Clear the staged file so a second click cannot attach it twice.
          $page.variables.pendingBase64   = '';
          $page.variables.pendingFileName = '';
          $page.variables.pendingMimeType = '';
          $page.variables.pendingSize     = 0;
          $page.variables.pendingSizeKb   = 0;
          $page.variables.remarks         = '';
          $page.variables.uploadHint      = '';

          await Actions.fireNotificationEvent(context, {
            summary: 'Document attached',
            message: name + ' attached.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadDocsChain' });
          return;
        }

        // A 400 means empty, over the ceiling, or an unsupported type — the
        // server's message says which.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Document rejected' : 'Upload failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Upload failed',
          message: 'The service is unreachable. Please retry.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return uploadDocChain;
});
