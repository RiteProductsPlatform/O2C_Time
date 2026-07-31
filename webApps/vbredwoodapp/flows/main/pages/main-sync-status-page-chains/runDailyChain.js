/* PAGE-010 Sync Status — run the daily action-date process */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Runs the daily process for today against the open period.
   *
   * Scope is left empty so every base/deputed country is processed. The job runs
   * per country in production because the weekly cut-off is evaluated in local
   * time, but a manual repair run wants everything.
   */
  class runDailyChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/runDailyProcess',
          body: {
            actionDate: null,
            scopeKey: null,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Daily process complete',
            message: 'Allocation changes, hires, exits, transfers and shift changes have been applied.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadStatusChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Daily process failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Daily process failed',
          message: 'The job could not be started — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return runDailyChain;
});
