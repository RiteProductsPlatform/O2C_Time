/* PAGE-003 Team Approvals — load projects, cut-offs and pending adjustments */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads everything the landing page shows for the selected month.
   *
   * All three fetches are independent, so a failure in one must not blank the
   * others: the projects table is the point of the page, while the cut-off panel
   * and the adjustment panel are supporting detail.
   */
  class loadProjectsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const periodId  = $page.variables.periodId;
      const managerId = $application.variables.actingManagerId;

      if (!periodId || !managerId) { return; }

      $application.variables.selectedPeriodId = periodId;

      // Remember the period name and whether it is in the future, which decides
      // whether the advance-approval panel appears (PROC-010).
      const opts = $application.variables.periodOptionsArray || [];
      const meta = opts.find((o) => o.value === periodId);
      if (meta) {
        $application.variables.selectedPeriodName = meta.label;
        $page.variables.isFuturePeriod = meta.periodState === 'Future';
      }

      $page.variables.busy = true;

      try {
        // ── Projects managed ────────────────────────────────────
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMgrProjects',
          uriParams: { managerId: managerId, periodId: periodId, _t: Date.now() },
        });

        if (resp.ok) {
          // Stored unfiltered; filterProjectsChain derives what the table shows,
          // so typing in the filter costs no round-trip.
          $page.variables.projectsRaw = ((resp.body && resp.body.items) || [])
            .map((p) => ({
              projectId: p.project_id,
              projectNumber: p.project_number,
              projectName: p.project_name,
              customerName: p.customer_name,
              revenueModel: p.revenue_model,
              leaveLossFlag: p.leave_loss_flag,
              periodName: p.period_name,
              tsStart: p.ts_start,
              tsEnd: p.ts_end,
              employees: p.employees || 0,
              approvedEmployees: p.approved_employees || 0,
              rejectedEmployees: p.rejected_employees || 0,
              pendingEmployees: p.pending_employees || 0,
              monthStatus: p.month_status,
              approvedOn: p.approved_on || '—',
              billableHours: p.billable_hours || 0,
              nonBillableHours: p.non_billable_hours || 0,
              leaveHours: p.leave_hours || 0,
              confirmAllowed: p.confirm_allowed,
              confirmId: p.confirm_id,
              confirmType: p.confirm_type,
              confirmedOn: p.confirmed_on,
              accrualStatus: p.accrual_status,
              pendingAdjustments: p.pending_adjustments || 0,
            }));

          await Actions.callChain(context, { chain: 'filterProjectsChain' });
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

        // ── Cut-offs (FLD-036) ─────────────────────────────────
        try {
          const cut = await Actions.callRest(context, {
            endpoint: 'oc_time/getCutoffs',
            uriParams: { periodId: periodId, _t: Date.now() },
          });
          $page.variables.cutoffs =
            (cut.ok && cut.body && cut.body.items && cut.body.items[0]) || null;
        } catch (e) {
          $page.variables.cutoffs = null;
        }

        // ── Retro adjustments awaiting this manager (ACT-021) ──
        try {
          const adj = await Actions.callRest(context, {
            endpoint: 'oc_time/getMgrAdjustments',
            uriParams: { managerId: managerId, _t: Date.now() },
          });

          $page.variables.adjustments =
            ((adj.ok && adj.body && adj.body.items) || []).map((a) => ({
              adjustmentId: a.adjustment_id,
              employeeId: a.employee_id,
              employeeName: a.employee_name,
              workDate: a.work_date,
              adjKind: a.adj_kind,
              oldProjectName: a.old_project_name,
              oldTaskCode: a.old_task_code,
              oldHours: a.old_hours,
              newProjectName: a.new_project_name,
              newTaskCode: a.new_task_code,
              newHours: a.new_hours,
              netHours: a.net_hours,
              status: a.status,
              reason: a.reason || '',
              isOldProjectManager: a.is_old_project_manager,
              isNewProjectManager: a.is_new_project_manager,
              oldMgrApprovedBy: a.old_mgr_approved_by,
              newMgrApprovedBy: a.new_mgr_approved_by,
            }));
        } catch (e) {
          $page.variables.adjustments = [];
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Service unavailable',
          message: 'The timesheet service is unavailable. Please try again shortly.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadProjectsChain;
});
