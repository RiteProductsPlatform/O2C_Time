/* PAGE-004 View Timesheet — ACT-012 approve the selected employees */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approves the ticked employees' month in one call.
   *
   * The ids go as a JSON array so the whole selection is one transaction — a
   * partially applied bulk approve would leave the manager unsure what actually
   * happened, and would make the RULE-020 confirm gate flicker.
   *
   * RULE-015 is enforced server-side: if the manager is on their own project the
   * call is refused with that rule's message rather than silently skipping them.
   */
  class approveSelectedChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const selected = $page.variables.selectedKeys || [];

      if (!selected.length) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing selected',
          message: 'Select at least one employee.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/approveMonth',
          body: {
            projectId: $application.variables.selectedProjectId,
            periodId: $application.variables.selectedPeriodId,
            employees: selected,
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          const n = (resp.body && resp.body.approved) || selected.length;
          await Actions.fireNotificationEvent(context, {
            summary: 'Approved',
            message: n + (n === 1 ? ' employee approved.' : ' employees approved.'),
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadSummaryChain' });
          return;
        }

        // A 400 names the rule, e.g. "A manager's own time is approved by their
        // reporting manager."
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Nothing was approved' : 'Approve failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

        if (resp.status === 400) {
          // Reload: the transaction rolled back, so the screen should reflect the
          // unchanged server state rather than an optimistic guess.
          await Actions.callChain(context, { chain: 'loadSummaryChain' });
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Approve failed',
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

  return approveSelectedChain;
});
