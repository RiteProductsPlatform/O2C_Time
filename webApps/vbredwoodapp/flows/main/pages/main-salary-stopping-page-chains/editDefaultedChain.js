/* PAGE-007 Salary Stopping — ACT-025 edit a defaulted timesheet */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Sends the manager to the employee's timesheet to correct the defaulted week.
   *
   * A defaulted week is LOCKED to the employee (RULE-006) — only a manager can
   * edit it, and the ORDS layer honours that by skipping the editability gate for
   * manager-sourced writes. Navigating to the approval detail rather than the
   * employee page keeps the manager in a screen that is already built for
   * someone else's time.
   *
   * The project is not known from this page, so when there is no current project
   * context to reuse the manager lands on the team landing page with the employee
   * remembered.
   */
  class editDefaultedChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{employeeId:string, employeeName:string}} params
     */
    async run(context, { employeeId, employeeName }) {
      const { $application } = context;

      if (!employeeId) { return; }

      $application.variables.selectedEmployeeId   = employeeId;
      $application.variables.selectedEmployeeName = employeeName || '';
      $application.variables.selectedWeekId       = null;

      if (!$application.variables.selectedProjectId) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Choose a project first',
          message: 'Choose the project this employee charges to, then open them to correct the week.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        await Actions.callChain(context, {
          chain: 'shell/navigateToPageChain',
          params: { page: 'main-team-approvals' },
        });
        return;
      }

      await Actions.callChain(context, {
        chain: 'shell/navigateToPageChain',
        params: { page: 'main-approval-detail' },
      });
    }
  }

  return editDefaultedChain;
});
