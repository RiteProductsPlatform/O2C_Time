/* PAGE-012 Integrations — load the reference catalogue */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the catalogue from OC_TIME_LOOKUP via the admin endpoint.
   *
   * Held as seeded data rather than hard-coded markup so that when an endpoint
   * path or load pattern changes it is a seed update, not a page redeploy. The
   * area filter is applied client-side by filterIntegrationsChain because the
   * whole catalogue is a handful of rows.
   */
  class loadIntegrationsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getIntegrations',
          uriParams: { _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Catalogue unavailable',
            message: 'Could not load the integration catalogue: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        $page.variables.rowsRaw = (($application.functions.apiBody(resp).items) || []).map((i) => ({
          integrationId: i.integration_id,
          area: i.area || '',
          fusionSource: i.fusion_source || '',
          objectUsage: i.object_usage || '',
          restResource: i.rest_resource || '',
          loadPattern: i.load_pattern || '',
          notes: i.notes || '',
        }));

        await Actions.callChain(context, { chain: 'filterIntegrationsChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Catalogue unavailable'),
          message: $application.functions.chainError(e, 'Could not load the integration catalogue — the service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadIntegrationsChain;
});
