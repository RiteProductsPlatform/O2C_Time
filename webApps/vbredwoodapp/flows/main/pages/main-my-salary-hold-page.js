define([], () => {
  'use strict';

  /**
   * PROC-007 — the employee's own held dates. Pure display helpers only;
   * everything that talks to ORDS is in an action chain.
   */
  class PageModule {

    /**
     * The banner sentence.
     *
     * Three states, and the difference between them is the whole point of the
     * page. "Your pay is held" with no deadline is frightening and useless;
     * "6 days left" is what makes somebody act today.
     */
    bannerMessage(openCount, daysLeft, windowClosed, loaded, total) {
      if (!loaded) { return ''; }
      if (!total) {
        return 'Nothing is held. Your timesheets were submitted before the '
             + 'payroll cut-off.';
      }
      if (windowClosed) {
        return 'The 60-day correction window has closed on every date below, '
             + 'so these can no longer be corrected here. Contact payroll.';
      }
      const d = Number(daysLeft) || 0;
      return openCount + (openCount === 1 ? ' date is' : ' dates are')
           + ' holding part of your pay. '
           + (d === 0
              ? 'The correction window closes today.'
              : d === 1 ? 'You have 1 day left to correct them.'
                        : 'You have ' + d + ' days left to correct them.');
    }

    /**
     * Banner tone. Reuses rw-notice / rw-notice-warning rather than inventing
     * rw-banner-*: deleting shell-page.css in the restructure silently orphaned
     * 22 classes once, and every rw- class used has to be defined somewhere.
     */
    bannerClass(windowClosed, loaded, total) {
      if (!loaded || !total) { return 'rw-notice'; }
      return 'rw-notice rw-notice-warning';
    }

    /** Status capsule, reusing the module's vocabulary. */
    dayStatusClass(status) {
      switch (status) {
        case 'Held':      return 'rw-status rw-status-defaulted';
        case 'Corrected': return 'rw-status rw-status-submitted';
        case 'Approved':  return 'rw-status rw-status-approved';
        case 'Rejected':  return 'rw-status rw-status-rejected';
        case 'Expired':   return 'rw-status rw-status-closed';
        default:          return 'rw-status rw-status-notsubmitted';
      }
    }

    /**
     * What this row means, in a sentence. The status word alone does not tell
     * an employee whether they still have to do something.
     */
    dayStatusHint(status, windowOpen) {
      switch (status) {
        case 'Held':
          return windowOpen === 'Y'
            ? 'Not submitted. Open the week and resubmit it.'
            : 'Not submitted, and the window has closed. Contact payroll.';
        case 'Corrected': return 'Resubmitted — waiting for your manager.';
        case 'Approved':  return 'Approved. This date no longer holds your pay.';
        case 'Rejected':  return 'Sent back by your manager. Correct it and resubmit.';
        case 'Expired':   return 'The 60-day window closed before this was corrected.';
        default:          return '';
      }
    }

    /** Only a row the employee can still act on gets a button. */
    canReopen(windowOpen) {
      return windowOpen === 'Y';
    }

    /** Accessible label — "Open week" repeated down a column says nothing. */
    reopenLabel(workDate) {
      return 'Open the timesheet week containing ' + (workDate || 'this date');
    }
  }

  return PageModule;
});
