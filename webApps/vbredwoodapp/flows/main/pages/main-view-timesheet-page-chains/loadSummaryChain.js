/* PAGE-004 View Timesheet — load the monthly summary */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the per-employee summary and works out whether the month can be
   * confirmed.
   *
   * The confirm gate is evaluated here from the employee rows AND re-evaluated on
   * the server when Confirm is pressed. The client copy exists only so the button
   * can be disabled with an explanation; the server is the authority (RULE-020).
   */
  class loadSummaryChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $application.variables.selectedProjectId;
      const periodId  = $application.variables.selectedPeriodId;

      if (!projectId || !periodId) { return; }

      $page.variables.busy = true;
      $page.variables.selectedKeys = [];

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMonthSummary',
          uriParams: { projectId: projectId, periodId: periodId, _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Summary unavailable',
            message: 'Could not load the monthly summary: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = ((resp.body && resp.body.items) || []).map((e) => ({
          employeeId: e.employee_id,
          employeeName: e.employee_name,
          workerType: e.worker_type,
          billingStatus: e.billing_status || '—',
          clientRole: e.client_role || '—',
          capType: e.cap_type,
          capHours: e.cap_hours,
          capDisplay: $page.functions.capDisplay(e.cap_type, e.cap_hours),
          billableHours: e.billable_hours || 0,
          nonBillableHours: e.non_billable_hours || 0,
          leaveHours: e.leave_hours || 0,
          totalHours: e.total_hours || 0,
          weekCount: e.week_count || 0,
          approvedWeeks: e.approved_weeks || 0,
          rejectedWeeks: e.rejected_weeks || 0,
          monthStatus: e.month_status,
          approvedOn: e.approved_on || '—',
          overriddenFlag: e.overridden_flag,
          advanceClosureFlag: e.advance_closure_flag,
          lateSubmissionFlag: e.late_submission_flag,
          defaultedFlag: e.defaulted_flag,
        }));

        $page.variables.employees = rows;

        const total    = rows.length;
        const approved = rows.filter((r) => r.monthStatus === 'Approved').length;
        const rejected = rows.filter((r) => r.monthStatus === 'Rejected').length;

        $page.variables.totalEmployees    = total;
        $page.variables.approvedEmployees = approved;
        $page.variables.rejectedEmployees = rejected;
        $page.variables.pendingEmployees  = total - approved - rejected;

        // ── Has this month already been confirmed? ─────────────
        // The landing page already knows, but this page can be reached directly,
        // so it is read again rather than assumed.
        let confirmed = false;
        try {
          const mgr = await Actions.callRest(context, {
            endpoint: 'oc_time/getMgrProjects',
            uriParams: {
              managerId: $application.variables.actingManagerId,
              periodId: periodId,
              _t: Date.now(),
            },
          });

          const proj = ((mgr.ok && mgr.body && mgr.body.items) || [])
            .find((p) => p.project_id === projectId);

          if (proj) {
            confirmed = !!proj.confirm_id;
            $page.variables.confirmedOn   = proj.confirmed_on || '';
            $page.variables.accrualStatus = proj.accrual_status || '';
          }
        } catch (e) {
          // Fall through: the gate below is still correct, it just cannot show
          // the previous confirmation details.
        }

        $page.variables.alreadyConfirmed = confirmed;

        // RULE-020: every employee approved, at least one employee, not already
        // confirmed.
        $page.variables.confirmAllowed =
          total > 0 && approved === total && !confirmed;

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

  return loadSummaryChain;
});
