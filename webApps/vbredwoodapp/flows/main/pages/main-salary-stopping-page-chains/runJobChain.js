/* PAGE-007 Salary Stopping — re-evaluate the holds */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Re-runs the salary-stopping evaluation for the period.
   *
   * Worth having as a manual action because the job normally fires at the payroll
   * cut-off: after a manager corrects several defaulted weeks they want the holds
   * recomputed now rather than at the next scheduled run. The job also
   * auto-releases anyone who no longer has a defaulted week, so this is how a
   * batch of corrections gets reflected in one step.
   */
  class runJobChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      if (!$page.variables.periodId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/runSalaryStopping',
          uriParams: { periodId: $page.variables.periodId },
          body: { actor: $application.variables.currentEmail },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Holds re-evaluated',
            message: 'Anyone with no defaulted week left has been released.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadHoldsChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Job failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Job failed',
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

  return runJobChain;
});
