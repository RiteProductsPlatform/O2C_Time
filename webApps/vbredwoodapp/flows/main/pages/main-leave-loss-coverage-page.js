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
