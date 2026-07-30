/* PAGE-010 Sync Status — run the weekly cut-off defaulting job (RULE-006) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Runs the defaulting job for the chosen period.
   *
   * Confirmed first because it is consequential in a way the other two are not:
   * defaulting auto-submits unsubmitted weeks with default hours, LOCKS them to
   * the employee, and is what puts a salary hold on the people affected
   * (RULE-006 / RULE-016). Running it early would hold pay for employees who
   * still had time to file.
   */
  class runDefaultingChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId = $page.variables.runJobPeriodId;
      if (!periodId) { return; }

      $page.variables.busy = true;

      try {
        await Actions.callComponentMethod(context, {
          selector: '#runDefaultingDlg',
          method: 'close',
        });

        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/runDefaulting',
          uriParams: { periodId: periodId },
          body: {
            asOf: null,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          const n = (resp.body && resp.body.defaulted) || 0;
          await Actions.fireNotificationEvent(context, {
            summary: 'Defaulting complete',
            message: n === 0
              ? 'No week missed the cut-off.'
              : n + (n === 1 ? ' week was defaulted.' : ' weeks were defaulted.'),
            severity: n === 0 ? 'confirmation' : 'warning',
            type: n === 0 ? 'confirmation' : 'warning',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadStatusChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Defaulting failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Defaulting failed',
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

  return runDefaultingChain;
});
