/* PAGE-010 Sync Status — ACT-031 run the monthly population job */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Runs population for the chosen period.
   *
   * Safe to re-run: the job never overwrites an existing entry, so employee input
   * is preserved and only missing cells are created. That is what makes it usable
   * as a repair tool rather than only a first-time load.
   */
  class runPopulationChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId = $page.variables.runJobPeriodId;
      if (!periodId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/runPopulation',
          uriParams: { periodId: periodId },
          body: { actor: $application.variables.currentEmail },
        });

        if (resp.ok) {
          const b = resp.body || {};
          const failed = b.failed || 0;

          await Actions.fireNotificationEvent(context, {
            summary: failed ? 'Population finished with failures' : 'Population complete',
            message: (b.read || 0) + ' allocations read, ' +
                     (b.upserted || 0) + ' entries created' +
                     (failed ? ', ' + failed + ' failed — see the queue below.' : '.'),
            severity: failed ? 'warning' : 'confirmation',
            type: failed ? 'warning' : 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadStatusChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Population failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Population failed'),
          message: $application.functions.chainError(e, 'The job could not be started — the service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return runPopulationChain;
});
