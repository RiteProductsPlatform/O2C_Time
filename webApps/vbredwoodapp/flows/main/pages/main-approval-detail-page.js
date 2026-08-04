define([], () => {
  'use strict';

  /**
   * A week nobody needs to decide on any more. Everything else is "pending",
   * including Rejected and Defaulted — a defaulted week still needs the manager
   * to edit or approve it, and a rejected one is back with the employee but has
   * not reached an outcome.
   *
   * The same three values as approve_employee_month's WHERE clause. If the two
   * ever disagree, "Approve all pending" would report a different number from
   * the one the server acts on.
   */
  const SETTLED = ['Approved', 'Overridden and approved', 'Closed'];

  /**
   * PAGE-005 Approval Detail — page module functions.
   */
  class PageModule {

    /** The weeks still awaiting a decision. */
    pendingWeeks(weeks) {
      return (weeks || []).filter((w) => SETTLED.indexOf(w.weekStatus) === -1);
    }

    /**
     * ACT-019 button label. Carries the count, so the manager knows the size of
     * what they are about to approve before they open the confirmation.
     */
    approveAllLabel(count) {
      if (!count)      { return 'No pending weeks'; }
      if (count === 1) { return 'Approve the 1 pending week'; }
      return 'Approve all ' + count + ' pending weeks';
    }

    /**
     * ACT-018 download. A direct ORDS URL rather than a callRest: the browser
     * has to fetch this itself for the Save dialog to appear, and the handler
     * sets the filename in Content-Disposition.
     */
    dayExportUrl(ordsBaseUrl, tsWeekId) {
      if (!tsWeekId) { return ''; }
      return (ordsBaseUrl || '') +
             '/oc/time/approval/days/' + tsWeekId + '/export';
    }

    /** Accessible name for the download link. */
    dayExportLabel(weekLabel) {
      return 'Download ' + (weekLabel || 'this week') + ' as CSV';
    }


    /** True when the date is ticked — drives the daily checkbox. */
    isDateSelected(selectedDates, entryDate) {
      return (selectedDates || []).indexOf(entryDate) >= 0;
    }


    isWeekSelected(selectedWeekKeys, tsWeekId) {
      return (selectedWeekKeys || []).indexOf(tsWeekId) >= 0;
    }

    /**
     * Selects the weeks that still need a decision.
     *
     * Approved, overridden-and-approved and closed weeks are skipped: they are
     * settled, and re-approving them would add noise to the approval log for no
     * change in state.
     */
    selectPendingWeeks(page) {
      if (!page) { return; }
      page.selectedWeekKeys = this.pendingWeeks(page.weeks).map((w) => w.tsWeekId);
    }

    clearWeekSelection(page) {
      if (page) { page.selectedWeekKeys = []; }
    }

    /** Selects every distinct date currently in the daily grid. */
    selectAllDates(page) {
      if (!page) { return; }
      const dates = [];
      (page.days || []).forEach((d) => {
        if (dates.indexOf(d.entryDate) === -1) { dates.push(d.entryDate); }
      });
      page.selectedDates = dates;
    }

    clearDateSelection(page) {
      if (page) { page.selectedDates = []; }
    }

    /**
     * A settled week offers no approve/reject action.
     *
     * 'Closed' is terminal (the month was confirmed to accrual); the two approved
     * states are decisions already taken.
     */
    isSettled(weekStatus) {
      return ['Approved', 'Overridden and approved', 'Closed']
        .indexOf(weekStatus) !== -1;
    }

    // ── Row pickers (oj-checkboxset) ──────────────────────────
    // oj-checkboxset carries an array value, so "ticked" is ['on'] and
    // "unticked" is []. These helpers keep that translation out of the markup,
    // which S1 requires bindings to be free of.

    weekPickValue(selectedWeekKeys, tsWeekId) {
      return this.isWeekSelected(selectedWeekKeys, tsWeekId) ? ['on'] : [];
    }

    weekPickLabel(weekIndex) {
      return 'Select week ' + weekIndex;
    }

    toggleWeekPick(page, tsWeekId, picked) {
      if (!page) { return; }
      const on   = !!(picked && picked.length);
      const list = (page.selectedWeekKeys || []).slice();
      const at = list.indexOf(tsWeekId);

      if (on && at === -1)     { list.push(tsWeekId); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      page.selectedWeekKeys = list;
    }

    datePickValue(selectedDates, entryDate) {
      return this.isDateSelected(selectedDates, entryDate) ? ['on'] : [];
    }

    datePickLabel(entryDate) {
      return 'Select ' + entryDate;
    }

    toggleDatePick(page, entryDate, picked) {
      if (!page) { return; }
      const on   = !!(picked && picked.length);
      const list = (page.selectedDates || []).slice();
      const at = list.indexOf(entryDate);

      if (on && at === -1)     { list.push(entryDate); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      page.selectedDates = list;
    }

    /**
     * Names the cell being corrected, so the override dialog says which line and
     * which day it is about rather than just "hours".
     */
    overrideLabelFor(row) {
      if (!row) { return ''; }
      return row.projectName + ' / ' + row.taskName + ' · ' + row.entryDate;
    }

    /** Human label for a week row, used as the daily view's heading. */
    weekLabelFor(row) {
      if (!row) { return ''; }
      return 'Week ' + row.weekIndex + ' (' + row.weekRange + ')';
    }

    /** Tooltip on a leave line, naming the absence type when HCM supplied one. */
    leaveTitle(absenceType) {
      return absenceType
        ? 'From HCM Absence: ' + absenceType
        : 'From HCM Absence';
    }

    /** Tooltip carrying a day's rejection reason and remarks. */
    rejectTitle(row) {
      if (!row || !row.rejectReason) { return ''; }
      return row.rejectRemarks
        ? row.rejectReason + ' \u2014 ' + row.rejectRemarks
        : row.rejectReason;
    }

    /** Explains what the reject dialog will act on, given its scope. */
    rejectScopeNote(scope) {
      return scope === 'dates'
        ? 'The selected dates go back to the employee. They are told exactly which days to correct.'
        : 'The selected weeks go back to the employee, unlocked so they can correct and resubmit.';
    }

    /** Accessible name for a week's open button. */
    openWeekLabel(weekIndex) {
      return 'Open week ' + weekIndex;
    }

    /** Accessible name for a day line's correct button. */
    correctLabel(taskName) {
      return 'Correct hours for ' + taskName;
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
