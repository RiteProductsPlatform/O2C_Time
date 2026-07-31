/* PAGE-005 Approval Detail — back to the weekly view */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Returning to the week list clears the date selection: dates belong to the
   * week that was open, and leaving them ticked would let a later "Approve
   * dates" act on a week the manager is no longer looking at.
   */
  class showWeeklyChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.view = 'weekly';
      $page.variables.selectedDates = [];
    }
  }

  return showWeeklyChain;
});
