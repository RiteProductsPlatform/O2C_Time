/* PAGE-010 Sync Status — load job cards and the failed queue */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class loadStatusChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getSyncStatus',
          uriParams: { _t: Date.now() },
        });

        if (resp.ok && resp.body && resp.body.items) {
          $page.variables.jobs = resp.body.items.map((j) => ({
            jobRunId: j.job_run_id,
            jobName: j.job_name,
            jobType: j.job_type,
            scopeKey: j.scope_key || '—',
            periodName: j.period_name || '',
            actionDate: j.action_date || '',
            jobStatus: j.job_status,
            startedOn: j.started_on || '',
            lastRun: j.last_run || '',
            durationMs: j.duration_ms || 0,
            durationText: $page.functions.durationText(j.duration_ms),
            recordsRead: j.records_read || 0,
            recordsUpserted: j.records_upserted || 0,
            recordsFailed: j.records_failed || 0,
            openFailures: j.open_failures || 0,
            message: j.message || '',
            traceId: j.trace_id || '',
            triggeredBy: j.triggered_by || '',
          }));
        } else if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Job status unavailable',
            message: 'Could not load the job status: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

        await Actions.callChain(context, { chain: 'loadFailedChain' });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Monitoring unavailable'),
          message: $application.functions.chainError(e, 'The monitoring service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadStatusChain;
});
