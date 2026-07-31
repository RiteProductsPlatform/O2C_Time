/* PAGE-011 Accrual Integration — ACT-033 post approved retro adjustments */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Tops up the interface table with the Reversal(-)/Adjustment(+) rows of
   * adjustments approved after their month was confirmed.
   *
   * Not confirmed with a dialog, unlike the manager's approve-all. Nothing here
   * is a decision: the adjustments were already approved by their managers, and
   * this only carries rows that should have gone across. Running it when there
   * is nothing to post is a no-op, and the endpoint guards on
   * (confirm_id, source_ts_id, entry_type) so a double click cannot double-post.
   *
   * The row count is reported rather than a bare "done", because zero is the
   * normal answer and the admin needs to be able to tell it from a failure.
   */
  class runAccrualJobChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId = $page.variables.periodId;
      if (!periodId) {
        await Actions.fireNotificationEvent(context, {
          summary: 'No period selected',
          message: 'Choose a month first.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/runAccrualJob',
          uriParams: { periodId },
          body: {
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Nothing posted',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows   = (resp.body && resp.body.rowsPosted) || 0;
        const months = (resp.body && resp.body.monthsChecked) || 0;

        await Actions.fireNotificationEvent(context, {
          summary: rows ? 'Adjustments posted' : 'Nothing to post',
          message: rows
            ? rows + (rows === 1 ? ' adjustment row' : ' adjustment rows')
              + ' added to the interface across ' + months
              + (months === 1 ? ' confirmed month.' : ' confirmed months.')
            : 'Every approved adjustment for this period is already in the '
              + 'interface. Nothing was added.',
          severity: rows ? 'confirmation' : 'info',
          type: rows ? 'confirmation' : 'info',
          displayMode: 'transient',
        });

      } catch (e) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing posted',
          message: 'The service was unreachable. The interface is unchanged.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
        // Reload either way: the confirmed-months totals change when rows post,
        // and on failure this shows they did not.
        await Actions.callChain(context, { chain: 'loadConfirmedChain' });
      }
    }
  }

  return runAccrualJobChain;
});
