/* PAGE-005 Approval Detail — undo the decision on the selected weeks */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * The week-level counterpart of revokeDatesChain.
   *
   * One call per week rather than a bulk endpoint, because a partial failure
   * has to be reportable: revoke_decision refuses a closed week and a closed
   * period individually, so selecting five weeks of which one is closed must
   * undo the four and say so, not fail all five.
   */
  class revokeWeeksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const weeks = $page.variables.selectedWeekKeys || [];

      if (!weeks.length) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing selected',
          message: 'Select at least one week.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      let done = 0;
      let firstError = null;

      try {
        for (const id of weeks) {
          const resp = await Actions.callRest(context, {
            endpoint: 'oc_time/revokeWeekDecision',
            uriParams: { id: id },
            body: {
              actorEmpId: $application.variables.actingManagerId,
              actor: $application.variables.currentEmail,
              traceId: $application.variables.traceId ||
                       $application.functions.newTraceId(),
            },
          });

          if (resp.ok) { done += 1; }
          else if (!firstError) { firstError = $application.functions.restError(resp); }
        }

        $page.variables.selectedWeekKeys = [];

        if (done) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Decision undone',
            message: done + (done === 1 ? ' week is' : ' weeks are') +
                     ' back with you to decide.' +
                     (firstError ? ' Some could not be undone: ' + firstError : ''),
            severity: firstError ? 'warning' : 'confirmation',
            type: firstError ? 'warning' : 'confirmation',
            displayMode: 'transient',
          });
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Could not undo',
            message: firstError || 'Nothing was undone.',
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

        await Actions.callChain(context, { chain: 'loadWeeksChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Could not undo'),
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

  return revokeWeeksChain;
});
