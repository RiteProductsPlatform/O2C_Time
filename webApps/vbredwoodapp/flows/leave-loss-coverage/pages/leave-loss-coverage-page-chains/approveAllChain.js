/* PAGE-006 Leave Loss Coverage — approve every assigned line */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Approves all assigned coverage in one pass.
   *
   * Confirmed first because it makes billed hours across the whole project month,
   * and reported per line so a partial failure is visible rather than hidden
   * behind a single success message.
   */
  class approveAllChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const pending = ($page.variables.lines || [])
        .filter((l) => l.llcStatus === 'Assigned');

      if (!pending.length) { return; }

      $page.variables.busy = true;

      let done = 0;
      let failed = 0;
      let firstError = '';

      try {
        await Actions.callComponentMethod(context, {
          selector: '#approveAllDlg',
          method: 'close',
        });

        for (let i = 0; i < pending.length; i++) {
          try {
            const resp = await Actions.callRest(context, {
              endpoint: 'oc_time/approveCover',
              uriParams: { id: pending[i].llcId },
              body: {
                actorEmpId: $application.variables.actingManagerId,
                actor: $application.variables.currentEmail,
              },
            });
            if (resp.ok) {
              done++;
            } else {
              failed++;
              if (!firstError) {
                firstError = $application.functions.restError(resp);
              }
            }
          } catch (e) {
            failed++;
            if (!firstError) { firstError = 'The service was unreachable.'; }
          }
        }

        await Actions.fireNotificationEvent(context, {
          summary: failed ? 'Partly approved' : 'Coverage approved',
          message: failed
            ? done + ' approved, ' + failed + ' failed. ' + firstError
            : done + ' coverage line(s) approved and now billed.',
          severity: failed ? 'warning' : 'confirmation',
          type: failed ? 'warning' : 'confirmation',
          displayMode: 'transient',
        });

        await Actions.callChain(context, { chain: 'loadLinesChain' });

      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return approveAllChain;
});
