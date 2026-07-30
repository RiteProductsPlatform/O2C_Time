/* PAGE-004 View Timesheet — confirm the month-to-accrual hand-off (ACT-020) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Confirming hands the consolidated timesheet to the accrual application
   * for every employee at once and cannot be undone from this screen, so the
   * RULE-020 gate is re-checked here before the dialog is even offered.
   */
  class askConfirmMonthChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      if ($page.variables.alreadyConfirmed) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Already confirmed',
          message: 'This month has already been confirmed.',
          severity: 'warning', type: 'warning', displayMode: 'transient',
        });
        return;
      }

      if (!$page.variables.confirmAllowed) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Not ready to confirm',
          message: 'Approve every employee’s month before confirming to accrual.',
          severity: 'warning', type: 'warning', displayMode: 'transient',
        });
        return;
      }

      $page.variables.confirmMessage = 'Confirm ' + $application.variables.selectedProjectName + ' for ' +
        $application.variables.selectedPeriodName + '? This confirms the month for all ' +
        $page.variables.totalEmployees + ' employees at once and hands the ' +
        'consolidated timesheet to the accrual application. It cannot be undone ' +
        'from this screen.';

      await Actions.callComponentMethod(context, {
        selector: '#confirmMonthDlg',
        method: 'open',
      });
    }
  }

  return askConfirmMonthChain;
});
