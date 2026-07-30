/* PAGE-005 Approval Detail — open the reject dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * One dialog serves both granularities; the scope decides what the confirm
   * button acts on. Reason and remarks are cleared each time because they are
   * shown verbatim to the employee, so stale text would misdirect them.
   */
  class openRejectChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{scope:string}} params  'week' | 'dates'
     */
    async run(context, { scope }) {
      const { $page } = context;

      const nothing = scope === 'dates'
        ? !($page.variables.selectedDates || []).length
        : !($page.variables.selectedWeekKeys || []).length;

      if (nothing) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing selected',
          message: scope === 'dates'
            ? 'Select at least one date.'
            : 'Select at least one week.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.rejectScope   = scope;
      $page.variables.rejectReason  = '';
      $page.variables.rejectRemarks = '';
      $page.variables.showReject    = true;
    }
  }

  return openRejectChain;
});
