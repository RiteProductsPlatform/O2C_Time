/* PAGE-005 Approval Detail — close an overridden week */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Closes the week after one or more overrides, landing it as
   * 'Overridden and approved' rather than a plain 'Approved'.
   *
   * The distinction matters downstream: it is one of the six workflow flags
   * carried into the accrual hand-off, so finance can see the hours were
   * manager-corrected rather than employee-entered.
   */
  class finishOverrideChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const weekId = $page.variables.weekId;
      if (!weekId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/finishOverride',
          uriParams: { tsWeekId: weekId },
          body: {
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          const status = ($application.functions.apiBody(resp).weekStatus) || 'Approved';
          $page.variables.overrideCount = 0;

          await Actions.fireNotificationEvent(context, {
            summary: 'Week closed',
            message: 'Week closed as "' + status + '".',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadWeeksChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not close the week',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Could not close the week'),
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

  return finishOverrideChain;
});
