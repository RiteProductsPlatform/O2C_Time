/* PAGE-005 Approval Detail — ACT-019 approve every pending week */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * The convenience roll-up over ACT-014.
   *
   * One server call, not a loop over the weeks like approveWeeksChain: the
   * endpoint calls approve_employee_month, which selects the pending weeks
   * itself. That matters — the server's list is authoritative and current, so a
   * week submitted while this page sat open is included, and one approved by
   * another manager in the meantime is not approved twice.
   *
   * The trade-off is that this is all-or-nothing where the loop is per-week.
   * Correct here: "approve all" is a single decision, and a partial result would
   * leave the manager guessing which weeks it covered.
   *
   * RULE-015 still applies server-side — assert_not_self is the first thing
   * approve_employee_month does, so a manager cannot sweep up their own week.
   */
  class approveAllWeeksChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      await Actions.callComponentMethod(context, {
        selector: '#approveAllDlg',
        method: 'close',
      });

      $page.variables.busy = true;
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/approveAllWeeks',
          body: {
            projectId:  $application.variables.selectedProjectId,
            periodId:   $application.variables.selectedPeriodId,
            employeeId: $application.variables.selectedEmployeeId,
            actorEmpId: $application.variables.actingManagerId,
            actor:      $application.variables.currentEmail,
            traceId:    $application.variables.traceId ||
                        $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Approved',
            message: 'Every pending week for this employee is approved.',
            severity: 'confirmation',
            type: 'confirmation',
            displayMode: 'transient',
          });
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Not approved',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Not approved',
          message: 'The service was unreachable. Nothing was approved.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
        // Reloaded whatever the outcome: on success to pick up the new statuses,
        // on failure to prove nothing changed.
        await Actions.callChain(context, { chain: 'loadWeeksChain' });
      }
    }
  }

  return approveAllWeeksChain;
});
