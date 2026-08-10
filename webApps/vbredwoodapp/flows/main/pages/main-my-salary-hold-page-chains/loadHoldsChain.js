/* PROC-007 — load my held dates */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * The employee's own held dates, after the payroll cut-off.
   *
   * Reads V_OC_TS_SALARY_HOLD_MINE through ORDS, which already computes
   * DAYS_LEFT and WINDOW_OPEN. Both are deliberately taken from the server
   * rather than worked out here: the same two facts gate the correction
   * procedure and the manager's queue, and three implementations of "is the
   * window still open" would eventually disagree — most likely across a
   * midnight or a timezone, which is exactly when someone's pay is at stake.
   */
  class loadHoldsChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const empId = $application.variables.employeeId;
      if (!empId) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMySalaryHold',
          uriParams: { employeeId: empId, _t: Date.now() },
        });

        if (!resp.ok) {
          $page.variables.holdRows = [];
          $page.variables.loaded = true;
          await Actions.fireNotificationEvent(context, {
            summary: 'Could not load',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const items = (resp.body && resp.body.items) || [];

        $page.variables.holdRows = items.map((r) => ({
          holdDayId: r.hold_day_id,
          workDate: r.work_date,
          dayName: r.day_name,
          tsWeekId: r.ts_week_id,
          periodName: r.period_name,
          expectedHours: r.expected_hours,
          dayStatus: r.day_status,
          correctedHours: r.corrected_hours,
          correctionReason: r.correction_reason,
          rejectRemarks: r.reject_remarks,
          salaryStatus: r.salary_status,
          windowExpiresOn: r.window_expires_on,
          daysLeft: r.days_left,
          windowOpen: r.window_open,
        }));

        // The banner counts down the TIGHTEST deadline still open, not an
        // average and not the latest. Somebody with one date expiring tomorrow
        // and four next month needs to be told about tomorrow.
        const open = $page.variables.holdRows.filter((r) => r.windowOpen === 'Y');
        $page.variables.openCount = open.length;
        $page.variables.daysLeft = open.length
          ? open.reduce((m, r) => Math.min(m, Number(r.daysLeft) || 0), 9999)
          : 0;

        // Held, but every window has closed. The rows still show — someone
        // whose pay is held must not find an empty page and no explanation.
        $page.variables.windowClosed =
          $page.variables.holdRows.length > 0 && open.length === 0;

        $page.variables.loaded = true;

      } catch (e) {
        if ($application.functions.isAbortError(e)) { return; }
        $page.variables.loaded = true;
        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Could not load'),
          message: $application.functions.chainError(
            e, 'The service is unreachable. Please retry.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadHoldsChain;
});
