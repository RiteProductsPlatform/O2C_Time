/* PAGE-009 Calendar — ACT-030 sync one calendar layer from Fusion */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Triggers a re-sync of one calendar layer (ACT-030).
   *
   * RA-005 closed calendar *authoring* — days are never edited here. Pulling the
   * layer again from Fusion is a different thing and is explicitly in scope: the
   * Pages sheet lists `sync-buttons` among PAGE-009's required components.
   *
   * The request body carries no days. OIC owns the extract from Fusion and posts
   * the day rows; this endpoint is the trigger, and precedence is derived from
   * the layer server-side so a caller can never set it wrongly.
   */
  class syncLayerChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{layer:string}} params CORPORATE | PROJECT | CLIENT | SHIFT
     */
    async run(context, { layer }) {
      const { $page, $application } = context;

      if (!layer) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/syncCalendarLayer',
          uriParams: { layer: layer },
          body: {
            days: [],
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          const n = ($application.functions.apiBody(resp).daysSynced) || 0;
          await Actions.fireNotificationEvent(context, {
            summary: 'Layer synced',
            message: layer + ': ' + n + ' day(s) synced from Fusion.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadLayersChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Sync failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Sync failed'),
          message: $application.functions.chainError(e, 'The calendar service is unreachable. Please retry.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return syncLayerChain;
});
