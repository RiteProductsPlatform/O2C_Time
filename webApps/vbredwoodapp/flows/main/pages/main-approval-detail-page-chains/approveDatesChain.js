/* PAGE-005 Approval Detail — ACT-017 approve the selected dates */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approves specific dates in one call.
   *
   * The server closes the week automatically once every day is approved and
   * returns the resulting week status, so the message can tell the manager that
   * just happened rather than leaving them to check.
   */
  class approveDatesChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const dates = $page.variables.selectedDates || [];

      if (!dates.length) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing selected',
          message: 'Select at least one date.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/approveDays',
          uriParams: { id: $page.variables.weekId },
          body: {
            dates: dates.map((d) => $application.functions.toApiDate(d)),
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          const n = (resp.body && resp.body.approvedDates) || dates.length;
          const status = (resp.body && resp.body.weekStatus) || '';
          const closed = status === 'Approved' || status === 'Overridden and approved';

          $page.variables.selectedDates = [];

          await Actions.fireNotificationEvent(context, {
            summary: 'Dates approved',
            message: n + (n === 1 ? ' date approved.' : ' dates approved.') +
                     (closed ? ' Every day is approved, so the week is closed.' : ''),
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadWeeksChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Approve failed',
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

  return approveDatesChain;
});
