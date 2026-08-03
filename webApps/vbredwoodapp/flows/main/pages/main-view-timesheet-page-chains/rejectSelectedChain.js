/* PAGE-004 View Timesheet — ACT-013 reject the selected employees */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Rejects the ticked employees' month with a mandatory reason.
   *
   * RULE-013 makes the reason mandatory and restricts it to Manager / Client /
   * Absence. It is checked here so the dialog can stay open and keep the typed
   * remarks, and again in the database as a CHECK constraint so no caller can
   * store a rejection without one.
   *
   * Rejecting unlocks the weeks so the employee can correct and resubmit
   * (PROC-005 / RULE-007).
   */
  class rejectSelectedChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const selected = $page.variables.selectedKeys || [];
      const reason   = $page.variables.rejectReason;

      if (!selected.length) { return; }

      if (!reason) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Reason required',
          message: 'Select a rejection reason.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/rejectMonth',
          body: {
            projectId: $application.variables.selectedProjectId,
            periodId: $application.variables.selectedPeriodId,
            employees: selected,
            reason: reason,
            remarks: $page.variables.rejectRemarks || null,
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          const n = (resp.body && resp.body.rejected) || selected.length;

          $page.variables.showReject    = false;
          $page.functions.setDialog('rejectDlg', false);
          $page.variables.rejectReason  = '';
          $page.variables.rejectRemarks = '';

          await Actions.fireNotificationEvent(context, {
            summary: 'Rejected',
            message: n + (n === 1 ? ' employee' : ' employees') +
                     ' rejected — back with them to correct and resubmit.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadSummaryChain' });
          return;
        }

        // The dialog deliberately stays open on a 400 so the typed remarks are
        // not lost.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Nothing was rejected' : 'Reject failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Reject failed',
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

  return rejectSelectedChain;
});
