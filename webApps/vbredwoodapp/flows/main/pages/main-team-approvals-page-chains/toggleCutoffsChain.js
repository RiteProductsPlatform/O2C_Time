/* PAGE-003 Team Approvals — show/hide the all-cut-offs panel (FLD-036) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Toggles the panel, fetching the cut-offs on first open if the initial load
   * could not get them.
   */
  class toggleCutoffsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const opening = !$page.variables.showCutoffs;
      $page.variables.showCutoffs = opening;

      if (!opening || $page.variables.cutoffs) { return; }

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getCutoffs',
          uriParams: { periodId: $page.variables.periodId, _t: Date.now() },
        });

        if (resp.ok && resp.body && resp.body.items && resp.body.items.length) {
          $page.variables.cutoffs = resp.body.items[0];
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'No cut-offs configured',
            message: 'Cut-off dates are not configured for this period.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Cut-offs unavailable'),
          message: $application.functions.chainError(e, 'Could not load the cut-off dates.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return toggleCutoffsChain;
});
