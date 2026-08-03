/* PAGE-003 Team Approvals — ACT-024 advance-approve a future month */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Advance-approves a whole future project month (PROC-010).
   *
   * This is deliberately confirmed: it approves time that has not been worked
   * yet, tags the month 'Advance closure', and means any later actuals arrive as
   * flagged adjustments instead of normal entries. That is a finance decision,
   * not a routine click.
   *
   * No employee list is sent, so the server applies it at month level for every
   * employee on the project — which is what "advance close the month" means.
   */
  class advanceApproveChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $page.variables.advanceProjectId;
      if (!projectId) { return; }

      const project = ($page.variables.projectsRaw || [])
        .find((p) => p.projectId === projectId);
      const name = project ? project.projectName : 'this project';

      $page.variables.busy = true;

      try {
        await Actions.callComponentMethod(context, {
          selector: '#advanceApproveDlg',
          method: 'close',
        });

        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/advanceApprove',
          body: {
            projectId: projectId,
            periodId: $page.variables.periodId,
            employees: null,
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Month advance-approved',
            message: name + ' advance-approved for ' +
                     $application.variables.selectedPeriodName + '.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadProjectsChain' });
          return;
        }

        // A 400 is most often RULE-015: the manager is on the project themselves.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Advance approval refused'
                                       : 'Advance approval failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Advance approval failed'),
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

  return advanceApproveChain;
});
