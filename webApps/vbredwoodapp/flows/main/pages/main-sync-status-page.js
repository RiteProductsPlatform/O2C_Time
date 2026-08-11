define([], () => {
  'use strict';

  /** PAGE-010 Sync Status — page module functions. */
  class PageModule {

    /**
     * Human-readable job duration.
     *
     * Raw milliseconds are unreadable at the scale these jobs run (a monthly
     * population over a few hundred workers is minutes, not milliseconds), and
     * NFR-003 is about whether the job fits its window — which is a question
     * about minutes.
     */
    durationText(ms) {
      const n = Number(ms);
      if (!n || n < 0) { return '—'; }
      if (n < 1000)    { return n + ' ms'; }

      const secs = Math.round(n / 1000);
      if (secs < 60)   { return secs + ' s'; }

      const mins = Math.floor(secs / 60);
      const rem  = secs % 60;
      if (mins < 60)   { return mins + 'm ' + rem + 's'; }

      const hrs = Math.floor(mins / 60);
      return hrs + 'h ' + (mins % 60) + 'm';
    }

    /** Capsule class for a job outcome. */
    jobStatusClass(jobStatus) {
      if (jobStatus === 'Success')  { return 'rw-status rw-status-approved'; }
      if (jobStatus === 'Failed')   { return 'rw-status rw-status-rejected'; }
      if (jobStatus === 'Partial')  { return 'rw-status rw-status-defaulted'; }
      return 'rw-status rw-status-submitted';
    }

    /** Highlights a non-zero failure count. */
    failedClass(recordsFailed) {
      return Number(recordsFailed) > 0 ? 'rw-grid-total-over' : '';
    }

    /** Accessible name for a failed record's retry button. */
    retryLabel(entityKey) {
      return 'Retry ' + entityKey;
    }

    /**
     * Chip class for a period's stored status. Open and Closed are the only
     * two values chk_oc_tp_status allows — there is no 'Future' — so this
     * says nothing about whether the month has started. That is phaseText.
     */
    periodStatusClass(status) {
      return status === 'Open'
        ? 'rw-status rw-status-approved'
        : 'rw-status rw-status-rejected';
    }

    /**
     * Where the month sits against today, derived in the view from its dates
     * rather than from STATUS. A Future month reading Closed is correct and
     * this is what tells the admin so.
     */
    phaseText(phase) {
      return phase || '';
    }

    /** Why a period cannot be closed yet, for the button's accessible name. */
    closeBlockedLabel(periodName, unconfirmed) {
      return Number(unconfirmed) > 0
        ? 'Cannot close ' + periodName + ' — ' + unconfirmed +
          ' project(s) not yet confirmed to accrual'
        : 'Close ' + periodName;
    }

  }

  return PageModule;
});
