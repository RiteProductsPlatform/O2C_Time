/* PAGE-007 Salary Stopping — ACT-026 release the hold */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Releases the salary hold so pay resumes in the next cycle.
   *
   * The server re-checks that no defaulted week remains, so even if the page's
   * copy of the data is stale the hold cannot be released while the time is still
   * missing. RULE-015 also applies — a manager cannot release their own hold.
   */
  class releaseHoldChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const holdId = $page.variables.releaseHoldId;
      if (!holdId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/releaseSalaryHold',
          uriParams: { id: holdId },
          body: {
            actorEmpId: $application.variables.actingManagerId,
            remarks: $page.variables.releaseRemarks || null,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          $page.variables.showRelease = false;
          await Actions.fireNotificationEvent(context, {
            summary: 'Hold released',
            message: 'Salary will be paid in the next cycle.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadHoldsChain' });
          return;
        }

        // A 400 is the ACT-026 precondition or RULE-015.
        await Actions.fireNotificationEvent(context, {
          summary: 'Hold not released',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
        await Actions.callChain(context, { chain: 'loadHoldsChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Release failed',
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

  return releaseHoldChain;
});
