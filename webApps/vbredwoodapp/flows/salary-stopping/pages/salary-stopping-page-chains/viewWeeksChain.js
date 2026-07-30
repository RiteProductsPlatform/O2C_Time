/* PAGE-007 Salary Stopping — weeks breakdown pop-up (#3) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Shows the per-week split for one employee: which weeks were submitted, which
   * defaulted, and the applied versus default hours for each.
   *
   * This is what distinguishes "missed one week" from "filed nothing all month",
   * and the two deserve very different manager responses.
   */
  class viewWeeksChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{employeeId:string, label:string}} params
     */
    async run(context, { employeeId, label }) {
      const { $page, $application } = context;

      if (!employeeId) { return; }

      $page.variables.weeksLabel = label || '';
      $page.variables.weekRows   = [];
      $page.variables.showWeeks  = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getSalaryHoldWeeks',
          uriParams: {
            periodId: $page.variables.periodId,
            employeeId: employeeId,
            _t: Date.now(),
          },
        });

        if (resp.ok && resp.body && resp.body.items) {
          $page.variables.weekRows = resp.body.items.map((w) => ({
            tsWeekId: w.ts_week_id,
            weekIndex: w.week_index,
            weekRange: w.week_range,
            weekStatus: w.week_status,
            defaultedFlag: w.defaulted_flag,
            lockedFlag: w.locked_flag,
            totalHours: w.total_hours || 0,
            appliedHours: w.applied_hours || 0,
            defaultHours: w.default_hours || 0,
          }));
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Weeks unavailable',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Weeks unavailable',
          message: 'Could not load the weeks — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return viewWeeksChain;
});
