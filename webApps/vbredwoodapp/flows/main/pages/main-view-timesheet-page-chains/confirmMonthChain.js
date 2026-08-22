/* PAGE-004 View Timesheet — ACT-020 confirm the month to accrual */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * The single all-employees-at-once confirmation (PROC-009 / RA-015).
   *
   * What this does on the server:
   *   * re-checks RULE-020 — every employee on the project must be Approved;
   *   * writes the consolidated timesheet (employee x project x task x day) plus
   *     the day-wise Reversal(-)/Adjustment(+) rows into
   *     XX_O2C_TIMESHEET_ACCRUAL_IF as one batch;
   *   * closes the approved weeks.
   *
   * The accrual application then PULLS that batch — nothing is pushed into
   * accrual's own tables from here, which is why the success message reports the
   * row count rather than claiming accrual has processed it.
   *
   * Confirmed twice? The interface insert is guarded by a unique key on
   * (confirm_id, employee, project, task, date, entry_type, source), so a repeat
   * confirmation cannot double-post.
   */
  class confirmMonthChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.busy = true;

      try {
        await Actions.callComponentMethod(context, {
          selector: '#confirmMonthDlg',
          method: 'close',
        });

        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/confirmMonth',
          body: {
            projectId: $application.variables.selectedProjectId,
            periodId: $application.variables.selectedPeriodId,
            confirmType: 'Normal',
            actorEmpId: $application.variables.actingManagerId,
            actor: $application.variables.currentEmail,
            traceId: $application.variables.traceId ||
                     $application.functions.newTraceId(),
          },
        });

        if (resp.ok) {
          const rows = ($application.functions.apiBody(resp).accrualRows) || 0;

          $page.variables.accrualRows = rows;

          // ZERO ROWS IS NOT A CONFIRMATION MESSAGE.
          //
          // This said "Confirmed for all employees. 0 rows are ready for the
          // accrual application to collect" in a green confirmation toast, and
          // that is what a real 0-row confirmation looked like on 21-Aug-2026 --
          // the endpoint returned 200 because the MONTH was confirmed, while the
          // hand-off it exists to perform had written nothing. Accrual cannot
          // tell an empty batch from a project nobody worked on, so this has to
          // read as the failure it is even though the call succeeded.
          if (rows === 0) {
            await Actions.fireNotificationEvent(context, {
              summary: 'Confirmed, but nothing was sent to accrual',
              message: 'The month is confirmed, but no rows were written for ' +
                       'accrual to collect. They would read this project-month ' +
                       'as having no time at all. Do not treat this as done — ' +
                       'report it, then re-confirm once it is fixed.',
              severity: 'error',
              type: 'error',
              displayMode: 'transient',
            });
          } else {
            await Actions.fireNotificationEvent(context, {
              summary: 'Month confirmed',
              message: 'Confirmed for all employees. ' + rows +
                       ' rows are ready for the accrual application to collect.',
              severity: 'confirmation',
              type: 'confirmation',
              displayMode: 'transient',
            });
          }

          await Actions.callChain(context, { chain: 'loadSummaryChain' });
          return;
        }

        if (resp.status === 400) {
          // The RULE-020 gate, raised server-side — e.g. someone approved a week
          // in another session between our load and this click (SC-19).
          await Actions.fireNotificationEvent(context, {
            summary: 'Month not confirmed',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          await Actions.callChain(context, { chain: 'loadSummaryChain' });
          return;
        }

        await Actions.fireNotificationEvent(context, {
          summary: 'Confirmation failed',
          message: 'Nothing was sent to accrual — please retry. ' +
                   $application.functions.restError(resp),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Confirmation failed'),
          message: $application.functions.chainError(e, 'The service is unreachable. Nothing was sent to accrual.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return confirmMonthChain;
});
