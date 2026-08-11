/* PAGE-010 — confirm closing a period.
 *
 * Closing asks and opening does not, because the two are not symmetrical.
 * Closing gates editing across the whole month, and a project that turns out
 * to be unconfirmed afterwards cannot be fixed by approving it — the weeks are
 * locked by then. 92_month_end_close.sql carries the same warning at its last
 * step for the same reason.
 *
 * The button is already disabled while anything is unconfirmed. This dialog is
 * for the case where nothing is, and closing is still the irreversible act.
 */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class askClosePeriodChain extends ActionChain {

    async run(context, { periodId, periodName }) {
      const { $page } = context;

      if (!periodId) { return; }

      $page.variables.closePeriodId = periodId;
      $page.variables.confirmMessage =
        'Closing ' + periodName + ' makes every week in it read-only. The month ' +
        'stays visible and its hours stay on screen, but nobody can edit, submit ' +
        'or approve in it again, and a project found unconfirmed afterwards ' +
        'cannot be fixed by approving it.';

      await Actions.callComponentMethod(context, {
        selector: '#closePeriodDlg',
        method: 'open',
      });
    }
  }

  return askClosePeriodChain;
});
