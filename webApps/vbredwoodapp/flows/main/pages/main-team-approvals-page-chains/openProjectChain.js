/* PAGE-003 Team Approvals — drill into a project (PAGE-004) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Stores the project selection at application scope and navigates to the
   * monthly summary.
   *
   * The selection is shared rather than passed as page input because the manager
   * drills two levels deep (summary -> approval detail) and then comes back;
   * holding it in the session means Back does not lose the context.
   */
  class openProjectChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{projectId:number, projectName:string}} params
     */
    async run(context, { projectId, projectName }) {
      const { $application } = context;

      if (!projectId) { return; }

      $application.variables.selectedProjectId   = projectId;
      $application.variables.selectedProjectName = projectName || '';

      // Clear the deeper level so PAGE-005 cannot open against the previous
      // project's employee.
      $application.variables.selectedEmployeeId   = '';
      $application.variables.selectedEmployeeName = '';
      $application.variables.selectedWeekId       = null;

      $application.variables.activeNav = 'main-view-timesheet';
      await Actions.navigateToPage(context, {
        page: 'main-view-timesheet', history: 'push',
      });
    }
  }

  return openProjectChain;
});
