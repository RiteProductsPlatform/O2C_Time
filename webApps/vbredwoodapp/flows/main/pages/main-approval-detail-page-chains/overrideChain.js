/* PAGE-005 Approval Detail — ACT-016 override a cell */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Corrects one hour cell as the manager.
   *
   * The write is tagged source='Manager', which is what makes the database
   * capture the employee's original value into the audit trail — the BRD requires
   * the original be kept (PROC-004 / NFR-010).
   *
   * This does NOT approve the week. Correcting several cells then approving once
   * is the normal flow, so the week is closed separately by Finish & approve,
   * which is also what makes the status 'Overridden and approved'.
   */
  class overrideChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const entryId = $page.variables.overrideEntryId;
      const hours   = Number($page.variables.overrideHours) || 0;

      if (!entryId) { return; }

      // RULE-005 — 15-minute blocks.
      if (Math.round(hours * 4) / 4 !== hours) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Invalid hours',
          message: 'Hours must be in 15-minute blocks.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      if (hours < 0 || hours > 24) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Invalid hours',
          message: 'Hours must be between 0 and 24.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      if (!$page.variables.overrideReason) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Reason required',
          message: 'Give a reason for the correction — it is kept in the audit trail.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/overrideEntry',
          uriParams: { tsEntryId: entryId },
          body: {
            newHours: hours,
            reason: $page.variables.overrideReason,
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          $page.variables.showOverride  = false;
          $page.functions.setDialog('overrideDlg', false);
          $page.variables.overrideReason = '';
          $page.variables.overrideCount = ($page.variables.overrideCount || 0) + 1;

          await Actions.fireNotificationEvent(context, {
            summary: 'Hours corrected',
            message: 'Use Finish & approve to close the week as "Overridden and approved".',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });

          await Actions.callChain(context, { chain: 'loadDaysChain' });
          return;
        }

        // A 400 here is usually RULE-003 (the day would now exceed 24h) or
        // RULE-015.
        await Actions.fireNotificationEvent(context, {
          summary: 'Correction refused',
          message: $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Correction failed',
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

  return overrideChain;
});
