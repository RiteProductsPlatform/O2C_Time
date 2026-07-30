/* PAGE-005 Approval Detail — ACT-014 approve the selected weeks */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approves each ticked week. Approving a week marks every one of its days
   * approved, which is what the BRD means by weekly approval.
   *
   * One call per week rather than a batch: each week is an independent decision,
   * so if the third of five is refused (say RULE-015 self-approval) the first two
   * are still legitimately approved. The summary then reports exactly what
   * happened instead of implying all-or-nothing.
   */
  class approveWeeksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const keys = $page.variables.selectedWeekKeys || [];
      if (!keys.length) {
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
      let failed = 0;
      let firstError = '';

      try {
        for (let i = 0; i < keys.length; i++) {
          try {
            const resp = await Actions.callRest(context, {
              endpoint: 'oc_time/approveWeek',
              uriParams: { id: keys[i] },
              body: {
                actorEmpId: $application.variables.actingManagerId,
                actor: $application.variables.currentEmail,
                traceId: $application.variables.traceId ||
                         $application.functions.newTraceId(),
              },
            });

            if (resp.ok) {
              done++;
            } else {
              failed++;
              if (!firstError) {
                firstError = $application.functions.restError(resp);
              }
            }
          } catch (e) {
            failed++;
            if (!firstError) { firstError = 'The service was unreachable.'; }
          }
        }

        if (done && !failed) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Approved',
            message: done + (done === 1 ? ' week approved.' : ' weeks approved.'),
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
        } else if (done && failed) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Partly approved',
            message: done + ' approved, ' + failed + ' failed. ' + firstError,
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Nothing approved',
            message: firstError || 'No weeks could be approved.',
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

        await Actions.callChain(context, { chain: 'loadWeeksChain' });

      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return approveWeeksChain;
});
