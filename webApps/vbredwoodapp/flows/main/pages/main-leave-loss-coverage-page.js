define([], () => {
  'use strict';

  /** PAGE-006 Leave Loss Coverage — page module functions. */
  class PageModule {

    /**
     * Names the absence the assign dialog was opened for.
     *
     * A page function rather than concatenation in the binding: S1 bars string
     * building inside [[ ]].
     */
    absenceLabel(row) {
      if (!row) { return ''; }
      return row.absentEmployeeName + ' · ' + row.absenceDate;
    }

    /** Accessible name for a row's assign button. */
    assignLabel(absentEmployeeName) {
      return 'Assign cover for ' + absentEmployeeName;
    }

    /**
     * The whole absence, beneath the project's share of it.
     *
     * Both numbers matter and they are usually different: the person was away
     * for a day, and this project lost its allocated fraction of that day. When
     * they happen to be equal -- a 100% allocation -- repeating the figure says
     * nothing, so the note becomes the allocation instead, which is the thing
     * that explains why they match.
     */
    absenceNote(row) {
      if (!row) { return ''; }
      const absent = Number(row.absenceHours) || 0;
      const loss = Number(row.lossHours) || 0;
      if (loss <= 0) { return 'not allocated that day'; }
      if (Math.abs(absent - loss) < 0.005) { return 'full allocation'; }
      return 'of ' + absent.toFixed(2) + ' away';
    }

    /**
     * What the Billed chip says.
     *
     * BILLED_FLAG and COVER_HOURS_BILLED can disagree, and the disagreement is
     * the interesting case: a row approved before the billing was wired carries
     * the flag with nothing moved. Saying "Billed" there is a claim about money
     * that is not true.
     */
    billedLabel(row) {
      if (!row) { return ''; }
      const h = row.coverHoursBilled;
      if (h === null || h === undefined) { return 'Not billed'; }
      return Number(h).toFixed(2) + 'h billed';
    }

    billedClass(row) {
      const h = row && row.coverHoursBilled;
      return (h === null || h === undefined)
        ? 'rw-flag rw-flag-defaulted'
        : 'rw-flag rw-flag-adjustment';
    }

    billedTitle(row) {
      const h = row && row.coverHoursBilled;
      return (h === null || h === undefined)
        ? 'Approved, but no hours moved to a billable task — the covering '
          + 'colleague had no non-billable hours on this project that day, or '
          + 'their week had already locked.'
        : 'Moved to a billable task and carried to the invoice annexure (REP-002).';
    }

    /** Names the gap between coverage approved and hours actually recovered. */
    unbilledNote(n) {
      const c = Number(n) || 0;
      return c + (c === 1 ? ' approved cover recovered no hours'
                          : ' approved covers recovered no hours');
    }

    /** Accessible name for a row's approve button. */
    approveLabel(absentEmployeeName) {
      return 'Approve cover for ' + absentEmployeeName;
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
