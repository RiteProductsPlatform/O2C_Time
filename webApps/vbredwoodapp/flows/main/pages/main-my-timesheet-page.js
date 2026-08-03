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
    applyCellEdit(row, dayIndex, value) {
      if (!row) { return; }

      const page = this.$page.variables;
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

      this.recomputeTotals();
    }

    /**
     * Recomputes the day column totals and the week roll-up from the grid in
     * memory, so the numbers move as the user types instead of only after a
     * save. The authoritative values still come back from the server on reload.
     *
     * Billing loss follows RULE-009: max(0, standard - billable - leave).
     */
    recomputeTotals() {
      const page = this.$page.variables;
      const rows = page.gridRows || [];
      const days = (page.dayHeaders || []).slice();

      let billable = 0, nonBillable = 0, leave = 0;

      days.forEach((d, i) => {
        let dayTotal = 0;
        rows.forEach((r) => { dayTotal += Number(r['d' + i]) || 0; });
        d.dayTotal = Math.round(dayTotal * 100) / 100;
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
    removeRow(row) {
      const page = this.$page.variables;
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

      this.recomputeTotals();
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

  }

  return PageModule;
});
