/* PAGE-001 My Timesheet — pull a submission back */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Revokes a week the employee submitted by mistake.
   *
   * A submitted week is frozen — it is with the manager, and editing underneath
   * a pending approval means they approve something other than what they read.
   * Without a way back, the only escape was to ask the manager to reject it,
   * which puts a rejection in the audit trail that never really happened.
   *
   * The server decides, not this chain: revoke_week refuses anything that is
   * not 'Submitted' (-20021) and refuses a closed period (-20022). Both arrive
   * as 400 carrying the rule's own message, so it is shown verbatim.
   */
  class revokeWeekChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const weekId = $page.variables.weekId;

      if (!weekId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/revokeWeek',
          uriParams: { id: weekId },
          body: {
            actor: $application.variables.employeeId,
            traceId: $application.functions.newTraceId(),
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Could not revoke',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Submission withdrawn',
          message: 'The week is back with you. Correct the hours and submit again.',
          severity: 'confirmation',
          type: 'confirmation',
          displayMode: 'transient',
        });

        // Reload rather than patching the status locally: the server also reset
        // every day to Draft, and editable is derived from the reloaded week.
        await Actions.callChain(context, { chain: 'periodChangedChain' });

      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Service unavailable'),
          message: $application.functions.chainError(e,
            'The timesheet service is unavailable. Please try again shortly.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return revokeWeekChain;
});
