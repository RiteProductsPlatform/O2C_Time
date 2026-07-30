define([], () => {
  'use strict';

  /** Security PAGE-002: the attachment policy ceiling is 25 MB. */
  const MAX_BYTES = 26214400;

  /**
   * PAGE-002 Client Timesheets — page module functions.
   *
   * File handling lives here rather than in a chain because it is browser API
   * work (FileReader), not a business step.
   */
  class PageModule {

    /**
     * Reads the picked file and base64-encodes it for the ORDS upload.
     *
     * The size check happens here so the user is told immediately instead of
     * after uploading 30MB and being rejected. The server checks again — this is
     * courtesy, not the control.
     */
    fileSelected(event) {
      const page = this.$page.variables;

      page.uploadHint      = '';
      page.pendingFileName = '';
      page.pendingMimeType = '';
      page.pendingBase64   = '';
      page.pendingSize     = 0;
      page.pendingSizeKb   = 0;

      const files = event && event.detail && event.detail.files;
      if (!files || !files.length) { return; }

      const file = files[0];

      if (file.size > MAX_BYTES) {
        page.uploadHint = 'That file is ' + Math.round(file.size / 1048576) +
          ' MB. The limit is 25 MB — please attach a smaller or split document.';
        return;
      }

      if (file.size === 0) {
        page.uploadHint = 'That file is empty.';
        return;
      }

      const reader = new FileReader();

      reader.onload = () => {
        // readAsDataURL gives 'data:<mime>;base64,<payload>'. Only the payload
        // goes to the server; the prefix would corrupt the decode.
        const result = String(reader.result || '');
        const comma  = result.indexOf(',');

        page.pendingBase64   = comma >= 0 ? result.substring(comma + 1) : '';
        page.pendingFileName = file.name;
        page.pendingMimeType = file.type || 'application/octet-stream';
        page.pendingSize     = file.size;
        page.pendingSizeKb   = Math.round(file.size / 1024);
      };

      reader.onerror = () => {
        page.uploadHint = 'That file could not be read. Please try again.';
      };

      reader.readAsDataURL(file);
    }

    /**
     * URL of a document, for a plain anchor.
     *
     * The response is a binary stream, so it is linked rather than fetched:
     * pulling a 20 MB PDF into a JS variable only to re-blob it would double the
     * memory for no benefit, and the browser already knows how to display it.
     *
     * An <a href> rather than window.open because JET's SES lockdown blocks
     * browser globals in page modules — window.open throws
     * SES_UNCAUGHT_EXCEPTION (knowledge/14 §7).
     */
    downloadUrl(docId) {
      return this.$application.variables.ordsBaseUrl + '/oc/time/clientdocs/' + docId;
    }

    /** Accessible name for a document's download link. */
    downloadLabel(docName) {
      return 'Download ' + docName;
    }

    /** Accessible name for a document's remove button. */
    removeLabel(docName) {
      return 'Remove ' + docName;
    }

    /**
     * Delegates to the chain that opens the confirmation dialog.
     *
     * The payload is a bare { docId } because that is exactly the shape the
     * page's askRemoveDoc listener destructures ({{ $event.docId }}). Nesting it
     * under `detail` would arrive as undefined and delete nothing.
     */
    askRemoveDoc(docId) {
      this.$page.listeners.askRemoveDoc({ docId: docId });
    }
  }

  return PageModule;
});
