/* PAGE-001 My Timesheet — ACT-004 remove a grid line */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Removes one project/task line from the week — for real.
   *
   * It used to zero the cells locally and queue seven 0-hour saves, on the
   * theory that "these hours are no longer charged here" was the same thing as
   * deleting the line. It is not: V_OC_TS_WEEK_GRID returns a row for any
   * project/task that HAS entries, whatever their hours, so a zeroed line
   * reappeared on the next reload with blank cells and a 0.00 total. Saving
   * again then reported "0 entries saved", correctly — nothing was dirty — which
   * made it look as though the delete had not worked at all when in fact it had
   * done exactly what it was written to do.
   *
   * DELETE line/:tsWeekId/:projectId/:taskId already existed and was never
   * called. oc_time_pkg.remove_line deletes the entries, and it refuses an
   * HR-sourced leave row (is_leave = 'Y') because that is not the employee's to
   * delete (RULE-008) — the same rule the button's oj-bind-if applies, enforced
   * where it counts.
   *
   * Immediate, not deferred to Save draft: a line that is gone from the screen
   * but still in the database until a later save is a lie the grid cannot
   * recover from if the user navigates away.
   */
  class removeLineChain extends ActionChain {

    async run(context, { row } = {}) {
      const { $page, $application } = context;

      if (!row || !$page.variables.weekId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/removeLine',
          uriParams: {
            tsWeekId: $page.variables.weekId,
            projectId: row.projectId,
            taskId: row.taskId,
          },
          body: { actor: $application.variables.employeeId },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Could not remove the line',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        // Drop any pending edits for the line that no longer exists, or Save
        // draft would recreate it with the hours that were just deleted.
        $page.variables.dirtyCells = ($page.variables.dirtyCells || []).filter(
          (c) => !(c.projectId === row.projectId && c.taskId === row.taskId));

        await Actions.fireNotificationEvent(context, {
          summary: 'Line removed',
          message: row.taskName + ' is no longer charged in this week.',
          severity: 'confirmation',
          type: 'confirmation',
          displayMode: 'transient',
        });

        // Reload rather than filtering locally: the server is the authority on
        // what the week now contains, and the day and week totals move with it.
        await Actions.callChain(context, { chain: 'loadGridChain' });

      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Service unavailable'),
          message: $application.functions.chainError(e,
            'The timesheet service is unavailable. Please try again shortly.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return removeLineChain;
});
