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
  // A week is the manager's to decide only if it actually reached them: the
  // employee submitted it, or the weekly cut-off submitted it on their behalf.
  // These mirror the FROM_SUBMISSION guards on the Approve / ApproveOverride /
  // Reject rules in OC_TS_TRANSITION -- if the two ever disagree, the screen
  // offers something the database will refuse.
  const REACHED_MANAGER = ['Submitted', 'LateSubmission', 'Defaulted'];

  /**
   * PAGE-005 Approval Detail — page module functions.
   */
  class PageModule {

    /**
     * ACT-019: the weeks awaiting THIS MANAGER's decision.
     *
     * This used to be "anything not yet settled" — every week whose status was
     * not Approved / Overridden and approved / Closed. That was right while
     * 'Pending' could only mean "submitted, waiting on the manager".
     *
     * Under V4 it is not. APPROVAL_STATUS is 'Pending' on a week nobody has
     * submitted, so the old filter swept those in and the button offered to
     * "Approve all 5 pending weeks" on a screen showing four Not yet submitted
     * and one Rejected. Clicking it now raises -20034 from the engine, which
     * is the database refusing something the screen should never have offered.
     *
     * Rejected is excluded for the same reason from the other side: it is a
     * decision already taken, not one outstanding.
     */
    pendingWeeks(weeks) {
      return (weeks || []).filter((w) =>
        w.approvalStatus === 'Pending' &&
        REACHED_MANAGER.indexOf(w.submissionStatus) !== -1);
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

    /**
     * Label for the change-history toggle.
     *
     * Carries the count, so an untouched week and a heavily corrected one are
     * distinguishable without opening either — which is most of the value the
     * panel had when it was always expanded, at none of the height.
     */
    historyToggleLabel(open, rows) {
      const n = (rows && rows.length) || 0;
      if (open) { return 'Hide history'; }
      if (n === 0) { return 'No changes'; }
      return 'Show ' + n + (n === 1 ? ' change' : ' changes');
    }

    /**
     * Tooltip for the "+n other" chip on a week that spans projects.
     *
     * The figures on this screen are scoped to the project the manager opened,
     * but approve_week fires the event against the WEEK and cascades to every
     * day in it — there is one APPROVAL_STATUS per week, not one per project.
     * So approving here settles the employee's hours on the other projects too,
     * and this is the only place that says so.
     */
    otherProjectsHint(otherProjects) {
      if (!otherProjects) { return ''; }
      return 'This week also has hours on ' + otherProjects +
             '. Approving or rejecting it here applies to those too — ' +
             'the week is approved as a whole.';
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

    /**
     * The same gate as canApprove/canReject, one level up.
     *
     * A week that is Approved, Overridden and approved, Closed or Rejected has
     * had its decision taken; approving or rejecting it again is either a no-op
     * or a second decision on top of the first, and neither is what the manager
     * means. Undoing it is what they mean, so that is the button that lights up.
     */
    _selectedWeeks(weeks, keys) {
      const picked = keys || [];
      return (weeks || []).filter((w) => picked.indexOf(w.tsWeekId) >= 0);
    }

    /**
     * Whether Approve / Reject should light up for the current selection.
     *
     * Uses the SAME test as pendingWeeks, deliberately: the button that acts on
     * a selection and the button that acts on all of them must agree about what
     * is decidable, or one of them offers something the other refuses. This
     * read "not settled and not Rejected", which excluded a decided week but
     * still lit up for one nobody had submitted.
     */
    canDecideWeeks(weeks, keys) {
      return this.pendingWeeks(this._selectedWeeks(weeks, keys)).length > 0;
    }

    canRevokeWeeks(weeks, keys) {
      return this._selectedWeeks(weeks, keys)
                 .some((w) => w.weekStatus === 'Approved'
                           || w.weekStatus === 'Overridden and approved'
                           || w.weekStatus === 'Rejected');
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

    /**
     * What the selected dates are actually in, so a button that cannot do
     * anything is disabled rather than left to fail at the server.
     *
     * Selection-count alone was the only gate before, so after rejecting seven
     * days both Approve dates and Reject dates stayed live on those same seven
     * — Reject would re-reject days already rejected, and nothing on the screen
     * said the decision had been taken. The rules apply per selection, not per
     * week: a mixed selection is normal, and anything that has work to do for
     * at least one of the selected days stays enabled.
     */
    _selected(days, selectedDates) {
      const picked = selectedDates || [];
      return (days || []).filter((d) => picked.indexOf(d.entryDate) >= 0);
    }

    /**
     * Something in the selection has no decision on it yet.
     *
     * One test for both buttons, on purpose. Approving a day that is already
     * rejected is a second decision layered on the first rather than a
     * correction of it - the rejection stays in OC_TS_APPROVAL either way, and
     * the employee has already been told to fix the day. Undo it first; that is
     * what the Undo button is for.
     */
    canDecide(days, selectedDates) {
      return this._selected(days, selectedDates)
                 .some((d) => d.dayStatus !== 'Approved' && d.dayStatus !== 'Rejected');
    }

    /** Something in the selection has a decision on it to undo. */
    canRevoke(days, selectedDates) {
      return this._selected(days, selectedDates)
                 .some((d) => d.dayStatus === 'Approved' || d.dayStatus === 'Rejected');
    }

    /**
     * Date column for the activity list.
     *
     * A DAY event names its day; a WEEK or MONTH decision has no entry_date at
     * all, and an empty cell there reads as data that failed to load rather than
     * as an event that is simply not about one day.
     */
    activityDate(row) {
      if (!row) { return ''; }
      if (row.entryDate) { return this.fmtDateSafe(row.entryDate); }
      return row.scope === 'MONTH' ? 'Whole month' : 'Whole week';
    }

    /** fmtDate lives on the application module; this keeps the guard local. */
    fmtDateSafe(d) {
      if (!d) { return ''; }
      const parts = String(d).substring(0, 10).split('-');
      if (parts.length !== 3) { return String(d); }
      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      const m = Number(parts[1]);
      return parts[2] + '-' + (months[m - 1] || parts[1]) + '-' + parts[0];
    }

    /**
     * Chip class for an activity row, so a rejection is not the same colour as
     * an import. Reuses the status palette already defined in shell-page.html
     * rather than a second set of names for the same six colours.
     */
    activityClass(row) {
      const t = (row && row.changeType) || '';
      if (t === 'Reject')  { return 'rw-status rw-status-rejected'; }
      if (t === 'Approve' || t === 'AdvanceApprove' || t === 'Confirm') {
        return 'rw-status rw-status-approved';
      }
      if (t === 'Submit' || t === 'Resubmit') { return 'rw-status rw-status-submitted'; }
      return 'rw-status rw-status-notsubmitted';
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
