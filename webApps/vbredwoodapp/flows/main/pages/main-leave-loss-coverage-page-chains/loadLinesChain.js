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
          absenceHours: l.absence_hours || 0,
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

        // Only APPROVED coverage is billed, so the headline figure counts those
        // rows alone — an assigned-but-unapproved cover is not billable yet.
        $page.variables.billedHours = rows
          .filter((r) => r.billedFlag === 'Y')
          .reduce((sum, r) => sum + (Number(r.absenceHours) || 0), 0);

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
