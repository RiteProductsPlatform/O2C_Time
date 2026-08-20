/* PAGE-006 Leave Loss Coverage — load absentee lines */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class loadLinesChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $page.variables.projectId;
      const periodId  = $page.variables.periodId;

      if (!projectId || !periodId) {
        $page.variables.lines = [];
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getLlc',
          uriParams: { projectId: projectId, periodId: periodId, _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Absences unavailable',
            message: 'Could not load the absence lines: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = ((resp.body && resp.body.items) || []).map((l) => ({
          llcId: l.llc_id,
          absentEmployeeId: l.absent_employee_id,
          absentEmployeeName: l.absent_employee_name,
          absenceDate: l.absence_date,
          absenceDay: l.absence_day,
          absenceType: l.absence_type || '—',
          // TWO NUMBERS, DELIBERATELY. absenceHours is the whole absence;
          // lossHours is THIS project's share of it, which is what a
          // per-project screen must lead with. Sam is 25% on 555, so a day of
          // his leave costs 555 two hours -- the screen showed 8 until
          // 20-Aug-2026 and overstated the loss fourfold.
          absenceHours: l.absence_hours || 0,
          lossHours: l.loss_hours || 0,
          // 'N' means the absence was withdrawn after this line was approved.
          absenceExists: l.absence_exists !== 'N',
          coverEmployeeId: l.cover_employee_id || '',
          coverEmployeeName: l.cover_employee_name || '',
          llcStatus: l.llc_status,
          billedFlag: l.billed_flag,
          assignedBy: l.assigned_by || '',
          assignedOn: l.assigned_on || '',
          approvedBy: l.approved_by || '',
          approvedOn: l.approved_on || '',
          remarks: l.remarks || '',
        }));

        $page.variables.lines = rows;

        $page.variables.openCount     = rows.filter((r) => r.llcStatus === 'Open').length;
        $page.variables.assignedCount = rows.filter((r) => r.llcStatus === 'Assigned').length;
        $page.variables.approvedCount = rows.filter((r) => r.llcStatus === 'Approved').length;

        // CAPACITY COVERED, and it is not a billing figure.
        //
        // This summed absenceHours over the billed rows, then briefly summed
        // the hours db/84 moved onto a billable task. Both were wrong in the
        // same direction: coverage moves no hours at all. The covering
        // colleague's time stays unbilled and the absentee's leave stays in the
        // leave column, so nothing here changes what anybody is billed.
        //
        // The total is still worth showing -- it is how much of the month's
        // lost capacity has been covered, which is the manager's own measure of
        // whether they are on top of it -- so it sums LOSS_HOURS over approved
        // rows and the label says capacity, not billing.
        $page.variables.billedHours = rows
          .filter((r) => r.llcStatus === 'Approved')
          .reduce((sum, r) => sum + (Number(r.lossHours) || 0), 0);

        // "there should always be a eligible person to cover in FCP and this is
        // mandatory" (20-Aug), so an uncovered absence is an exception rather
        // than a resting state and the count is surfaced beside the total.
        $page.variables.unbilledApproved = rows.filter(
          (r) => !r.coverEmployeeId).length;

        // Approved coverage whose absence has since been withdrawn. It keeps
        // its row deliberately -- a manager decided it -- and it is already off
        // the annexure, but somebody has to revoke it, so it cannot be quiet.
        $page.variables.orphanCount = rows.filter(
          (r) => !r.absenceExists).length;

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

  return loadLinesChain;
});
