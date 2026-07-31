/* PAGE-001 My Timesheet — ACT-002 Submit for Approval */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Submits the week.
   *
   * Unsaved cells are saved first: a user who edits and clicks Submit means
   * "submit what I see", and submitting the previously saved state instead would
   * silently discard their last edits. If that save fails, submission is
   * abandoned rather than sending stale hours to the manager.
   *
   * The server applies RULE-002 (unbilled reason), RULE-003 (24h/day) and
   * RULE-007, and per project line routes to that project's approving manager.
   *
   * On lateness: since the 30-Jul-2026 revision a late submit is NOT a distinct
   * status. submit_week always yields 'Submitted' and sets LATE_SUBMISSION_FLAG,
   * so the response status alone cannot tell us whether the cut-off was missed.
   * The flag is read from the reloaded week instead — which is also the value the
   * manager will see, so the two can never disagree.
   */
  class submitWeekChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const weekId = $page.variables.weekId;

      if (!weekId) { return; }

      // Flush pending edits first.
      if ($page.variables.hasUnsaved) {
        await Actions.callChain(context, { chain: 'saveDraftChain' });

        if ($page.variables.hasUnsaved) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Not submitted',
            message: 'Your changes could not be saved, so the week was not submitted.',
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/submitWeek',
          uriParams: { id: weekId },
          body: {
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (!resp.ok) {
          // A 400 is a rule refusal and the message names the rule, e.g.
          // "An unbilled reason is required for non-billable hours."
          await Actions.fireNotificationEvent(context, {
            summary: resp.status === 400 ? 'This week cannot be submitted yet'
                                         : 'Submit failed',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        // Refresh the week list so the new status shows in the selector, then
        // reload the grid read-only. Done before the notification so the flag
        // read below is the server's, not a guess.
        await Actions.callChain(context, { chain: 'periodChangedChain' });

        const fresh = $page.variables.weekRow || {};
        const late  = (fresh.late_submission_flag || fresh.LATE_SUBMISSION_FLAG) === 'Y';

        await Actions.fireNotificationEvent(context, {
          summary: late ? 'Submitted late' : 'Submitted',
          message: late
            ? 'Submitted after the weekly cut-off, so it is flagged as a late submission. It is with your manager for approval.'
            : 'Submitted for approval.',
          severity: late ? 'warning' : 'confirmation',
          type: late ? 'warning' : 'confirmation',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Submit failed',
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

  return submitWeekChain;
});
