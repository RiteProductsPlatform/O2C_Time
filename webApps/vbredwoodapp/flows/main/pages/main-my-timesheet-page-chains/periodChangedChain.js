/* PAGE-001 My Timesheet — month changed */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the weeks in the selected month and the cut-off dates, then selects a
   * week.
   *
   * Which week: the current week if it is in this month (FLD-002 "show current
   * week by default"), otherwise the last week — because when someone opens a
   * past month they are almost always chasing the end of it.
   *
   * Editability comes from the period, not from the client's clock: the server
   * view already resolved RULE-004 (future frozen) and RULE-007 (open until the
   * delivery cut-off), so the page just reflects it.
   */
  class periodChangedChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const periodId = $page.variables.periodId;

      if (!periodId) { return; }

      $application.variables.selectedPeriodId = periodId;

      // Reset per-week state so a stale grid is never shown against a new month.
      $page.variables.dirtyCells = [];
      $page.variables.hasUnsaved = false;
      $page.variables.gridRows   = [];

      // ── Period metadata: editability + cut-offs ──────────────
      const opts = $application.variables.periodOptionsArray || [];
      const meta = opts.find((o) => o.value === periodId);

      if (meta) {
        $application.variables.selectedPeriodName = meta.label;
        $page.variables.periodState = meta.periodState;
        $page.variables.adjustmentAllowed = meta.adjustmentAllowed === 'Y';
        $application.variables.periodEditable    = meta.editableFlag;
        $application.variables.adjustmentAllowed = meta.adjustmentAllowed;
      }

      try {
        const cut = await Actions.callRest(context, {
          endpoint: 'oc_time/getCutoffs',
          uriParams: { periodId: periodId, _t: Date.now() },
        });

        if (cut.ok && cut.body && cut.body.items && cut.body.items.length) {
          const c = cut.body.items[0];
          $page.variables.weeklyCutoff   = c.weekly_cutoff_display || '';
          $page.variables.deliveryCutoff = c.delivery_cutoff || '';
        }
      } catch (e) {
        // Cut-off display is informational; the grid still works without it.
        $page.variables.weeklyCutoff = '';
      }

      // ── Weeks in the month ──────────────────────────────────
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getMyWeeks',
          uriParams: {
            employeeId: $application.variables.employeeId,
            periodId: periodId,
            _t: Date.now(),
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Weeks unavailable',
            message: 'Could not load the weeks for this month: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const weeks = ($application.functions.apiBody(resp).items) || [];
        $page.variables.weeksRaw = weeks;

        $page.variables.weekOptionsArray = weeks.map((w) => ({
          value: w.ts_week_id,
          label: 'Week ' + w.week_index + '  (' + w.week_range + ')',
          weekStatus: w.week_status,
          locked: w.locked_flag,
        }));

        if (!weeks.length) {
          // Nothing populated yet — most often a month the population job has
          // not reached, or an employee with no allocation.
          $page.variables.weekId = null;
          await Actions.fireNotificationEvent(context, {
            summary: 'Nothing to show',
            message: 'No timesheet has been prepared for this month yet.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
          return;
        }

        const today = new Date();
        const iso = today.getFullYear() + '-' +
                    String(today.getMonth() + 1).padStart(2, '0') + '-' +
                    String(today.getDate()).padStart(2, '0');

        // A WEEK ASKED FOR BY NAME WINS. Salary on Hold navigates here with
        // $application.variables.selectedWeekId set to the week behind the date
        // somebody clicked, and nothing read it back -- so "Open week" on
        // 01-Jun landed on the LAST week of June, because no June week contains
        // today and the fallback below takes weeks[length - 1]. The date they
        // clicked was nowhere on the screen they arrived at.
        //
        // Matched against THIS month's weeks rather than trusted blindly: the
        // id belongs to whichever month it was set from, and a stale one must
        // not stop the month picker working.
        //
        // Cleared once used, so changing month afterwards goes back to the
        // ordinary "current week, else the last one" behaviour rather than
        // snapping back to the held week for ever.
        const asked = $application.variables.selectedWeekId;
        const wanted = asked ? weeks.find((w) => w.ts_week_id === asked) : null;
        if (wanted) { $application.variables.selectedWeekId = null; }

        const current = weeks.find((w) => w.week_start <= iso && w.week_end >= iso);
        const pick = wanted || current || weeks[weeks.length - 1];

        // Assigning weekId fires loadGridChain. If the same week is reselected
        // the value does not change and the chain would not fire, so reload
        // explicitly in that case.
        if ($page.variables.weekId === pick.ts_week_id) {
          await Actions.callChain(context, { chain: 'loadGridChain' });
        } else {
          $page.variables.weekId = pick.ts_week_id;
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Service unavailable'),
          message: $application.functions.chainError(e, 'The timesheet service is unavailable. Please try again shortly.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return periodChangedChain;
});
