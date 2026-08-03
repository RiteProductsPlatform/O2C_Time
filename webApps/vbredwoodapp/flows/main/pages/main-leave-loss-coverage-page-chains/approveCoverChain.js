/* PAGE-006 Leave Loss Coverage — ACT-023 approve one coverage line */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approving coverage is what turns the absence into BILLED hours and puts the
   * line on the invoice annexure (REP-002) — so it is a revenue-affecting action,
   * not just a status change.
   */
  class approveCoverChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{llcId:number}} params
     */
    async run(context, { llcId }) {
      const { $page, $application } = context;

      if (!llcId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/approveCover',
          uriParams: { id: llcId },
          body: {
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Coverage approved',
            message: 'The absence hours are now billed.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadLinesChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not approve',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Approve failed'),
          message: $application.functions.chainError(e, 'The service is unreachable. Please retry.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return approveCoverChain;
});
