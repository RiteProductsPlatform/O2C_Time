/* PAGE-005 Approval Detail — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/absence',
], (
  ActionChain,
  Actions,
  Absence
) => {
  'use strict';

  /**
   * Needs a project AND an employee. Missing either means the page was reached
   * directly, so hand the user back to the level that can make the choice.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.activeNav = 'main-approval-detail';

      if (!$application.variables.selectedProjectId) {
        $application.variables.activeNav = 'main-team-approvals';
        await Actions.navigateToPage(context, {
          page: 'main-team-approvals', history: 'push',
        });
        return;
      }

      if (!$application.variables.selectedEmployeeId) {
        $application.variables.activeNav = 'main-view-timesheet';
        await Actions.navigateToPage(context, {
          page: 'main-view-timesheet', history: 'push',
        });
        return;
      }

      // READS HR BEFORE THE WEEKS. Every hour on this page comes from
      // OC_TS_ENTRY, and leave only lands there once something has synced the
      // absence. Reached the normal way -- through the Monthly Summary -- that
      // has already happened and pullForRoster returns immediately on its
      // app-scoped marker. Reached by a deep link or a browser refresh, which
      // is how this page is usually revisited, nothing had asked at all and the
      // manager could act on leave HR changed days earlier.
      //
      // Non-fatal: the week still opens on the last known figures with a
      // warning, because refusing to show a timesheet because a pod is down is
      // the worse failure.
      try {
        const out = await Absence.pullForRoster(context, Actions, {
          projectId: $application.variables.selectedProjectId,
          periodId: $application.variables.selectedPeriodId
                 || $application.variables.openPeriodId,
        });

        if (out.note) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Leave may be out of date',
            message: out.note + ' The hours below are the last known figures.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        if (!$application.functions.isAbortError(e)) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Leave may be out of date',
            message: $application.functions.chainError(
              e, 'HR could not be reached, so leave was not refreshed.')
              + ' The hours below are the last known figures.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        }
      }

      await Actions.callChain(context, { chain: 'loadWeeksChain' });
    }
  }

  return enterChain;
});
