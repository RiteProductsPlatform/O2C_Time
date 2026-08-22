/* PAGE-010 Sync Status — load the failed-record queue */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the failed records. Unresolved only by default: this is a work list,
   * and mixing in months of resolved history would bury the rows that still need
   * action.
   *
   * `resolved` is a declared query parameter, so it travels in uriParams — VBCS
   * routes each parameter by what the OpenAPI spec says it is, and anything
   * passed another way is silently dropped.
   */
  class loadFailedChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      try {
        const uriParams = { _t: Date.now() };
        if (!$page.variables.showResolved) {
          uriParams.resolved = 'N';
        }

        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getSyncFailed',
          uriParams: uriParams,
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Queue unavailable',
            message: 'Could not load the failed records: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = (($application.functions.apiBody(resp).items) || []).map((x) => ({
          failedId: x.failed_id,
          jobName: x.job_name,
          jobType: x.job_type,
          entityType: x.entity_type,
          entityKey: x.entity_key,
          employeeId: x.employee_id || '',
          employeeName: x.employee_name || '—',
          failureReason: x.failure_reason,
          failureCode: x.failure_code || '',
          retryCount: x.retry_count || 0,
          resolvedFlag: x.resolved_flag,
          firstSeenOn: x.first_seen_on || '',
          lastRetryOn: x.last_retry_on || '',
          resolvedBy: x.resolved_by || '',
          resolvedOn: x.resolved_on || '',
          traceId: x.trace_id || '',
        }));

        $page.variables.failed       = rows;
        $page.variables.openFailures = rows.filter((r) => r.resolvedFlag === 'N').length;

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Queue unavailable'),
          message: $application.functions.chainError(e, 'Could not load the failed records — the service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return loadFailedChain;
});
