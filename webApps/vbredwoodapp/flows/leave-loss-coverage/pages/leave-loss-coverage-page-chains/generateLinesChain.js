/* PAGE-006 Leave Loss Coverage — build the absentee list from HR */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Rebuilds the absentee list from HCM absences.
   *
   * Idempotent by design: the server inserts only absences that do not already
   * have a coverage line, so pressing this after new leave is approved adds the
   * new days without disturbing covers already assigned or approved.
   */
  class generateLinesChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      if (!$page.variables.projectId || !$page.variables.periodId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/generateLlc',
          body: {
            projectId: $page.variables.projectId,
            periodId: $page.variables.periodId,
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          const n = (resp.body && resp.body.linesCreated) || 0;
          await Actions.fireNotificationEvent(context, {
            summary: n === 0 ? 'Nothing new' : 'Absences added',
            message: n === 0
              ? 'No new absences to cover.'
              : n + (n === 1 ? ' absence added.' : ' absences added.'),
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadLinesChain' });
          return;
        }

        // A 400 means the project is not FCP + leave loss — which the picker
        // should have prevented, so surface the server's own wording.
        await Actions.fireNotificationEvent(context, {
          summary: 'Could not refresh absences',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Could not refresh absences',
          message: 'The service is unreachable. Please retry.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return generateLinesChain;
});
