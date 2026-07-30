/* PAGE-004 View Timesheet — drill into an employee (PAGE-005) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class openEmployeeChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{employeeId:string, employeeName:string}} params
     */
    async run(context, { employeeId, employeeName }) {
      const { $application } = context;

      if (!employeeId) { return; }

      $application.variables.selectedEmployeeId   = employeeId;
      $application.variables.selectedEmployeeName = employeeName || '';
      // The approval detail page picks its own week; clear any previous one.
      $application.variables.selectedWeekId       = null;

      await Actions.callChain(context, {
        chain: 'shell/navigateChain',
        params: { target: 'approval-detail' },
      });
    }
  }

  return openEmployeeChain;
});
