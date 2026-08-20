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
          // null until the coverage is approved AND the hours actually moved.
          // Kept null rather than defaulted to 0: "nothing has been billed" and
          // "zero was billable" are different answers and the row renders them
          // differently.
          coverHoursBilled: (l.cover_hours_billed === null
                          || l.cover_hours_billed === undefined)
            ? null : Number(l.cover_hours_billed),
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

        // WHAT ACTUALLY MOVED, not what was absent.
        //
        // This summed absenceHours over the billed rows, so a single approved
        // cover on a 25% allocation reported 8.00 hours recovered when 2.00
        // had been converted to billable. It also counted rows approved before
        // db/84 was wired, where BILLED_FLAG was set and no hours moved at all
        // -- the tile asserted a recovery that had not happened.
        //
        // COVER_HOURS_BILLED is written by oc_time_cover_billing at the moment
        // it moves the hours, so summing it cannot claim more than was done.
        $page.variables.billedHours = rows
          .reduce((sum, r) => sum + (Number(r.coverHoursBilled) || 0), 0);

        // Approved, flagged billed, and yet nothing moved. Worth surfacing
        // rather than showing a quietly low total: it means the cover had no
        // non-billable hours that day, or the week had already locked.
        $page.variables.unbilledApproved = rows.filter(
          (r) => r.llcStatus === 'Approved' && r.coverHoursBilled === null).length;

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
