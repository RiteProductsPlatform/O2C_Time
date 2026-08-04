/* PAGE-005 Approval Detail — undo an approval or rejection on the selected dates */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Puts decided days back to Pending.
   *
   * Without this a mis-click was unrecoverable from the screen: approve_day only
   * ever writes 'Approved' and reject_day only 'Rejected', so the two buttons
   * that produce the mistake cannot correct it, and the manager's only route was
   * a retro adjustment for something that had never really happened.
   *
   * The server recomputes the week status from the days that remain and returns
   * it, because the answer is not obvious — undoing the only rejection in a week
   * takes it back to Submitted, undoing one approval in an otherwise approved
   * week reopens it, and the manager should not have to work out which.
   */
  class revokeDatesChain extends ActionChain {

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
          endpoint: 'oc_time/revokeDays',
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
          const n = (resp.body && resp.body.revokedDates) || dates.length;
          const status = (resp.body && resp.body.weekStatus) || '';

          $page.variables.selectedDates = [];

          await Actions.fireNotificationEvent(context, {
            summary: 'Decision undone',
            message: n + (n === 1 ? ' date is' : ' dates are') +
                     ' back to Pending.' +
                     (status ? ' The week is now ' + status + '.' : ''),
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadWeeksChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not undo',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

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

  return revokeDatesChain;
});
