/* PAGE-001 My Timesheet — task LOV for the chosen project (RULE-010) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the task LOV for the selected project: that project's WBS tasks plus
   * the four common non-billable tasks, which appear in EVERY project and in the
   * Organization project.
   *
   * Leave and Billing Loss are filtered out server-side by SELECTABLE_FLAG
   * (RULE-008 / RULE-009), so this chain does not need to know about them — the
   * one place that decides is the database.
   *
   * Tasks are grouped in the label so the common tasks are visually separate
   * from the project's own WBS.
   */
  class loadTasksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const projectId = $page.variables.newLineProjectId;

      $page.variables.newLineTaskId = null;

      if (!projectId) {
        $page.variables.taskOptionsArray = [];
        return;
      }

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

        const items = (resp.body && resp.body.items) || [];

        $page.variables.taskOptionsArray = items.map((t) => ({
          value: t.task_id,
          label: t.task_group === 'WBS'
                   ? t.task_name
                   : t.task_name + '  (non-billable)',
          taskGroup: t.task_group,
          billableType: t.billable_type,
        }));

        if (!items.length) {
          await Actions.fireNotificationEvent(context, {
            summary: 'No chargeable tasks',
            message: 'This project has no chargeable tasks set up yet.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Tasks unavailable',
          message: 'Could not load tasks for this project — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return loadTasksChain;
});
