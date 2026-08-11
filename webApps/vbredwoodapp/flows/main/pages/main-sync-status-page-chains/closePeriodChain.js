/* PAGE-010 — close a period, once the dialog is confirmed.
 *
 * force is never sent from here. OC_TIME_CLOSE_PERIOD refuses while any
 * project is unconfirmed, and that refusal is the point — advance closure is a
 * deliberate act that goes through 92_month_end_close.sql, not something
 * reachable by pressing the ordinary button twice.
 */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class closePeriodChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      await Actions.callComponentMethod(context, {
        selector: '#closePeriodDlg',
        method: 'close',
      });

      const periodId = $page.variables.closePeriodId;
      if (!periodId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/closePeriod',
          uriParams: { periodId },
          body: { actor: $application.variables.currentEmail },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: resp.body.periodName + ' is Closed',
            message: 'It stays visible and its hours stay on screen. Only editing is gated.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadPeriodsChain' });
          await Actions.callChain(context, { chain: 'loadStatusChain' });
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Could not close the period',
            // The rule's own wording, ORA- prefix already stripped by the
            // handler, so it names the unconfirmed count and what to do.
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Could not close the period'),
          message: $application.functions.chainError(e, 'The period service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
        $page.variables.closePeriodId = null;
      }
    }
  }

  return closePeriodChain;
});
