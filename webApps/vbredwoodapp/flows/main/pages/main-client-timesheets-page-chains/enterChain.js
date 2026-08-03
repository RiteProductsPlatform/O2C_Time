/* PAGE-002 Client Timesheets — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the project LOV and seeds the billing period from the shared session
   * selection, so arriving from My Timesheet keeps the same month.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $application.variables.activeNav = 'main-client-timesheets';

      $page.variables.periodId = $application.variables.selectedPeriodId
                              || $application.variables.openPeriodId;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMyProjects',
          uriParams: {
            employeeId: $application.variables.employeeId,
            _t: Date.now(),
          },
        });

        if (resp.ok && resp.body && resp.body.items) {
          // The Organization (Non-Billable) project has no client, so a signed
          // client timesheet cannot exist for it — keep it out of the picker.
          const billable = resp.body.items
            .filter((p) => p.project_type !== 'Organization');

          $page.variables.projectOptionsArray = billable.map((p) => ({
            value: p.project_id,
            label: p.project_name,
          }));

          // One project is the common case for a delivery consultant; select it
          // so the page is immediately usable.
          if (billable.length === 1) {
            $page.variables.projectId = billable[0].project_id;
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
    }
  }

  return enterChain;
});
