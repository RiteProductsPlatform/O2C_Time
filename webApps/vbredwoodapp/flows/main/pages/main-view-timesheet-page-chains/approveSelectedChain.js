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
   * NO LONGER ALL-OR-NOTHING, and the reasoning it replaces is worth keeping.
   * This used to send the selection as one transaction, on the grounds that a
   * partial apply would leave the manager unsure what happened. That assumed
   * the failure was exceptional. It is not: a manager who books time to their
   * own project appears in their own team list, RULE-015 refuses their row, and
   * the whole batch rolled back — nine approvable months lost to the tenth,
   * reported only as approved:0. "Select all pending" was therefore broken for
   * every manager who is a member of their own project, which is most of them.
   *
   * The server now isolates each employee and reports who was skipped and why.
   * The original worry is answered better this way: the manager is told exactly
   * which rows did not go through, instead of being told nothing went through.
   *
   * RULE-015 is still enforced server-side and is never silently swallowed —
   * a skipped row is always named.
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
          const b = (resp.body) || {};
          const n = b.approved || 0;
          const skipped = b.skipped || 0;

          // Partial success is a warning, not a tick. Showing "9 approved" in
          // confirmation green while one was silently refused is how a month
          // gets confirmed with a hole in it.
          await Actions.fireNotificationEvent(context, {
            summary: $application.functions.countSummary(n, skipped, 'approved'),
            message: $application.functions.countOutcome(n, skipped, 'employee',
                       'employees', 'approved', b.error),
            severity: $application.functions.countSeverity(n, skipped),
            type: $application.functions.countSeverity(n, skipped),
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadSummaryChain' });
          return;
        }

        // A 400 now means NOTHING went through — every selected row was
        // refused. The message names each one and the rule that refused it.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Nothing was approved' : 'Approve failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

        if (resp.status === 400) {
          // Reload: nothing was applied, so the screen should reflect the
          // unchanged server state rather than an optimistic guess.
          await Actions.callChain(context, { chain: 'loadSummaryChain' });
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Approve failed'),
          message: $application.functions.chainError(e, 'The service is unreachable. Please retry.'),
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
