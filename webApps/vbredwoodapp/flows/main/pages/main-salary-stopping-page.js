define([], () => {
  'use strict';

  /** PAGE-007 Salary Stopping — page module functions. */
  class PageModule {

    /** Accessible name for the weeks-breakdown button. */
    weeksLabel(employeeName) {
      return 'Weeks for ' + employeeName;
    }

    /** Accessible name for the correct-defaulted-week button. */
    correctLabel(employeeName) {
      return 'Correct the defaulted week for ' + employeeName;
    }

    /** Accessible name for the release-hold button. */
    releaseLabel(employeeName) {
      return 'Release the hold for ' + employeeName;
    }

    /**
     * Second line under the employee name: id, plus the worker type when it is
     * something other than a plain employee.
     */
    employeeMeta(row) {
      if (!row) { return ''; }
      return row.workerType === 'Contractor'
        ? row.employeeId + ' · Contractor'
        : row.employeeId;
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
