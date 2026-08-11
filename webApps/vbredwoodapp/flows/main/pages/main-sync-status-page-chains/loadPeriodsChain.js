/* PAGE-010 Sync Status — the period rollover panel.
 *
 * The monthly OIC run populates next month automatically; nothing opens it
 * (RA-009). This panel is where that step lives, so it stops being a thing
 * somebody has to remember on the 1st.
 *
 * Every flag rendered here is computed by V_OC_TIME_PERIOD_ADMIN, not by this
 * chain — canOpen and canClose are the same conditions OC_TIME_CLOSE_PERIOD
 * refuses on, so a greyed button and a refused call cannot disagree.
 */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class loadPeriodsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getPeriodRollover',
          uriParams: { _t: Date.now() },
        });

        if (resp.ok && resp.body && resp.body.items) {
          $page.variables.periods = resp.body.items.map((p) => ({
            periodId: p.period_id,
            periodName: p.period_name,
            status: p.status,
            phase: p.phase,
            startDate: p.start_date || '',
            endDate: p.end_date || '',
            deliveryCutoff: p.delivery_cutoff || '',
            weeks: p.weeks || 0,
            people: p.people || 0,
            unconfirmed: p.unconfirmed_projects || 0,
            // The view returns 'Y'/'N'; the buttons bind booleans.
            canOpen: p.can_open === 'Y',
            canClose: p.can_close === 'Y',
          }));
        } else if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Periods unavailable',
            message: 'Could not load the period list: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Periods unavailable'),
          message: $application.functions.chainError(e, 'The period service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return loadPeriodsChain;
});
