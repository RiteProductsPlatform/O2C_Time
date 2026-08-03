/* PAGE-003 Team Approvals — manager identity switch (ACT-011) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * A split employee reports into more than one manager, so a manager may need
   * to act as a different manager to review that team (ACT-011 / FLD-026).
   *
   * actingManagerId is what every approval call sends as actorEmpId, so the
   * switch changes both what the manager sees AND who the approval is recorded
   * against. RULE-015 still applies on the server: whoever is acting cannot
   * approve their own timesheet.
   */
  class switchManagerChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{managerId:string}} params
     */
    async run(context, { managerId }) {
      const { $application } = context;

      if (!managerId || managerId === $application.variables.actingManagerId) {
        return;
      }

      $application.variables.actingManagerId = managerId;

      // Clear the drill-down context: the previous project/employee selection
      // belongs to the previous manager's team and must not leak across.
      $application.variables.selectedProjectId    = null;
      $application.variables.selectedProjectName  = '';
      $application.variables.selectedEmployeeId   = '';
      $application.variables.selectedEmployeeName = '';
      $application.variables.selectedWeekId       = null;

      await Actions.fireNotificationEvent(context, {
        summary: 'Manager switched',
        message: 'Now reviewing the team of the selected manager.',
        severity: 'confirmation',
        type: 'confirmation',
        displayMode: 'transient',
      });

      // Reload this page's projects for the new team. It used to navigate to
      // main-team-approvals, which is where the switcher used to live (the
      // shell banner); it now sits on this page, so navigating would be a
      // no-op that discards the filter.
      await Actions.callChain(context, { chain: 'loadProjectsChain' });
    }
  }

  return switchManagerChain;
});
