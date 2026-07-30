/* PAGE-001 My Timesheet — ACT-003 open the Add line dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Clears the previous selection before opening, so the dialog never appears
   * pre-filled with the line the user added last time.
   */
  class openAddLineChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.newLineProjectId = null;
      $page.variables.newLineTaskId    = null;
      $page.variables.taskOptionsArray = [];
      $page.variables.showAddLine      = true;
    }
  }

  return openAddLineChain;
});
