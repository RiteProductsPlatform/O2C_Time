/* PAGE-001 My Timesheet — ACT-008 allocation pop-up */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Shows project / client / allocation % / approving manager (FLD-005).
   *
   * RULE-001 says allocation across projects should total 100%. It is a WARNING,
   * not a block — an employee legitimately sits above or below 100 mid-transfer
   * or mid-deputation — so the total is surfaced in the dialog and nothing is
   * prevented.
   */
  class showAllocationChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.showAllocation = true;
      $page.functions.setDialog('allocDlg', true);

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getAllocation',
          uriParams: {
            employeeId: $application.variables.employeeId,
            _t: Date.now(),
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Allocation unavailable',
            message: 'Could not load your allocation: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const items = (resp.body && resp.body.items) || [];

        $page.variables.allocationRows = items.map((a) => ({
          allocationId: a.allocation_id,
          projectName: a.project_name,
          customerName: a.customer_name || '—',
          allocPct: a.alloc_pct,
          billingStatus: a.billing_status,
          clientRole: a.client_role || '—',
          approvingManagerName: a.approving_manager_name || '—',
          capType: a.cap_type,
          capHours: a.cap_hours,
        }));

        // The view already computes the total across active allocations.
        const total = items.length ? (items[0].total_alloc_pct || 0) : 0;
        $application.variables.totalAllocPct = total;

        $page.variables.allocationWarning =
          (items.length && total !== 100)
            ? 'Your allocation across projects totals ' + total +
              '%, not 100%. Raise this with your manager if it looks wrong — ' +
              'you can still record time.'
            : '';

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Allocation unavailable',
          message: 'Could not load your allocation — the service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return showAllocationChain;
});
