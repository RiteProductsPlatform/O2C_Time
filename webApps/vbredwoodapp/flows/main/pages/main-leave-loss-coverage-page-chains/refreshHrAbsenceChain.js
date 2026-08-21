/* PAGE-006 Leave Loss Coverage — read absence live from Fusion, for everyone
   on the project, then rebuild the absentee list */

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
   * "Refresh absences from HR" used to mean "re-read our own cache".
   *
   * The button called llc/generate, and generate_llc_lines selects from
   * OC_TIME_ABSENCE. So leave applied in Fusion reached this screen only when
   * something else had already fetched it — the nightly feed, or the absent
   * person opening their own timesheet, which triggers PAGE-001's live read for
   * that one person. Measured 20-Aug-2026: RI2894's 20-Aug leave was APPROVED
   * in Fusion, absent from OC_TIME_ABSENCE, and therefore missing from the
   * coverage list their manager works from. The button said it had refreshed
   * and it had, from the wrong place.
   *
   * WHAT IT DOES, in order:
   *
   *   1  Absence.pullForRoster   read HR for the whole team and write it down
   *   2  generateLinesChain      rebuild the coverage lines from what arrived
   *   3  loadLinesChain          show them
   *
   * Step 1 lives in resources/js/absence.js because the Monthly Summary needs
   * exactly the same thing and a VB action chain belongs to one page. It reads
   * the roster, resolves the whole team's PersonIds in ONE Fusion call, reads
   * every absence in ONE more, and posts a windowed claim per person -- see
   * that module for why each of those is the way it is.
   *
   * FAILURE STILL REBUILDS FROM THE CACHE. If Fusion is unreachable the manager
   * is told so plainly and hop 5 still runs, so the button does at least what
   * it used to do. Refusing to do anything because the pod is down would be a
   * worse answer than a stale one that says it is stale.
   */
  class refreshHrAbsenceChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $page.variables.projectId;
      const periodId  = $page.variables.periodId;
      if (!projectId || !periodId) { return; }

      // The once-per-project-month guard now lives inside pullForRoster, at
      // APPLICATION scope, so it also covers the Monthly Summary and Approval
      // Detail. A page-scoped marker carried it while this was the only
      // caller; a page-scoped marker cannot see a pull another page just made.
      $page.variables.busy = true;

      let fusionNote = null;   // set when the live half could not complete

      try {
        // The roster read, the two Fusion calls and the per-person windowed
        // claim all live in resources/js/absence.js, because the Monthly
        // Summary needs exactly the same thing and a chain belongs to one page.
        const out = await Absence.pullForRoster(context, Actions, {
          projectId: projectId, periodId: periodId,
          force: $page.variables.forceNextPull,
        });
        $page.variables.forceNextPull = false;
        fusionNote = out.note;

      } catch (e) {
        if ($application.functions.isAbortError(e)) {
          $page.variables.busy = false;
          return;
        }
        fusionNote = $application.functions.chainError(
          e, 'Fusion could not be reached, so leave was not refreshed.');
      }

      if (fusionNote) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Leave not refreshed from HR',
          message: fusionNote + ' The list below was rebuilt from the last '
                 + 'known leave.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
      }

      // ── 5 & 6. rebuild the coverage lines either way ───────────
      $page.variables.busy = false;
      await Actions.callChain(context, { chain: 'generateLinesChain' });
    }

  }

  return refreshHrAbsenceChain;
});
