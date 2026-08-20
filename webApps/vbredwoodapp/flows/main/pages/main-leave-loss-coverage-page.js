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
     * What the annexure chip says.
     *
     * NOT an hours figure, and not the word "billed". Approving coverage moves
     * nothing: it records that this colleague covered this absence, and that
     * statement is what reaches the invoice annexure (REP-002). The chip said
     * "2.00h billed" for one afternoon on 20-Aug and that reading -- that
     * covering somebody makes their hours billable -- is exactly what the
     * functional owner retracted.
     */
    billedLabel(row) {
      if (!row) { return ''; }
      return 'On annexure';
    }

    billedClass(row) {
      return 'rw-flag rw-flag-adjustment';
    }

    billedTitle(row) {
      return 'Named in the invoice annexure (REP-002) as covering this '
           + 'absence. No hours change: the covering colleague\'s time stays '
           + 'unbilled and the absence stays in the leave column.';
    }

    /**
     * Names approved coverage whose absence has since been withdrawn.
     *
     * Worth a banner rather than only a row chip: it is already off the invoice
     * annexure, so nothing is wrong downstream, but the record still says a
     * colleague covered a day nobody was away and only a manager can undo that.
     */
    orphanNote(n) {
      const c = Number(n) || 0;
      return c === 1
        ? '1 approved coverage is for an absence that has since been withdrawn. '
          + 'It no longer reaches the invoice annexure — revoke it to tidy the record.'
        : c + ' approved coverages are for absences that have since been withdrawn. '
          + 'They no longer reach the invoice annexure — revoke them to tidy the record.';
    }

    /** Names absences nobody has been assigned to cover. */
    unbilledNote(n) {
      const c = Number(n) || 0;
      return c + (c === 1 ? ' absence still has no cover'
                          : ' absences still have no cover');
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
