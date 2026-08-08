define([], () => {
  'use strict';

  /**
   * PAGE-001 My Timesheet — page module functions.
   *
   * These are the pure, synchronous helpers the grid binds to. Anything that
   * talks to ORDS lives in an action chain; anything that only reshapes data in
   * the browser lives here, so the chains stay about business steps.
   */
  class PageModule {

    /**
     * What a closed month means for this employee.
     *
     * Two different answers, because the difference is actionable: inside the
     * backdating window (RULE-019) a mistake can still be corrected through a
     * retro adjustment, and outside it there is genuinely nothing to be done.
     * Telling someone only "this is read-only" leaves them to find that out by
     * hunting.
     */
    closedPeriodMessage(adjustmentAllowed) {
      const base = 'This month is closed, so the hours below cannot be edited. ';
      return adjustmentAllowed === 'Y'
        ? base + 'It is still inside the adjustment window — use Enter New & '
               + 'Cancel Old to correct a day, and your manager will approve it.'
        : base + 'The adjustment window has passed too, so any correction now '
               + 'has to go through your manager.';
    }

    /**
     * Accessible name for an hours box.
     *
     * Every cell used to be labelled just "Hours", which is useless in a grid of
     * seven identical boxes — and it matters more now that the +/- buttons are
     * aria-hidden and out of the tab order, so the box is the only thing a
     * screen reader lands on.
     */
    hoursLabel(entryDate) {
      return 'Hours for ' + (entryDate || 'this day');
    }

    /**
     * Hours on a line for one day column.
     *
     * The day columns are generated from dayHeaders, so the cell only knows its
     * index — and `row['d' + i]` is arithmetic inside a binding, which S1 bars.
     * Returned blank rather than 0 when there is nothing there, so an untouched
     * cell reads as empty instead of as a deliberate zero.
     */
    hoursAt(row, dayIndex) {
      if (!row) { return ''; }
      const v = Number(row['d' + dayIndex]);
      return (!v || isNaN(v)) ? '' : String(v);
    }

    /**
     * Running total for a grid line (FLD-010).
     * Computed rather than stored so the total cannot disagree with the cells.
     */
    lineTotal(row) {
      if (!row) { return 0; }
      let t = 0;
      for (let i = 0; i < 7; i++) {
        t += Number(row['d' + i]) || 0;
      }
      // Two decimals: hours are quarter-hour multiples, so this is exact and
      // avoids 7.199999999 showing up from float addition.
      return Math.round(t * 100) / 100;
    }

    /**
     * Records a changed cell so Save Draft can post only what actually moved.
     *
     * RULE-005 (15-minute blocks) is enforced by the stepper's step=0.25, but a
     * pasted or typed value can still be off-grid, so it is snapped here too.
     * The server re-validates regardless — this is for immediate feedback, not
     * for trust.
     *
     * Takes the raw value rather than the DOM event: the caller is now
     * cellChangedChain, a declared listener, because the inline
     * `function(e){ ... }` this used to be bound to was never wired up (S1).
     * The chain has already discarded anything that is not a real user edit.
     */
    applyCellEdit(page, row, dayIndex, value) {
      if (!page || !row) { return; }

      const raw  = Number(value) || 0;
      const snapped = Math.max(0, Math.min(24, Math.round(raw * 4) / 4));

      // Always write it back. The cell used to be bound two-way, so JET did
      // this and the assignment was only needed when the value was snapped —
      // but an oj-table cell context is a plain object, not an observable, so
      // writeback never worked and the input rendered blank. It reads one-way
      // now, which makes this handler the only thing that updates the row.
      row['d' + dayIndex] = snapped;

      const dates = page.dayHeaders || [];
      const day   = dates[dayIndex];
      if (!day) { return; }

      const key = row.projectId + '|' + row.taskId + '|' + day.entryDate;

      // Last write per cell wins: replace any earlier pending value rather than
      // queueing several updates for the same cell.
      const pending = (page.dirtyCells || []).filter((c) => c.key !== key);
      pending.push({
        key: key,
        tsWeekId: page.weekId,
        projectId: row.projectId,
        taskId: row.taskId,
        entryDate: day.entryDate,
        hours: snapped,
        unbilledReason: row.unbilledReason || null,
      });

      page.dirtyCells = pending;
      page.hasUnsaved = true;

      // Mutating a row object in place does not tell the ADP anything, so the
      // line Total column would keep showing the pre-edit figure. gridADP is
      // live-bound to gridRows at page scope, so replacing the array reference
      // re-renders the table. Safe here because oj-input-number commits on
      // blur/Enter rather than per keystroke, and the guard above ignores the
      // programmatic value-changed that the re-render fires back.
      page.gridRows = (page.gridRows || []).slice();

      this.recomputeTotals(page);
    }

    /**
     * Recomputes the day column totals and the week roll-up from the grid in
     * memory, so the numbers move as the user types instead of only after a
     * save. The authoritative values still come back from the server on reload.
     *
     * Billing loss follows RULE-009: max(0, standard - billable - leave).
     */
    recomputeTotals(page) {
      if (!page) { return; }
      const rows = page.gridRows || [];

      let billable = 0, nonBillable = 0, leave = 0;

      // A NEW object per day, not slice() + mutate.
      //
      // slice() copies the array but keeps the same item references, and
      // oj-bind-for-each reuses the DOM it already rendered for a reference it
      // has seen before — so `d.dayTotal = x` on a plain object updated the
      // data and never the screen. The Entered row went on showing the figures
      // the server sent for a line that had since been removed, while the
      // week total beside it was right, because that is a scalar page variable
      // and those do re-render. Same trap as mutating a gridRows row in place.
      const days = (page.dayHeaders || []).map((d, i) => {
        let dayTotal = 0;
        rows.forEach((r) => { dayTotal += Number(r['d' + i]) || 0; });
        return Object.assign({}, d, { dayTotal: Math.round(dayTotal * 100) / 100 });
      });

      rows.forEach((r) => {
        const t = this.lineTotal(r);
        if (r.isLeave === 'Y') { leave += t; }
        else if (r.billableType === 'Non-billable') { nonBillable += t; }
        else { billable += t; }
      });

      const round = (n) => Math.round(n * 100) / 100;

      // Reassigning the array (rather than mutating in place) is what makes the
      // day header row re-render.
      page.dayHeaders       = days;
      page.billableHours    = round(billable);
      page.nonBillableHours = round(nonBillable);
      page.leaveHours       = round(leave);
      page.totalHours       = round(billable + nonBillable + leave);
      page.billingLossHours = round(
        Math.max(0, (Number(page.standardHours) || 0) - billable - leave));
    }

    /**
     * Removes a line from the grid and queues its cells as zeros.
     *
     * Zeroing rather than deleting keeps it a single code path: the batch save
     * already knows how to write hours, and a zeroed cell is exactly what
     * "these hours are no longer charged here" means. The row is also dropped
     * from view immediately so the grid matches what will be saved.
     */
    removeRow(page, row) {
      if (!page || !row) { return; }
      const days = page.dayHeaders || [];

      const queued = (page.dirtyCells || []).filter(
        (c) => !(c.projectId === row.projectId && c.taskId === row.taskId));

      days.forEach((d) => {
        queued.push({
          key: row.projectId + '|' + row.taskId + '|' + d.entryDate,
          tsWeekId: page.weekId,
          projectId: row.projectId,
          taskId: row.taskId,
          entryDate: d.entryDate,
          hours: 0,
          unbilledReason: null,
        });
      });

      page.dirtyCells = queued;
      // Assigning gridRows is enough — gridADP is live-bound to it.
      page.gridRows   = (page.gridRows || []).filter((r) => r.rowKey !== row.rowKey);
      page.hasUnsaved = true;

      this.recomputeTotals(page);
    }

    /**
     * Column class for a day header.
     *
     * Non-working days stay enterable (RULE-012); the tint only marks them as
     * unusual. A page function because S1 bars concatenation in bindings.
     */
    dayHeaderClass(day) {
      return day && day.isWorking ? 'rw-grid-day' : 'rw-grid-day rw-grid-nonworking';
    }

    /**
     * Column class for the entered-hours total.
     *
     * RULE-003 is a cross-line rule, so a breach is reported on the column total
     * rather than on any single cell.
     */
    dayTotalClass(day) {
      const over = day && Number(day.dayTotal) > 24;
      return over ? 'rw-grid-day rw-grid-total-over' : 'rw-grid-day';
    }

    /**
     * The rejection reason, as a person would say it.
     *
     * CHK_OC_TSA_REASON stores 'Manager', 'Client' or 'Absence'. The banner
     * printed the bare code straight after an em dash, so "This week was
     * rejected — Manager" read as the name of whoever rejected it. The
     * prototype's LOV is the long form.
     */
    rejectReasonLabel(code) {
      const map = {
        Manager: 'Manager driven',
        Client:  'Client driven',
        Absence: 'Absence',
      };
      return map[code] || code || 'not given';
    }

    /** " (by Navamani Solairajan)", or nothing when the trail has no name. */
    rejectedByLabel(name) {
      return name ? ' (by ' + name + ')' : '';
    }

    /** " (2026-09-03)." — the sentence has to end whether or not a date exists. */
    cutoffSuffix(cutoff) {
      return cutoff ? ' (' + cutoff + ').' : '.';
    }

    /**
     * One line of the workflow strip. The view hands back the raw event -
     * 'Submit', 'Reject', 'Approve' - which is a database word, not a sentence.
     */
    wfTitle(row) {
      if (!row) { return ''; }
      const by = row.changed_by ? ' by ' + row.changed_by : '';
      const scope = row.entry_date ? ' (' + row.entry_date + ')' : '';
      const said = {
        Submit:         'Submitted',
        Resubmit:       'Corrected and resubmitted',
        Approve:        'Approved',
        AdvanceApprove: 'Approved in advance',
        Reject:         'Rejected',
        Revoke:         'Decision undone',
        Confirm:        'Confirmed to accrual',
        Default:        'Defaulted at the cut-off',
        Release:        'Salary hold released',
        Override:       'Hours changed by the manager',
        Adjustment:     'Retro adjustment',
        Reversal:       'Reversal',
        ManagerEdit:    'Edited by the manager',
        Import:         'Imported',
      }[row.change_type] || row.change_type;
      return said + scope + by;
    }

    /** Timestamp column. Trimmed to the minute - seconds are noise here. */
    wfWhen(row) {
      const t = (row && row.changed_on) || '';
      return t.length >= 16 ? t.substring(0, 16) : t;
    }

    /** Red for a rejection, green for an approval, grey for everything else. */
    wfDotClass(row) {
      const t = (row && row.change_type) || '';
      if (t === 'Reject') { return 'rw-wf-dot rw-wf-dot-reject'; }
      if (t === 'Approve' || t === 'AdvanceApprove' || t === 'Confirm') {
        return 'rw-wf-dot rw-wf-dot-approve';
      }
      return 'rw-wf-dot';
    }

    /** Accessible name for a grid line's remove button. */
    removeLineLabel(taskName) {
      return 'Remove ' + taskName;
    }


    /**
     * Open or close an oj-dialog by element id.
     *
     * oj-dialog has NO `opened` attribute — that is oj-drawer-popup. Binding
     * `opened="{{ ... }}"` therefore did nothing at all and every dialog on
     * this app was unopenable. JET exposes open()/close() methods instead, so
     * the boolean page variable stays the source of truth for logic and this
     * drives the component from it.
     */
    setDialog(dialogId, open) {
      const dlg = document.getElementById(dialogId);
      if (!dlg) { return; }
      if (open) { dlg.open(); } else { dlg.close(); }
    }


    /**
     * Fusion absence records -> the INT-006 rows POST sync/absence expects.
     *
     * Three conversions, and each one has already cost time:
     *
     *  SPAN -> DAYS. Fusion returns one record per absence, not per day; the
     *  timesheet is a cell per day. The span is expanded, and clipped to the
     *  week, so a leave running past Sunday contributes only its own days here.
     *
     *  DAYS -> HOURS. `duration` is in DAYS — the Fusion screen shows "1 Days".
     *  OC_TS_ENTRY holds hours, so it is days x the worker's standard day. The
     *  division is by the absence's OWN length, not by the visible part, or a
     *  leave straddling the week inflates every day inside it.
     *
     *  CASE. Fusion says 'APPROVED'; populate_month filters on exactly
     *  'Approved'. Send the wrong case and the absence caches perfectly well
     *  and then never becomes a row — it fails silently at the last step, which
     *  is the worst place for it to fail.
     */
    absenceToRows(items, employeeId, from, to, stdHoursPerDay) {
      const std = Number(stdHoursPerDay) || 8;
      const lo = new Date(from + 'T00:00:00');
      const hi = new Date(to + 'T00:00:00');
      const out = [];

      (items || []).forEach((x) => {
        const s = new Date(String(x.startDate).substring(0, 10) + 'T00:00:00');
        const e = new Date(String(x.endDate).substring(0, 10) + 'T00:00:00');
        if (isNaN(s) || isNaN(e)) { return; }

        const whole = Math.round((e - s) / 86400000) + 1;
        const days = Number(x.duration) || whole;
        const perDay = whole ? days / whole : 0;

        const start = s > lo ? s : lo;
        const end = e < hi ? e : hi;

        for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
          out.push({
            EMPLOYEE_ID: employeeId,
            ABSENCE_DATE: d.toISOString().substring(0, 10),
            ABSENCE_TYPE: x.absenceType || 'Leave',
            // CHK_OC_TABS_HRS caps the column at 24
            DURATION_HOURS: Math.round(Math.min(perDay * std, 24) * 100) / 100,
            APPROVAL_STATUS:
              String(x.approvalStatusCd).toUpperCase() === 'APPROVED'
                ? 'Approved' : 'Pending',
          });
        }
      });

      return out;
    }


    /**
     * Why the live absence read failed, in terms of who can fix it.
     *
     * Each status needs a different person, so each gets its own sentence
     * rather than "the call failed" — the same reasoning as the Fusion probe on
     * PAGE-012, and the reason that probe was worth building.
     */
    absenceDiagnosis(status) {
      if (status === 401) {
        return 'Fusion refused the credentials, so leave could not be read. '
             + 'The backend sign-in needs re-entering in VB Studio.';
      }
      if (status === 403) {
        return 'Fusion accepted the sign-in but the service account is not '
             + 'entitled to absence data. This needs a role in Fusion.';
      }
      if (status === 404) {
        return 'The absence resource was not found on this Fusion pod — the '
             + 'REST path or version in services/fa_hcm/service.json is wrong.';
      }
      if (status === 400) {
        return 'Fusion rejected the absence query. Almost always the filter '
             + 'syntax: the separator must be " AND ", not ";".';
      }
      if (!status) {
        return 'Fusion could not be reached, so the leave shown may be out of '
             + 'date. Your hours are unaffected. If this persists, the fa '
             + 'backend may be configured but not published.';
      }
      return 'Leave could not be read from Fusion (' + status + '). The hours '
           + 'below are unaffected.';
    }

  }

  return PageModule;
});
