/* PROC-007 — open the held week in My Timesheet so it can be resubmitted */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Take the employee to the week the held date belongs to.
   *
   * THE CORRECTION IS THE TIMESHEET, not a second form on this page. The
   * functional owner described the employee seeing "the defaulted week
   * timesheet after the payroll cutoff is over" and being "able to resubmit
   * it" — so this page lists what is held and hands over to the grid they
   * already know, rather than asking for the same hours twice in two places
   * that could then disagree.
   *
   * The week is normally uneditable by now: defaulting locked it and the
   * delivery cut-off has passed. assert_editable reopens it for exactly this
   * case — a held date, inside the 60 days — so the grid will let them type.
   * Nothing needs unlocking from here.
   */
  class openWeekChain extends ActionChain {

    /**
     * Takes the whole row via {{ $current.data }}, which is how every other
     * for-each in this module hands a row to a chain. An oj-action event
     * carries no custom detail, so reading $event.detail here would arrive
     * undefined and the navigation would silently go nowhere.
     *
     * @param {Object} context
     * @param {{row:Object}} params
     */
    async run(context, { row }) {
      const { $page, $application } = context;
      const tsWeekId = row && row.tsWeekId;

      if (!tsWeekId) {
        await Actions.fireNotificationEvent(context, {
          summary: 'No timesheet week',
          message: 'This date has no timesheet week behind it, so there is '
                 + 'nothing to reopen. Contact payroll — it cannot be '
                 + 'corrected from here.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      // The grid keys off these, and the month picker off the period. Set both
      // before navigating: My Timesheet loads from the application variables on
      // entry, so arriving with only the week id lands on the wrong month.
      $application.variables.selectedWeekId = tsWeekId;

      if (row && row.periodName) {
        const opt = ($application.variables.periodOptionsArray || [])
          .find((p) => p.label === row.periodName);
        if (opt) { $application.variables.selectedPeriodId = opt.value; }
      }

      // A page chain sets activeNav itself and navigates to a SIBLING. It
      // cannot call shell/navigateToPageChain — Actions.callChain resolves the
      // id against this page's own -chains folder, so that request 404s and the
      // navigation silently does nothing.
      $application.variables.activeNav = 'main-my-timesheet';
      await Actions.navigateToPage(context, {
        page: 'main-my-timesheet',
        history: 'push',
      });
    }
  }

  return openWeekChain;
});
