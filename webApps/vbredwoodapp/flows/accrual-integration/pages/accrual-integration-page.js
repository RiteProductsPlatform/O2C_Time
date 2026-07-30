define([], () => {
  'use strict';

  /** PAGE-011 Accrual Integration — page module functions. */
  class PageModule {

    /**
     * Capsule class for a hand-off status.
     *
     * 'Pending' is deliberately not styled as a failure: OTL push (INT-007) is an
     * OIC flow that has not been built yet, so every confirmation legitimately
     * records OTL_STATUS = 'Pending' today.
     */
    handoffClass(status) {
      if (status === 'Success')  { return 'rw-status rw-status-approved'; }
      if (status === 'Failed')   { return 'rw-status rw-status-rejected'; }
      if (status === 'Pending')  { return 'rw-status rw-status-notsubmitted'; }
      return 'rw-status rw-status-submitted';
    }

    /**
     * Chip class for an interface row's entry type.
     *
     * A page function rather than a ternary chain in the binding (S1). Reversal
     * and Adjustment are the retro pair; Default is auto-filled hours.
     */
    entryTypeClass(entryType) {
      switch (entryType) {
        case 'Reversal':   return 'rw-flag rw-flag-reversal';
        case 'Adjustment': return 'rw-flag rw-flag-adjustment';
        case 'Default':    return 'rw-flag rw-flag-defaulted';
        default:           return 'rw-flag rw-flag-advance';
      }
    }

    /** Tooltip naming the batch a row was collected in, if any. */
    batchTitle(batchId) {
      return batchId ? 'Batch ' + batchId : '';
    }

    /** Accessible name for a row's extract button. */
    extractLabel(projectName) {
      return 'Extract for ' + projectName;
    }

  }

  return PageModule;
});
