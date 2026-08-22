/* PAGE-010 Sync Status — run the delivery cut-off defaulting job (RULE-007) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Marks submitted weeks the manager never decided on as Defaulted, with
   * DEFAULTED_BY = 'MANAGER'.
   *
   * Not behind a confirmation, unlike weekly defaulting. That one auto-submits
   * hours nobody entered, locks the week away from the employee and holds their
   * pay; this one changes a badge and holds nothing. The week stays unlocked and
   * the manager can still approve it, which is exactly what the flow expects
   * them to do next.
   */
  class runDeliveryDefaultingChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId = $page.variables.runJobPeriodId;
      if (!periodId) { return; }

      $page.variables.busy = true;
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/runDeliveryDefaulting',
          uriParams: { periodId },
          body: {
            asOf: null,
            actor: $application.variables.currentEmail,
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Delivery defaulting failed',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const n = ($application.functions.apiBody(resp).defaulted) || 0;
        await Actions.fireNotificationEvent(context, {
          summary: 'Delivery defaulting complete',
          message: n === 0
            ? 'Every submitted week was decided before the delivery cut-off, ' +
              'or the cut-off has not passed yet.'
            : n + (n === 1 ? ' week was' : ' weeks were')
              + ' marked Defaulted against the manager. They stay unlocked and '
              + 'can still be approved; no salary is held.',
          severity: n === 0 ? 'confirmation' : 'warning',
          type: n === 0 ? 'confirmation' : 'warning',
          displayMode: 'transient',
        });

      } catch (e) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Delivery defaulting failed',
          message: 'The service was unreachable. Nothing was changed.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
        await Actions.callChain(context, { chain: 'loadStatusChain' });
      }
    }
  }

  return runDeliveryDefaultingChain;
});
