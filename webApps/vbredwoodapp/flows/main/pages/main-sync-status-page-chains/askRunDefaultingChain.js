/* PAGE-010 Sync Status — confirm running the defaulting job */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Defaulting is consequential in a way the other two jobs are not: it
   * auto-submits unsubmitted weeks with default hours, LOCKS them to the
   * employee, and places a hold on their salary (RULE-006 / RULE-016).
   * Running it before the cut-off would hold pay for people who still had
   * time to file.
   */
  class askRunDefaultingChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      if (!$page.variables.runJobPeriodId) { return; }

      $page.variables.confirmMessage = 'Weeks not submitted by the weekly cut-off will be auto-submitted with '  +
        'default hours, locked to the employee, and will place a hold on their ' +
        'salary. Only run this after the cut-off has passed.';

      await Actions.callComponentMethod(context, {
        selector: '#runDefaultingDlg',
        method: 'open',
      });
    }
  }

  return askRunDefaultingChain;
});
