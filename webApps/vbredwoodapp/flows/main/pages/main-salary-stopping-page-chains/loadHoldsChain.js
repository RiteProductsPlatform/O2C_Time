/* PAGE-007 Salary Stopping — load the holds */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the holds for the period, scoped to this manager's team.
   *
   * managerId is a query parameter rather than a path segment because it is
   * genuinely optional: an admin viewing the same endpoint wants every hold in
   * the period, not just their own reports. It goes in uriParams alongside the
   * path parameters — VBCS routes each one by what the OpenAPI spec declares it
   * to be, and a parameter passed any other way is silently dropped.
   */
  class loadHoldsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId = $page.variables.periodId;
      if (!periodId) { return; }

      $application.variables.selectedPeriodId = periodId;
      $page.variables.busy = true;

      try {
        // An admin sees the whole period; a manager sees their own reports.
        const isAdmin = $application.variables.currentRole === 'ROLE_TIME_ADMIN';

        const uriParams = { periodId: periodId, _t: Date.now() };
        if (!isAdmin) {
          uriParams.managerId = $application.variables.actingManagerId;
        }

        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getSalaryHold',
          uriParams: uriParams,
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Holds unavailable',
            message: 'Could not load the salary holds: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = ((resp.body && resp.body.items) || []).map((h) => ({
          holdId: h.hold_id,
          employeeId: h.employee_id,
          employeeName: h.employee_name,
          workerType: h.worker_type,
          baseCountry: h.base_country || '',
          weeksTotal: h.weeks_total || 0,
          weeksSubmitted: h.weeks_submitted || 0,
          weeksDefaulted: h.weeks_defaulted || 0,
          weeksSplit: h.weeks_split || '',
          appliedHours: h.applied_hours || 0,
          defaultHours: h.default_hours || 0,
          salaryStatus: h.salary_status,
          holdReleaseDays: h.hold_release_days || 0,
          windowExpiresOn: h.window_expires_on || '',
          windowExpired: h.window_expired,
          heldOn: h.held_on || '',
          releasedOn: h.released_on || '',
          releasedBy: h.released_by || '',
          remarks: h.remarks || '',
        }));

        $page.variables.holds = rows;

        $page.variables.heldCount     = rows.filter((r) => r.salaryStatus === 'Held').length;
        $page.variables.releasedCount = rows.filter((r) => r.salaryStatus === 'Released').length;
        $page.variables.expiredCount  = rows.filter(
          (r) => r.salaryStatus === 'Held' && r.windowExpired === 'Y').length;

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Service unavailable'),
          message: $application.functions.chainError(e, 'The timesheet service is unavailable. Please try again shortly.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadHoldsChain;
});
