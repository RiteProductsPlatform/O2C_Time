/* PAGE-010 — open a period so its weeks become editable.
 *
 * No confirmation dialog, deliberately. Opening only widens what can be
 * edited and is undone by closing again; RULE-017 is relaxed, so several
 * months may be Open at once and this cannot collide with another. Closing
 * is the one that asks, because closing cannot be undone by approving.
 */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class openPeriodChain extends ActionChain {

    async run(context, { periodId }) {
      const { $page, $application } = context;

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/openPeriod',
          uriParams: { periodId },
          body: { actor: $application.variables.currentEmail },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: resp.body.periodName + ' is Open',
            message: 'Its weeks are editable, subject to the delivery cut-off.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadPeriodsChain' });
          // The rollover writes a job row, so the card list above is now stale.
          await Actions.callChain(context, { chain: 'loadStatusChain' });
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Could not open the period',
            // The database message is the rule's own wording, already stripped
            // of the ORA- prefix by the handler, so it is shown verbatim.
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Could not open the period'),
          message: $application.functions.chainError(e, 'The period service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return openPeriodChain;
});
