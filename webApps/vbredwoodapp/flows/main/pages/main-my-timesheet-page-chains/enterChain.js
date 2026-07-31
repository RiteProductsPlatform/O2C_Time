/* PAGE-001 My Timesheet — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Seeds the page from the application session and loads the project LOV once.
   *
   * The month is taken from the shared selectedPeriodId rather than defaulting
   * to "today", so returning from another page keeps the user where they were.
   * Setting periodId then fires periodChangedChain, which loads the weeks.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $application.variables.activeNav = 'main-my-timesheet';

      if (!$application.variables.employeeId) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Not signed in',
          message: 'Your worker record could not be resolved. Please sign in again.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
        return;
      }

      // Projects the employee may charge to: their allocations plus the
      // Organization (Non-Billable) project that everyone gets (FLD-006).
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMyProjects',
          uriParams: {
            employeeId: $application.variables.employeeId,
            _t: Date.now(),
          },
        });

        if (resp.ok && resp.body && resp.body.items) {
          $page.variables.projectOptionsArray = resp.body.items.map((p) => ({
            value: p.project_id,
            label: p.project_name,
            projectType: p.project_type,
            billingStatus: p.billing_status,
          }));
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
          summary: 'Projects unavailable',
          message: 'Could not load your projects — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }

      // Drives the weeks load. Falls back to the open period if nothing is set.
      const wanted = $application.variables.selectedPeriodId
                  || $application.variables.openPeriodId;

      // Assigning fires periodChangedChain — but only if the value actually
      // changes. Returning to a page already on that month would otherwise show
      // a stale grid, so reload explicitly in that case.
      if ($page.variables.periodId === wanted) {
        await Actions.callChain(context, { chain: 'periodChangedChain' });
      } else {
        $page.variables.periodId = wanted;
      }
    }
  }

  return enterChain;
});
