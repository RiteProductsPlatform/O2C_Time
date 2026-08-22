/* PAGE-001 My Timesheet — ACT-001 Save Draft */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Saves the changed cells in ONE batch call.
   *
   * A weekly grid is up to 7 x lines cells; posting each individually would be
   * dozens of round-trips and would leave the week half-saved if one failed.
   * The batch endpoint iterates server-side in a single transaction, so the
   * week either saves completely or not at all — which is what "Save draft"
   * has to mean.
   *
   * A 400 here is a business rule (RULE-003 over 24h, RULE-005 off-grid,
   * RULE-010 bad task); the rule's own message is shown rather than a generic
   * failure, because the user needs to know which rule they hit.
   */
  class saveDraftChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const cells = $page.variables.dirtyCells || [];

      // COUNTED NOW, BEFORE ANYTHING IS CLEARED.
      //
      // `cells` is a REFERENCE to $page.variables.dirtyCells, not a copy. The
      // success path sets that variable to [] and then read cells.length
      // afterwards — and VB empties the underlying observable array in place
      // rather than swapping it, so by the time the message was built the
      // local was empty too. Result: "0 entries saved" as a CONFIRMATION,
      // after a save that had worked, on a page still showing the new hours.
      //
      // Reported twice. The first fix corrected which number to trust — server
      // over client — and left the aliasing, so the same words came back from a
      // different direction. Reading a count after clearing its source is the
      // actual defect; taking a copy of the number is the fix.
      const sent = cells.length;

      if (!sent) {
        // Accurate but easy to misread: after removing a line there is
        // legitimately nothing to save, because Remove deletes the entries
        // server-side straight away rather than queueing a change. Saying so
        // outright stops it reading as "the delete did not work".
        await Actions.fireNotificationEvent(context, {
          summary: 'Nothing to save',
          message: 'Every change is already saved. Removing a line takes effect '
                 + 'immediately, so it needs no save.',
          severity: 'info',
          type: 'info',
          displayMode: 'transient',
        });
        return;
      }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/saveEntriesBatch',
          body: {
            cells: cells.map((c) => ({
              tsWeekId: c.tsWeekId,
              projectId: c.projectId,
              taskId: c.taskId,
              // ORDS needs the time component; a bare YYYY-MM-DD is answered
              // with a 400 carrying no useful message.
              entryDate: $application.functions.toApiDate(c.entryDate),
              hours: c.hours,
              unbilledReason: c.unbilledReason,
            })),
            source: 'Employee',
            actor: $application.variables.currentEmail,
          },
        });

        if (resp.ok) {
          $page.variables.dirtyCells = [];
          $page.variables.hasUnsaved = false;

          // Report what the SERVER saved, not what we hoped it would.
          // `(resp.body.saved || cells.length)` quietly substituted the number
          // sent whenever the server said 0, so a request that reached the
          // handler and stored nothing still read as a success. A 200 with
          // saved = 0 means the rows did not arrive in the shape the handler
          // reads — that is worth saying, not papering over.
          const saved = (typeof $application.functions.apiBody(resp).saved === 'number')
            ? $application.functions.apiBody(resp).saved : null;

          // A count of zero is never a success, so it must never be phrased as
          // one. "0 entries saved" told the user nothing about why - and the
          // usual why is a rule refusal the server already explained in the
          // body, which is worth repeating here rather than discarding.
          if (saved === 0) {
            await Actions.fireNotificationEvent(context, {
              summary: 'Nothing was saved',
              message: ($application.functions.apiBody(resp).error)
                ? $application.functions.apiBody(resp).error
                : 'The server stored none of the ' + sent + ' changed '
                  + 'cells and gave no reason. Your hours are still on screen — '
                  + 'please report this rather than retyping them.',
              severity: 'error',
              type: 'error',
              displayMode: 'transient',
            });
          } else {
            const n = (saved === null ? sent : saved);
            await Actions.fireNotificationEvent(context, {
              summary: 'Draft saved',
              message: n + (n === 1 ? ' entry saved.' : ' entries saved.'),
              severity: 'confirmation',
              type: 'confirmation',
              displayMode: 'transient',
            });
          }

          // Reload so server-derived values the client cannot compute — billing
          // loss, the roll-up, the day statuses — are the ones on screen.
          await Actions.callChain(context, { chain: 'loadGridChain' });
          return;
        }

        // The unsaved cells are deliberately kept so a retry does not lose work.
        await Actions.fireNotificationEvent(context, {
          summary: resp.status === 400 ? 'Some hours were refused' : 'Save failed',
          message: $application.functions.restError(resp) +
                   ' Your changes are still on screen.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Save failed'),
          message: $application.functions.chainError(e, 'The service is unreachable. Your changes are still on screen — please retry.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return saveDraftChain;
});
