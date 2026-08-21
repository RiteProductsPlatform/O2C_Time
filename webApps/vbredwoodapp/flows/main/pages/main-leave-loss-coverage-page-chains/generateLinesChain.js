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
          const b = resp.body || {};
          const n = b.linesCreated || 0;
          // A REMOVAL IS NEWS TOO. This reported linesCreated alone, so a
          // withdrawn absence dropping off the list said "No new absences to
          // cover" -- which is true, and reads as "nothing happened" at the
          // exact moment something did. Reported 21-Aug, when a retracted
          // 20-Aug line vanished with no explanation on screen.
          const gone = b.linesRemoved || 0;
          const orph = b.approvedOrphans || 0;

          const said = [];
          if (n)    { said.push(n + (n === 1 ? ' absence added' : ' absences added')); }
          if (gone) { said.push(gone + (gone === 1 ? ' withdrawn absence removed'
                                                   : ' withdrawn absences removed')); }
          if (orph) { said.push(orph + (orph === 1
                        ? ' approved cover now has no absence behind it'
                        : ' approved covers now have no absence behind them')); }

          await Actions.fireNotificationEvent(context, {
            summary: said.length ? 'Absences refreshed' : 'Nothing changed',
            message: said.length ? said.join(', ') + '.'
                                 : 'No new or withdrawn absences.',
            severity: orph ? 'warning' : 'confirmation',
            type: orph ? 'warning' : 'confirmation',
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
          summary: $application.functions.chainSummary(e, 'Could not refresh absences'),
          message: $application.functions.chainError(e, 'The service is unreachable. Please retry.'),
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
