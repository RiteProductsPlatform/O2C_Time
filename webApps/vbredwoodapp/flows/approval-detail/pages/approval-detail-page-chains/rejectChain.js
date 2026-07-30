/* PAGE-005 Approval Detail — ACT-015 reject a week or specific dates */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Rejects at whichever granularity the dialog was opened for.
   *
   * Either way the week goes back to the employee unlocked so they can correct
   * and resubmit (PROC-005 / RULE-007), and the rejected DATES are recorded on
   * the individual entries so the employee is told precisely which days to fix
   * rather than just "the week was rejected".
   */
  class rejectChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const reason = $page.variables.rejectReason;

      if (!reason) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Reason required',
          message: 'Select a rejection reason.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      const common = {
        reason: reason,
        remarks: $page.variables.rejectRemarks || null,
        actorEmpId: $application.variables.actingManagerId,
        actor: $application.variables.currentEmail,
        traceId: $application.variables.traceId ||
                 $application.functions.newTraceId(),
      };

      try {
        // ---- date-wise ----------------------------------------
        if ($page.variables.rejectScope === 'dates') {
          const resp = await Actions.callRest(context, {
            endpoint: 'oc_time/rejectDays',
            uriParams: { id: $page.variables.weekId },
            body: Object.assign({
              dates: ($page.variables.selectedDates || [])
                .map((d) => $application.functions.toApiDate(d)),
            }, common),
          });

          if (resp.ok) {
            const n = (resp.body && resp.body.rejectedDates) || 0;
            $page.variables.showReject    = false;
            $page.variables.selectedDates = [];

            await Actions.fireNotificationEvent(context, {
              summary: 'Dates rejected',
              message: n + (n === 1 ? ' date' : ' dates') +
                       ' rejected — back with the employee.',
              severity: 'confirmation',
              type: 'confirmation',
              displayMode: 'transient',
            });
            await Actions.callChain(context, { chain: 'loadWeeksChain' });
          } else {
            // The dialog stays open so the typed remarks are not lost.
            await Actions.fireNotificationEvent(context, {
              summary: 'Reject failed',
              message: $application.functions.restError(resp),
              severity: 'error',
              type: 'error',
              displayMode: 'transient',
            });
          }
          return;
        }

        // ---- week-wise: one call per selected week ------------
        const keys = $page.variables.selectedWeekKeys || [];
        let done = 0;
        let failed = 0;
        let firstError = '';

        for (let i = 0; i < keys.length; i++) {
          try {
            const resp = await Actions.callRest(context, {
              endpoint: 'oc_time/rejectWeek',
              uriParams: { id: keys[i] },
              body: common,
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

        if (done) {
          $page.variables.showReject = false;
          await Actions.fireNotificationEvent(context, {
            summary: failed ? 'Partly rejected' : 'Rejected',
            message: done + (done === 1 ? ' week' : ' weeks') + ' rejected' +
                     (failed ? ', ' + failed + ' failed. ' + firstError
                             : ' — back with the employee.'),
            severity: failed ? 'warning' : 'confirmation',
            type: failed ? 'warning' : 'confirmation',
            displayMode: 'transient',
          });
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Nothing rejected',
            message: firstError || 'Reject failed.',
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

        await Actions.callChain(context, { chain: 'loadWeeksChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Reject failed',
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

  return rejectChain;
});
