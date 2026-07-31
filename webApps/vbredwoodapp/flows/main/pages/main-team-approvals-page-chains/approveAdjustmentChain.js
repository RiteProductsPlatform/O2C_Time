/* PAGE-003 Team Approvals — ACT-021 approve a retro adjustment */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approves one day-wise backdated change.
   *
   * A cross-project change needs BOTH the old and the new project manager
   * (RA-014). The server tracks each side separately and only materialises the
   * Reversal(-)/Adjustment(+) pair once both have approved, so a single approval
   * may legitimately leave the row still pending — the response says which
   * happened, and the message reflects it rather than claiming it is done.
   */
  class approveAdjustmentChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{adjustmentId:number}} params
     */
    async run(context, { adjustmentId }) {
      const { $page, $application } = context;

      if (!adjustmentId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/approveAdjustment',
          uriParams: { id: adjustmentId },
          body: {
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          const posted = resp.body && resp.body.posted === 'Y';

          await Actions.fireNotificationEvent(context, {
            summary: posted ? 'Adjustment posted' : 'Approval recorded',
            message: posted
              ? 'Adjustment approved and posted to the open period.'
              : 'Your approval is recorded. The change posts once the other project manager approves.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadProjectsChain' });
          return;
        }

        // A 400 is RULE-015 self-approval, or the adjustment was withdrawn.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Adjustment refused' : 'Approve failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Approve failed',
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

  return approveAdjustmentChain;
});
