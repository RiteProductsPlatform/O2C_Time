/* PAGE-004 View Timesheet — page entry */

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
   * Requires a project selection. Arriving without one means the user deep-linked
   * or the session was cleared, so send them back to the landing page rather than
   * showing an empty summary they cannot explain.
   *
   * READS HR BEFORE IT READS THE SUMMARY, added 21-Aug-2026. Every figure on
   * this page comes from OC_TS_ENTRY, and leave only reaches OC_TS_ENTRY once
   * something has synced the absence. Until now the only things that did were
   * the nightly feed and THE ABSENT PERSON opening their own timesheet -- so a
   * manager could approve a month against leave that HR had changed days
   * earlier, with nothing on the screen to say it was stale. Reported when a
   * withdrawn absence stayed on every manager screen while the employee's own
   * timesheet showed it correctly.
   *
   * NON-FATAL, and deliberately quiet about it. If Fusion cannot be reached the
   * summary still opens on the last known figures with a warning, because
   * refusing to show a month because a pod is down is the worse failure -- the
   * same call PAGE-001 makes.
   */
  class enterChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.activeNav = 'main-view-timesheet';

      if (!$application.variables.selectedProjectId) {
        $application.variables.activeNav = 'main-team-approvals';
        await Actions.navigateToPage(context, {
          page: 'main-team-approvals', history: 'push',
        });
        return;
      }

      const periodId = $application.variables.selectedPeriodId
                    || $application.variables.openPeriodId;

      try {
        const out = await Absence.pullForRoster(context, Actions, {
          projectId: $application.variables.selectedProjectId,
          periodId: periodId,
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
        // JET aborts in-flight requests on re-render; that is not a failure.
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

      await Actions.callChain(context, { chain: 'loadSummaryChain' });
    }
  }

  return enterChain;
});
