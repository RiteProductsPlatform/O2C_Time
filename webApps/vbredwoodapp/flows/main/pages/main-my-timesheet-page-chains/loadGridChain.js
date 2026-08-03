/* PAGE-001 My Timesheet — load the weekly grid */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads one week: the shift/standard day row, the pivoted grid, and — when the
   * week was rejected — the reason, remarks and rejected dates (#5).
   *
   * The grid arrives from the server already pivoted Mon..Sun
   * (V_OC_TS_WEEK_GRID), so this chain maps column names to the d0..d6 the table
   * binds to and decides per row whether it is editable.
   */
  class loadGridChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;
      const weekId = $page.variables.weekId;

      if (!weekId) { return; }

      $page.variables.busy = true;

      try {
        // ── Week header from the already-loaded list ───────────
        const week = ($page.variables.weeksRaw || [])
          .find((w) => w.ts_week_id === weekId);

        if (week) {
          // Kept whole so the flag chips can be derived from it by
          // $application.functions.weekFlags rather than restating each flag.
          $page.variables.weekRow          = week;
          $page.variables.weekStatus       = week.week_status;
          $page.variables.weekRange        = week.week_range;
          $page.variables.locked           = week.locked_flag === 'Y';
          $page.variables.defaultedBy      = (week.defaulted_by || '').toUpperCase();
          $page.variables.billableHours    = week.billable_hours || 0;
          $page.variables.nonBillableHours = week.non_billable_hours || 0;
          $page.variables.leaveHours       = week.leave_hours || 0;
          $page.variables.billingLossHours = week.billing_loss_hours || 0;
          $page.variables.totalHours       = week.total_hours || 0;
          $page.variables.standardHours    = week.standard_hours || 0;
          $page.variables.rejectReason     = week.reject_reason || '';
          $page.variables.rejectRemarks    = week.reject_remarks || '';

          // A week is editable when the period allows it AND the week itself is
          // not locked or already closed. RULE-004 / RULE-006 / RULE-007.
          //
          // The editable statuses are the 3 of the 7 that are still the
          // employee's to change. 'Late submission' is NOT among them — it
          // stopped being a status in the 30-Jul-2026 revision and is now a flag
          // on a week whose status is 'Submitted'.
          const periodOk = $application.variables.periodEditable === 'Y';
          const stateOk  = ['Not yet submitted', 'Rejected', 'Submitted']
                             .indexOf(week.week_status) !== -1;
          $page.variables.editable = periodOk && stateOk && week.locked_flag !== 'Y';

          $application.variables.selectedWeekId = weekId;
        }

        // ── Shift + standard hours per day (RULE-011) ──────────
        const shiftResp = await Actions.callRest(context, {
          endpoint: 'oc_time/getShiftRow',
          uriParams: { tsWeekId: weekId, _t: Date.now() },
        });

        const dayRows = (shiftResp.ok && shiftResp.body && shiftResp.body.items) || [];

        // Build the seven column headers. The shift row is the authority on
        // which dates the week actually covers, because weeks are clipped to
        // the month and so can be shorter than seven days.
        const headers = dayRows.map((d) => ({
          entryDate: d.entry_date,
          dayName: d.day_name,
          shiftCode: d.shift_code || '',
          standardHours: d.standard_hours || 0,
          dayTotal: d.day_total || 0,
          // A day with zero standard hours is a weekend or holiday. It stays
          // editable (RULE-012) but is shaded so the user can see why it is 0.
          isWorking: (d.standard_hours || 0) > 0,
        }));
        $page.variables.dayHeaders = headers;

        // ── The grid itself ───────────────────────────────────
        const gridResp = await Actions.callRest(context, {
          endpoint: 'oc_time/getWeekGrid',
          uriParams: { tsWeekId: weekId, _t: Date.now() },
        });

        if (!gridResp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Hours unavailable',
            message: 'Could not load your hours for this week: ' +
                     $application.functions.restError(gridResp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const dateAt = (i) => (headers[i] ? headers[i].entryDate : null);
        const pivot  = ['mon_hours', 'tue_hours', 'wed_hours', 'thu_hours',
                        'fri_hours', 'sat_hours', 'sun_hours'];

        const rows = ((gridResp.body && gridResp.body.items) || []).map((r) => {
          const row = {
            rowKey: r.project_id + '|' + r.task_id,
            projectId: r.project_id,
            projectNumber: r.project_number,
            projectName: r.project_name,
            projectType: r.project_type,
            taskId: r.task_id,
            taskCode: r.task_code,
            taskName: r.task_name,
            taskType: r.task_type,
            billableType: r.billable_type,
            unbilledReason: r.unbilled_reason,
            isLeave: r.is_leave,
            lineTotal: r.line_total,
            lineStatus: r.line_status,
            // Leave is HR-sourced and never employee-editable (RULE-008).
            readOnly: r.is_leave === 'Y',
          };
          for (let i = 0; i < 7; i++) {
            // Only map columns that correspond to a real date in this (possibly
            // clipped) week; the rest stay 0 and are not rendered as inputs.
            row['d' + i] = dateAt(i) === null ? 0 : (r[pivot[i]] || 0);
          }
          return row;
        });

        $page.variables.gridRows = rows;

        $page.variables.dirtyCells = [];
        $page.variables.hasUnsaved = false;

        // ── Rejected dates (#5) ───────────────────────────────
        if ($page.variables.weekStatus === 'Rejected') {
          const rej = await Actions.callRest(context, {
            endpoint: 'oc_time/getRejection',
            uriParams: { tsWeekId: weekId, _t: Date.now() },
          });
          $page.variables.rejectedDates =
            (rej.ok && rej.body && rej.body.items) || [];
        } else {
          $page.variables.rejectedDates = [];
        }

        // ── Retro adjustments already applied (FLD-016..018) ───
        if ($page.variables.adjustmentAllowed) {
          const adj = await Actions.callRest(context, {
            endpoint: 'oc_time/getMyAdjustments',
            uriParams: {
              employeeId: $application.variables.employeeId,
              _t: Date.now(),
            },
          });

          $page.variables.myAdjustments =
            ((adj.ok && adj.body && adj.body.items) || []).map((a) => ({
              adjustmentId: a.adjustment_id,
              workDate: a.work_date,
              adjKind: a.adj_kind,
              oldProjectName: a.old_project_name,
              oldTaskCode: a.old_task_code,
              oldHours: a.old_hours,
              newProjectName: a.new_project_name,
              newTaskCode: a.new_task_code,
              newHours: a.new_hours,
              netHours: a.net_hours,
              status: a.status,
              postedFlag: a.posted_flag,
            }));
        }

        // Align the in-memory totals with what was just loaded.
        $page.functions.recomputeTotals($page.variables);

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
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadGridChain;
});
