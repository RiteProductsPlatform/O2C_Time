/* PAGE-005 Approval Detail — load the weeks for this employee + project */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the weekly rows and, when a week is already open, refreshes the daily
   * grid and the audit trail so the whole page is consistent after any action.
   */
  class loadWeeksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId  = $application.variables.selectedProjectId;
      const periodId   = $application.variables.selectedPeriodId;
      const employeeId = $application.variables.selectedEmployeeId;

      if (!projectId || !periodId || !employeeId) { return; }

      $page.variables.busy = true;
      $page.variables.selectedWeekKeys = [];

      // FLD-003. The weekly cut-off is what governs a week, so it is fetched
      // here and shown beside the list. Informational — a failure must not stop
      // the weeks loading, which is the point of the page.
      try {
        const cut = await Actions.callRest(context, {
          endpoint: 'oc_time/getCutoffs',
          uriParams: { periodId: periodId, _t: Date.now() },
        });
        if (cut.ok && cut.body && cut.body.items && cut.body.items.length) {
          $page.variables.weeklyCutoff = cut.body.items[0].weekly_cutoff_display || '';
        }
      } catch (e) {
        $page.variables.weeklyCutoff = '';
      }

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMgrWeeks',
          uriParams: {
            projectId: projectId,
            periodId: periodId,
            employeeId: employeeId,
            _t: Date.now(),
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Weeks unavailable',
            message: 'Could not load the weeks: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = ((resp.body && resp.body.items) || []).map((w) => ({
          tsWeekId: w.ts_week_id,
          weekIndex: w.week_index,
          weekRange: w.week_range,
          weekStart: w.week_start,
          weekEnd: w.week_end,
          weekStatus: w.week_status,
          // The V4 axes. weekStatus collapses them, and pendingWeeks() needs
          // them apart to tell "waiting on the manager" from "never submitted".
          submissionStatus: w.submission_status,
          approvalStatus: w.approval_status,
          billableHours: w.billable_hours || 0,
          nonBillableHours: w.non_billable_hours || 0,
          leaveHours: w.leave_hours || 0,
          billingLossHours: w.billing_loss_hours || 0,
          totalHours: w.total_hours || 0,
          standardHours: w.standard_hours || 0,
          daysTotal: w.days_total || 0,
          daysPending: w.days_pending || 0,
          daysApproved: w.days_approved || 0,
          daysRejected: w.days_rejected || 0,
          // The six flag columns keep their raw ORDS names so
          // $application.functions.weekFlags can read the row directly and this
          // page cannot drift from the employee's own page.
          defaulted_flag: w.defaulted_flag,
          late_submission_flag: w.late_submission_flag,
          advance_closure_flag: w.advance_closure_flag,
          overridden_flag: w.overridden_flag,
          has_reversal_flag: w.has_reversal_flag,
          has_adjustment_flag: w.has_adjustment_flag,
          defaulted_by: w.defaulted_by,
          lockedFlag: w.locked_flag,
          submittedOn: w.submitted_on || '—',
          approvedBy: w.approved_by || '',
          approvedOn: w.approved_on || '',
          rejectReason: w.reject_reason || '',
          rejectRemarks: w.reject_remarks || '',
          projects: w.projects || '',
          // THE HOURS ABOVE ARE NOW THIS PROJECT'S ONLY, but approve_week fires
          // the event against the WEEK and cascades to every day in it -- so
          // approving from 444 also approves this employee's 555 and PCS10034
          // days. Scoping the figures without saying so would hide that rather
          // than fix it, which is why the count is carried and shown.
          otherProjects: w.other_projects || '',
          otherProjectCount: w.other_project_count || 0,
        }));

        $page.variables.weeks = rows;
        // Kept beside the rows rather than computed in the binding (S1), and
        // recomputed on every load so ACT-019's button cannot offer to approve
        // weeks that were settled since the page opened.
        $page.variables.pendingWeekCount =
          $page.functions.pendingWeeks(rows).length;

        // If a week was open, keep it open and refresh its detail. If it has
        // vanished (period changed underneath us) fall back to the week list.
        const open = $page.variables.weekId;
        if (open && rows.some((r) => r.tsWeekId === open)) {
          const w = rows.find((r) => r.tsWeekId === open);
          $page.variables.weekStatus = w.weekStatus;
          await Actions.callChain(context, { chain: 'loadDaysChain' });
        } else if (open) {
          $page.variables.weekId    = null;
          $page.variables.weekLabel = '';
          $page.variables.view      = 'weekly';
        }

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

  return loadWeeksChain;
});
