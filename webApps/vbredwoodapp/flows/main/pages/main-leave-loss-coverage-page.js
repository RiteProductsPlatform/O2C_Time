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

  }

  return PageModule;
});
