/* PAGE-011 Accrual Integration — confirmed months + the leave-loss annexure */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the confirmed project-months for the period and the leave-loss
   * annexure that accompanies them.
   *
   * Changing the period invalidates any open extract, so it is cleared rather
   * than left showing rows from a month the user is no longer looking at.
   */
  class loadConfirmedChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId = $page.variables.periodId;
      if (!periodId) { return; }

      $application.variables.selectedPeriodId = periodId;

      $page.variables.busy = true;
      $page.variables.confirmId    = null;
      $page.variables.extractLabel = '';
      $page.variables.extractRaw   = [];
      $page.variables.extract      = [];

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getConfirmedMonths',
          uriParams: { periodId: periodId, _t: Date.now() },
        });

        if (resp.ok) {
          $page.variables.confirmed = ((resp.body && resp.body.items) || []).map((c) => ({
            confirmId: c.confirm_id,
            projectNumber: c.project_number,
            projectName: c.project_name,
            customerName: c.customer_name || '—',
            revenueModel: c.revenue_model || '',
            periodName: c.period_name,
            employeeCount: c.employee_count || 0,
            billableHours: c.billable_hours || 0,
            nonBillableHours: c.non_billable_hours || 0,
            leaveHours: c.leave_hours || 0,
            adjustmentHours: c.adjustment_hours || 0,
            confirmType: c.confirm_type,
            confirmedBy: c.confirmed_by || '',
            confirmedOn: c.confirmed_on || '',
            otlStatus: c.otl_status || 'Pending',
            otlPushedOn: c.otl_pushed_on || '',
            otlMessage: c.otl_message || '',
            accrualStatus: c.accrual_status || 'Pending',
            accrualRows: c.accrual_rows || 0,
            accrualPushedOn: c.accrual_pushed_on || '',
            accrualMessage: c.accrual_message || '',
            partnerStatus: c.partner_status || '',
            rowsPulled: c.rows_pulled || 0,
            rowsPending: c.rows_pending || 0,
            traceId: c.trace_id || '',
          }));
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Confirmations unavailable',
            message: 'Could not load the confirmed months: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

        // ── Leave-loss annexure (REP-002) ──────────────────────
        // Supporting detail: a failure here must not blank the page.
        try {
          const ann = await Actions.callRest(context, {
            endpoint: 'oc_time/getLlcAnnexure',
            uriParams: { periodId: periodId, _t: Date.now() },
          });

          $page.variables.annexure =
            ((ann.ok && ann.body && ann.body.items) || []).map((a) => ({
              llcId: a.llc_id,
              projectNumber: a.project_number,
              projectName: a.project_name,
              customerName: a.customer_name || '—',
              periodName: a.period_name,
              absentEmployeeId: a.absent_employee_id,
              absentEmployeeName: a.absent_employee_name,
              absenceDate: a.absence_date,
              absenceType: a.absence_type || '—',
              coveredBilledHours: a.covered_billed_hours || 0,
              coverEmployeeId: a.cover_employee_id || '',
              coverEmployeeName: a.cover_employee_name || '',
              approvedBy: a.approved_by || '',
              approvedOn: a.approved_on || '',
            }));
        } catch (e) {
          $page.variables.annexure = [];
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Service unavailable',
          message: 'The accrual service is unreachable. Please try again shortly.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadConfirmedChain;
});
