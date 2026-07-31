/* PAGE-005 Approval Detail — confirm approving every pending week (ACT-019) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Confirmed rather than immediate, unlike "Approve selected".
   *
   * "Selected" acts on rows the manager ticked and can see. This acts on every
   * pending week for the employee — including weeks scrolled off screen, and
   * including Defaulted ones, which are pending precisely because nobody has
   * looked at them yet. Naming the count and listing the statuses is the point
   * of the dialog: it tells the manager what "all" turned out to mean.
   */
  class askApproveAllWeeksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const pending = $page.functions.pendingWeeks($page.variables.weeks);
      if (!pending.length) {
        return;
      }

      // Defaulted weeks are called out separately. They carry hours nobody
      // entered, so approving them without noticing is the mistake this
      // sentence exists to prevent.
      const defaulted = pending.filter((w) => w.weekStatus === 'Defaulted').length;

      let msg = 'Approve all ' + pending.length + ' pending week'
              + (pending.length === 1 ? '' : 's') + ' for '
              + ($application.variables.selectedEmployeeName || 'this employee')
              + ' on ' + ($application.variables.selectedProjectName || 'this project')
              + '?';

      if (defaulted) {
        msg += ' ' + defaulted + ' of them ' + (defaulted === 1 ? 'is' : 'are')
             + ' Defaulted — those carry system-applied default hours, not hours'
             + ' the employee entered.';
      }

      $page.variables.confirmMessage = msg;

      await Actions.callComponentMethod(context, {
        selector: '#approveAllDlg',
        method: 'open',
      });
    }
  }

  return askApproveAllWeeksChain;
});
