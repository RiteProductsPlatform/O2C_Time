/* PAGE-006 Leave Loss Coverage — confirm approving all assigned coverage */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approving coverage turns absence hours into BILLED hours on the invoice
   * annexure, so it is confirmed first — this is a revenue-affecting action
   * across the whole project month, not a status tidy-up.
   */
  class askApproveAllChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const pending = ($page.variables.lines || [])
        .filter((l) => l.llcStatus === 'Assigned');
      if (!pending.length) { return; }

      const hours = pending.reduce((s, l) => s + (Number(l.absenceHours) || 0), 0);

      $page.variables.confirmMessage = 'Approve ' + pending.length + ' coverage line(s)? ' +
        $application.functions.fmtHours(hours) +
        ' absence hours will become billed and will appear on the invoice annexure.';

      await Actions.callComponentMethod(context, {
        selector: '#approveAllDlg',
        method: 'open',
      });
    }
  }

  return askApproveAllChain;
});
