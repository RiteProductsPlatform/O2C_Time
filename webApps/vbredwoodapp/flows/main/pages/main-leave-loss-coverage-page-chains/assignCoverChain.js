/* PAGE-006 Leave Loss Coverage — ACT-022 assign a cover */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Assigns the chosen colleague.
   *
   * RULE-014 is re-checked server-side even though the LOV was already filtered:
   * between opening the dialog and pressing Assign someone else may have taken
   * that colleague for the same day. A 400 here is that race, and the rule's own
   * message explains it.
   */
  class assignCoverChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const llcId = $page.variables.assignLlcId;
      const cover = $page.variables.assignCoverId;

      if (!llcId || !cover) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/assignCover',
          uriParams: { id: llcId },
          body: {
            coverEmployeeId: cover,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          $page.variables.showAssign = false;
          await Actions.fireNotificationEvent(context, {
            summary: 'Cover assigned',
            message: 'Approve it to make the hours billed.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadLinesChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not assign',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
        // Reload so the LOV and the grid reflect whatever changed underneath.
        await Actions.callChain(context, { chain: 'loadLinesChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Assign failed',
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

  return assignCoverChain;
});
