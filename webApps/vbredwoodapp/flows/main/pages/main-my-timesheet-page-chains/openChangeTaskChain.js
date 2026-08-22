/* H8 — open the change-task dialog for one line.
 *
 * A dialog rather than an inline dropdown in the grid, decided 12-Aug-2026.
 * oj-select-single needs a DataProvider and the options differ per row (each
 * row's own project), and a per-row ADP cannot be built inside an
 * oj-bind-for-each. Dropping to a plain <select> would hit the same parser
 * trap as the day/shift strip -- a custom element inside <select> is stripped
 * exactly as one inside <tbody> is.
 *
 * So this reuses the Add-a-line pattern: same getTaskLov, same shape of
 * options, same number of clicks for the employee.
 */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class openChangeTaskChain extends ActionChain {

    // The whole row, not four separate bindings — matching removeLineChain,
    // which is the proven shape for a per-row action on this grid.
    async run(context, { row }) {
      const { $page, $application } = context;

      const projectId   = row && row.projectId;
      const projectName = row && row.projectName;
      const taskId      = row && row.taskId;
      const taskName    = row && row.taskName;

      // The button is only rendered on an editable, non-leave line, but the
      // guard is repeated here because a chain can be reached by other means
      // and the database refusal is not a nice place to discover that.
      if (!$page.variables.editable || !projectId || !taskId) { return; }
      if (row.isLeave === 'Y') { return; }

      // APPLICATION scope. This read the PAGE variable of the same name first,
      // which is not declared on this page and so was always undefined -- the
      // || carried it, but the line read as though a page-level override
      // existed. There is one week id and it lives at app scope.
      $page.variables.chgWeekId = $application.variables.selectedWeekId;
      $page.variables.chgProjectId    = projectId;
      $page.variables.chgProjectName  = projectName || '';
      $page.variables.chgOldTaskId    = taskId;
      $page.variables.chgOldTaskName  = taskName || '';
      $page.variables.chgNewTaskId    = null;
      $page.variables.chgTaskOptionsArray = [];

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getTaskLov',
          uriParams: { projectId: projectId, _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Tasks unavailable',
            message: 'Could not load tasks for this project: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        // The task already on this line is dropped from the list. Choosing it
        // would be a no-op, and offering it invites the employee to "change"
        // to what they already have and wonder why nothing happened.
        $page.variables.chgTaskOptionsArray =
          (($application.functions.apiBody(resp).items) || [])
            .filter((t) => t.task_id !== taskId)
            .map((t) => ({
              value: t.task_id,
              label: t.task_group === 'WBS'
                       ? t.task_name
                       : t.task_name + '  (non-billable)',
              taskGroup: t.task_group,
              billableType: t.billable_type,
            }));

        if (!$page.variables.chgTaskOptionsArray.length) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Nothing to change to',
            message: 'This project offers no other task you can move these '
                     + 'hours to.',
            severity: 'info',
            type: 'info',
            displayMode: 'transient',
          });
          return;
        }

        await Actions.callComponentMethod(context, {
          selector: '#changeTaskDlg',
          method: 'open',
        });

      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Tasks unavailable'),
          message: $application.functions.chainError(e, 'Could not load the task list.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return openChangeTaskChain;
});
