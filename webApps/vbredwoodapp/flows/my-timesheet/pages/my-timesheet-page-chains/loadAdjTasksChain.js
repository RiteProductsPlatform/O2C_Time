/* PAGE-001 My Timesheet — task LOV for the adjustment's NEW project */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Kept separate from loadTasksChain because the adjustment dialog has two
   * independent task selectors — old and new. Sharing one variable would make
   * choosing the new project wipe the old task the user had already picked.
   */
  class loadAdjTasksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const projectId = $page.variables.adjNewProjectId;

      $page.variables.adjNewTaskId = null;

      if (!projectId) {
        $page.variables.adjTaskOptionsArray = [];
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
            message: 'Could not load tasks for the new project: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        $page.variables.adjTaskOptionsArray =
          ((resp.body && resp.body.items) || []).map((t) => ({
            value: t.task_id,
            label: t.task_name,
            taskGroup: t.task_group,
            billableType: t.billable_type,
          }));

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Tasks unavailable',
          message: 'Could not load tasks for the new project — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return loadAdjTasksChain;
});
