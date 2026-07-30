/* PAGE-005 Approval Detail — open one week day by day */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class openWeekChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{tsWeekId:number, label:string}} params
     */
    async run(context, { tsWeekId, label }) {
      const { $page, $application } = context;

      if (!tsWeekId) { return; }

      const week = ($page.variables.weeks || [])
        .find((w) => w.tsWeekId === tsWeekId);

      $page.variables.weekId        = tsWeekId;
      $page.variables.weekLabel     = label || '';
      $page.variables.weekStatus    = week ? week.weekStatus : '';
      $page.variables.view          = 'daily';
      $page.variables.selectedDates = [];
      // Overrides are counted per sitting, so a newly opened week starts at zero.
      $page.variables.overrideCount = 0;

      $application.variables.selectedWeekId = tsWeekId;

      await Actions.callChain(context, { chain: 'loadDaysChain' });
    }
  }

  return openWeekChain;
});
