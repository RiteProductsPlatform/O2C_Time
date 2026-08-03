/* PAGE-011 Accrual Integration — open the extract for one confirmation */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the day-wise interface rows written by one confirmation.
   *
   * This is exactly what the accrual application will pull, which is the point:
   * an admin investigating a discrepancy needs to see the rows as the consumer
   * sees them, not a re-derivation.
   */
  class openExtractChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{confirmId:number, label:string}} params
     */
    async run(context, { confirmId, label }) {
      const { $page, $application } = context;

      if (!confirmId) { return; }

      $page.variables.confirmId    = confirmId;
      $page.variables.extractLabel = label || '';
      $page.variables.extractView  = 'all';
      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getAccrualExtract',
          uriParams: { confirmId: confirmId, _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Extract unavailable',
            message: 'Could not load the extract: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        $page.variables.extractRaw = ((resp.body && resp.body.items) || []).map((r) => ({
          ifId: r.if_id,
          employeeId: r.employee_id,
          employeeName: r.employee_name,
          workerType: r.worker_type || '',
          projectNumber: r.project_number,
          projectName: r.project_name,
          wbsTask: r.wbs_task,
          wbsTaskName: r.wbs_task_name || '',
          workDate: r.work_date,
          billed: r.billed || 0,
          unbilled: r.unbilled || 0,
          leaveHours: r.leave_hours || 0,
          unbilledReason: r.unbilled_reason || '',
          entryType: r.entry_type,
          approval: r.approval || '',
          flag: r.flag || '',
          actionDate: r.action_date || '',
          batchId: r.batch_id || '',
          processedFlag: r.processed_flag || 'N',
          pulledOn: r.pulled_on || '',
        }));

        await Actions.callChain(context, { chain: 'filterExtractChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Extract unavailable'),
          message: $application.functions.chainError(e, 'The accrual service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return openExtractChain;
});
