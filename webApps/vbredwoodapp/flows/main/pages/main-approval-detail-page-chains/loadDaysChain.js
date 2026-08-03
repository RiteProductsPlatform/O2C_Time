/* PAGE-005 Approval Detail — load the daily lines + audit trail */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the line-wise daily grid for the open week and its change history.
   *
   * The audit trail is fetched here rather than lazily, because it is the
   * evidence the manager needs while deciding — seeing that a week was already
   * overridden once changes how you read it.
   */
  class loadDaysChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const weekId = $page.variables.weekId;

      if (!weekId) { return; }

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getDayDetail',
          uriParams: { tsWeekId: weekId, _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Daily detail unavailable',
            message: 'Could not load the daily detail: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = ((resp.body && resp.body.items) || []).map((d) => ({
          tsEntryId: d.ts_entry_id,
          entryDate: d.entry_date,
          dayName: d.day_name,
          projectId: d.project_id,
          projectName: d.project_name,
          taskId: d.task_id,
          taskCode: d.task_code,
          taskName: d.task_name,
          hours: d.hours,
          entryType: d.entry_type,
          billableType: d.billable_type,
          unbilledReason: d.unbilled_reason || '—',
          shiftCode: d.shift_code || '—',
          standardHours: d.standard_hours || 0,
          isLeave: d.is_leave,
          absenceType: d.absence_type,
          dayStatus: d.day_status,
          rejectReason: d.reject_reason || '',
          rejectRemarks: d.reject_remarks || '',
          source: d.source,
        }));

        $page.variables.days = rows;

        // Drop any previously selected dates that are no longer in the week.
        const dates = rows.map((r) => r.entryDate);
        $page.variables.selectedDates =
          ($page.variables.selectedDates || []).filter((d) => dates.indexOf(d) >= 0);

        // ── Change history (REP-007 / NFR-010) ─────────────────
        try {
          const aud = await Actions.callRest(context, {
            endpoint: 'oc_time/getWeekAudit',
            uriParams: { tsWeekId: weekId, _t: Date.now() },
          });

          $page.variables.auditRows =
            ((aud.ok && aud.body && aud.body.items) || []).map((a) => ({
              auditId: a.audit_id,
              entryDate: a.entry_date,
              changeType: a.change_type,
              oldProjectName: a.old_project_name,
              oldTaskCode: a.old_task_code,
              oldHours: a.old_hours,
              newProjectName: a.new_project_name,
              newTaskCode: a.new_task_code,
              newHours: a.new_hours,
              deltaHours: a.delta_hours,
              changeReason: a.change_reason || '',
              changedBy: a.changed_by,
              changedOn: a.changed_on,
            }));
        } catch (e) {
          $page.variables.auditRows = [];
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
      }
    }
  }

  return loadDaysChain;
});
