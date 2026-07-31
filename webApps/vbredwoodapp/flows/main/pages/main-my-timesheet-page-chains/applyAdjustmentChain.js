/* PAGE-001 My Timesheet — ACT-009 apply a day-wise retro adjustment */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Applies a backdated Project/WBS change for ONE day (PROC-008 / #10).
   *
   * Nothing is posted to accrual here. The adjustment is created 'Awaiting
   * Approval'; only when the manager approves does the server materialise the
   * Reversal(-) and Adjustment(+) pair in the OPEN period (the closed book is
   * never reopened) and hand it to accrual.
   *
   * RULE-019 (the 3-month backdating window) is enforced by a database trigger,
   * so a stale page or a direct API call cannot slip past it. The message the
   * trigger raises is what the user sees.
   */
  class applyAdjustmentChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const workDate     = $page.variables.adjWorkDate;
      const oldProjectId = $page.variables.adjOldProjectId;
      const oldTaskId    = $page.variables.adjOldTaskId;
      const oldHours     = Number($page.variables.adjOldHours) || 0;
      const newProjectId = $page.variables.adjNewProjectId;
      const newTaskId    = $page.variables.adjNewTaskId;
      const newHours     = Number($page.variables.adjNewHours) || 0;

      // ── Validate before calling ──────────────────────────────
      if (!workDate || !oldProjectId || !oldTaskId) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Incomplete',
          message: 'Enter the date and the project/task the hours should come off.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      if (oldHours <= 0) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Incomplete',
          message: 'Enter the number of hours to reverse.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      // RULE-005 applies to both sides of the net-off.
      const offGrid = (v) => Math.round(v * 4) / 4 !== v;
      if (offGrid(oldHours) || offGrid(newHours)) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Invalid hours',
          message: 'Hours must be in 15-minute blocks.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      // Moving hours requires somewhere to move them to. Reversal-only (new
      // hours zero) is legitimate — hours were simply logged that should not
      // have been.
      if (newHours > 0 && (!newProjectId || !newTaskId)) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Incomplete',
          message: 'Choose the new project and task for the hours being added.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/applyAdjustment',
          body: {
            employeeId: $application.variables.employeeId,
            workDate: $application.functions.toApiDate(workDate),
            oldProjectId: oldProjectId,
            oldTaskId: oldTaskId,
            oldHours: oldHours,
            newProjectId: newProjectId || null,
            newTaskId: newTaskId || null,
            newHours: newHours,
            reason: $page.variables.adjReason || null,
            adjKind: 'RetroWBS',
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          $page.variables.showAdjustment = false;

          await Actions.fireNotificationEvent(context, {
            summary: 'Change applied',
            message: 'Applied for ' + $application.functions.fmtDate(workDate) +
                     ' and sent to your manager for approval.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadGridChain' });
          return;
        }

        // A 400 is most often the backdating window (RULE-019) or a missing
        // open period; the trigger's own message says which.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Adjustment refused' : 'Apply failed',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Apply failed',
          message: 'The service is unreachable. Please retry.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return applyAdjustmentChain;
});
