/* PAGE-010 Sync Status — ACT-032 retry one failed record */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Retries a failed record by re-running population for that employee.
   *
   * A retry only succeeds if the underlying cause has been fixed at source — an
   * allocation created, a shift calendar loaded. The response says whether the
   * record actually resolved, so the message distinguishes "fixed" from "tried
   * again and it still fails", rather than implying success either way.
   */
  class retryRecordChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{failedId:number}} params
     */
    async run(context, { failedId }) {
      const { $page, $application } = context;

      if (!failedId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/retryFailed',
          uriParams: { failedId: failedId },
          body: { actor: $application.variables.currentEmail },
        });

        if (resp.ok) {
          const b = resp.body || {};

          if (b.retried === false) {
            // No employee on the record — nothing to re-run automatically.
            await Actions.fireNotificationEvent(context, {
              summary: 'Resolve at source',
              message: b.message || 'This record has to be resolved at source.',
              severity: 'warning',
              type: 'warning',
              displayMode: 'transient',
            });
          } else {
            await Actions.fireNotificationEvent(context, {
              summary: b.resolved ? 'Record resolved' : 'Still failing',
              message: b.resolved
                ? 'Reprocessed and resolved.'
                : 'Retried, but it still fails — the underlying cause has not been fixed yet.',
              severity: b.resolved ? 'confirmation' : 'warning',
              type: b.resolved ? 'confirmation' : 'warning',
              displayMode: 'transient',
            });
          }

          await Actions.callChain(context, { chain: 'loadStatusChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Retry failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Retry failed',
          message: 'The retry could not be started — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return retryRecordChain;
});
