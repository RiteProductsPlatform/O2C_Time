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
    dayExportUrl(tsWeekId) {
      if (!tsWeekId) { return ''; }
      return this.$application.variables.ordsBaseUrl +
             '/oc/time/approval/days/' + tsWeekId + '/export';
    }

    /** Accessible name for the download link. */
    dayExportLabel(weekLabel) {
      return 'Download ' + (weekLabel || 'this week') + ' as CSV';
    }

    /**
     * Selects or clears a whole DATE in the daily view.
     *
     * A date has several task lines and the BRD approves at date level, not line
     * level — approving three of a day's five lines is not a state the workflow
     * models. So the checkbox on any line toggles the entire date, and
     * selectedDates holds distinct date strings rather than row keys.
     */
    toggleDate(entryDate, event) {
      const page = this.$page.variables;
      const list = (page.selectedDates || []).slice();
      const on   = event && event.target && event.target.checked;

      const at = list.indexOf(entryDate);

      if (on && at === -1) {
        list.push(entryDate);
      } else if (!on && at >= 0) {
        list.splice(at, 1);
      }

      page.selectedDates = list;
    }

    /** True when the date is ticked — drives the daily checkbox. */
    isDateSelected(entryDate) {
      return (this.$page.variables.selectedDates || []).indexOf(entryDate) >= 0;
    }

    /**
     * Toggles one week in the weekly selection.
     *
     * Same reasoning as the date selection: oj-table's selected-row-keys expects a
     * JET KeySet, while the approve/reject calls iterate a plain array of week
     * ids. Holding the selection as an array keeps one representation throughout.
     */
    toggleWeek(tsWeekId, event) {
      const page = this.$page.variables;
      const list = (page.selectedWeekKeys || []).slice();
      const on   = event && event.target && event.target.checked;
      const at   = list.indexOf(tsWeekId);

      if (on && at === -1)     { list.push(tsWeekId); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      page.selectedWeekKeys = list;
    }

    isWeekSelected(tsWeekId) {
      return (this.$page.variables.selectedWeekKeys || []).indexOf(tsWeekId) >= 0;
    }

    /**
     * Selects the weeks that still need a decision.
     *
     * Approved, overridden-and-approved and closed weeks are skipped: they are
     * settled, and re-approving them would add noise to the approval log for no
     * change in state.
     */
    selectPendingWeeks() {
      const page = this.$page.variables;
      page.selectedWeekKeys = this.pendingWeeks(page.weeks).map((w) => w.tsWeekId);
    }

    clearWeekSelection() {
      this.$page.variables.selectedWeekKeys = [];
    }

    /** Selects every distinct date currently in the daily grid. */
    selectAllDates() {
      const page = this.$page.variables;
      const dates = [];
      (page.days || []).forEach((d) => {
        if (dates.indexOf(d.entryDate) === -1) { dates.push(d.entryDate); }
      });
      page.selectedDates = dates;
    }

    clearDateSelection() {
      this.$page.variables.selectedDates = [];
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

    weekPickValue(tsWeekId) {
      return this.isWeekSelected(tsWeekId) ? ['on'] : [];
    }

    weekPickLabel(weekIndex) {
      return 'Select week ' + weekIndex;
    }

    toggleWeekPick(tsWeekId, event) {
      const on = !!(event && event.detail && event.detail.value &&
                    event.detail.value.length);
      const list = (this.$page.variables.selectedWeekKeys || []).slice();
      const at = list.indexOf(tsWeekId);

      if (on && at === -1)     { list.push(tsWeekId); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      this.$page.variables.selectedWeekKeys = list;
    }

    datePickValue(entryDate) {
      return this.isDateSelected(entryDate) ? ['on'] : [];
    }

    datePickLabel(entryDate) {
      return 'Select ' + entryDate;
    }

    toggleDatePick(entryDate, event) {
      const on = !!(event && event.detail && event.detail.value &&
                    event.detail.value.length);
      const list = (this.$page.variables.selectedDates || []).slice();
      const at = list.indexOf(entryDate);

      if (on && at === -1)     { list.push(entryDate); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      this.$page.variables.selectedDates = list;
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

  }

  return PageModule;
});
