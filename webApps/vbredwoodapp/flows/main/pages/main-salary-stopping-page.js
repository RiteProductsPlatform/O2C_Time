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
  }

  return PageModule;
});
