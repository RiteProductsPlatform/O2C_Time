/* H8 — move a line to the chosen task.
 *
 * The endpoint REFUSES rather than merges when the target task already has a
 * line (decision, 12-Aug-2026). That refusal is not an error to be smoothed
 * over: it names the task and says what to do instead, so it is shown to the
 * employee verbatim rather than replaced with something generic.
 */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class changeTaskChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const weekId = $page.variables.chgWeekId;
      const projId = $page.variables.chgProjectId;
      const oldId  = $page.variables.chgOldTaskId;
      const newId  = $page.variables.chgNewTaskId;

      if (!newId || newId === oldId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/changeLineTask',
          body: {
            tsWeekId:  weekId,
            projectId: projId,
            oldTaskId: oldId,
            newTaskId: newId,
            actor:     $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          await Actions.callComponentMethod(context, {
            selector: '#changeTaskDlg',
            method: 'close',
          });

          await Actions.fireNotificationEvent(context, {
            summary: 'Task changed',
            message: 'The hours moved with the line. If the new task is '
                     + 'non-billable, they are now non-billable too.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          // The grid is rebuilt rather than patched: TRG_OC_TSE_DERIVE
          // re-derives BILLABLE_TYPE from the new task, so the row's billable
          // state may have changed in ways the page did not ask for.
          await Actions.callChain(context, { chain: 'loadGridChain' });

        } else {
          // Shown verbatim. The database wrote this sentence to be read by the
          // person who pressed the button -- "Offshore is already on this
          // timesheet. Enter the hours on that line, or remove it first."
          await Actions.fireNotificationEvent(context, {
            summary: 'Task not changed',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Task not changed'),
          message: $application.functions.chainError(e, 'The timesheet service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return changeTaskChain;
});
