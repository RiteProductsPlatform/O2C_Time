/* PAGE-001 My Timesheet — open the retro adjustment dialog (ACT-009) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Prepares the day-wise Reversal(-)/Adjustment(+) dialog.
   *
   * The old project/task is pre-selected from the first line on the grid, since
   * the overwhelmingly common case is "these hours went to the wrong project" on
   * a line already visible. Everything remains changeable.
   */
  class openAdjustmentChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      const rows = $page.variables.gridRows || [];
      const first = rows.find((r) => r.isLeave !== 'Y');

      $page.variables.adjOldProjectId = first ? first.projectId : null;
      $page.variables.adjOldTaskId    = first ? first.taskId    : null;
      $page.variables.adjOldHours     = 0;
      $page.variables.adjNewProjectId = null;
      $page.variables.adjNewTaskId    = null;
      $page.variables.adjNewHours     = 0;
      $page.variables.adjReason       = '';
      $page.variables.adjTaskOptionsArray = [];

      // Default the date to the first day of the week on screen — it is in the
      // closed month being corrected, so it is a sensible starting point.
      const headers = $page.variables.dayHeaders || [];
      $page.variables.adjWorkDate = headers.length ? headers[0].entryDate : '';

      // Load the task LOV for the pre-selected old project so the Old task
      // selector is usable straight away.
      if (first) {
        try {
          const resp = await Actions.callRest(context, {
            endpoint: 'oc_time/getTaskLov',
            uriParams: { projectId: first.projectId, _t: Date.now() },
          });

          if (resp.ok && resp.body && resp.body.items) {
            $page.variables.taskOptionsArray = resp.body.items.map((t) => ({
              value: t.task_id,
              label: t.task_name,
              taskGroup: t.task_group,
              billableType: t.billable_type,
            }));
          }
        } catch (e) {
          // The selector will simply be empty; the user can still pick a
          // different old project, which reloads it.
        }
      }

      $page.variables.showAdjustment = true;
    }
  }

  return openAdjustmentChain;
});
