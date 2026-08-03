/* PAGE-006 Leave Loss Coverage — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Builds the project picker from the manager's projects, keeping only those
   * that satisfy the PROC-006 entry condition: revenue model FCP AND leave loss
   * enabled. Filtering here rather than showing everything means the manager is
   * never offered a project where coverage is meaningless.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $application.variables.activeNav = 'main-leave-loss-coverage';

      const periodId = $application.variables.selectedPeriodId
                    || $application.variables.openPeriodId;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMgrProjects',
          uriParams: {
            managerId: $application.variables.actingManagerId,
            periodId: periodId,
            _t: Date.now(),
          },
        });

        if (resp.ok && resp.body && resp.body.items) {
          const eligible = resp.body.items.filter(
            (p) => p.revenue_model === 'FCP' && p.leave_loss_flag === 'Y');

          $page.variables.projectOptionsArray = eligible.map((p) => ({
            value: p.project_id,
            label: p.project_name,
          }));

          if (eligible.length === 1) {
            $page.variables.projectId = eligible[0].project_id;
          }
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Projects unavailable',
            message: 'Could not load your projects: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Projects unavailable'),
          message: $application.functions.chainError(e, 'Could not load your projects — the service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }

      // Set last: it triggers loadLinesChain once the project may already be set.
      if ($page.variables.periodId === periodId) {
        await Actions.callChain(context, { chain: 'loadLinesChain' });
      } else {
        $page.variables.periodId = periodId;
      }
    }
  }

  return enterChain;
});
