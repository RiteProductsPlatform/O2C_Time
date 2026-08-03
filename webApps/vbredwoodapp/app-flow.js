/* Copyright (c) 2026, Oracle and/or its affiliates */

define(['oj-sp/spectra-shell/config/config'], function () {
  'use strict';

  /**
   * O2C Timesheet Module — application module.
   *
   * Everything here is a pure display or payload helper reachable from any page
   * as $application.functions.<name>(). It lives at application scope so the 11
   * pages share one implementation of the status vocabulary, the flag chips and
   * the ORDS date format instead of each re-deriving them.
   *
   * No business rule is decided here. Rules are enforced in OC_TIME_PKG and as
   * table constraints; these helpers only present what the server already
   * decided, so a caller hitting ORDS directly gets the identical answer.
   */
  class AppModule {

    // ── Status (7, revised 30-Jul-2026) ────────────────────────

    /**
     * Maps a week status to its capsule class. The status text is always
     * rendered alongside, so colour is never the only carrier of meaning.
     *
     * @param {string} status WEEK_STATUS as stored
     * @return {string}
     */
    statusClass(status) {
      switch (status) {
        case 'Not yet submitted':       return 'rw-status rw-status-notsubmitted';
        case 'Submitted':               return 'rw-status rw-status-submitted';
        case 'Approved':                return 'rw-status rw-status-approved';
        case 'Rejected':                return 'rw-status rw-status-rejected';
        case 'Defaulted':               return 'rw-status rw-status-defaulted';
        case 'Overridden and approved': return 'rw-status rw-status-overridden';
        case 'Closed':                  return 'rw-status rw-status-closed';
        default:                        return 'rw-status rw-status-notsubmitted';
      }
    }

    // ── Flags (6, revised 30-Jul-2026) ─────────────────────────

    /**
     * The flags set on a week row, as chips.
     *
     * Flags are independent of status and several can be true at once, which is
     * why this returns a list rather than one value. Reads both ORDS casings.
     *
     * Defaulted is reported with its cause: a week defaulted because the manager
     * missed the delivery cut-off is not the employee's failure, and salary
     * stopping treats the two differently.
     *
     * @param {Object} row a week row from any of the week feeds
     * @return {Array<{label:string, cls:string, title:string}>}
     */
    weekFlags(row) {
      const r = row || {};
      const on = (a, b) => (r[a] || r[b]) === 'Y';
      const by = (r.defaulted_by || r.DEFAULTED_BY || '').toUpperCase();
      const chips = [];

      if (on('defaulted_flag', 'DEFAULTED_FLAG')) {
        chips.push({
          label: by === 'MANAGER' ? 'Defaulted (manager)'
               : by === 'EMPLOYEE' ? 'Defaulted (employee)'
               : 'Defaulted',
          cls: 'rw-flag rw-flag-defaulted',
          title: by === 'MANAGER'
            ? 'The delivery cut-off passed without a manager decision. The week is not locked and can still be approved.'
            : 'The weekly cut-off passed without a submission. Default hours were applied and the week is locked to the employee.',
        });
      }
      if (on('late_submission_flag', 'LATE_SUBMISSION_FLAG')) {
        chips.push({
          label: 'Late submission',
          cls: 'rw-flag rw-flag-late',
          title: 'Submitted or resubmitted after the weekly cut-off. The status stays Submitted — this records the SLA miss only.',
        });
      }
      if (on('advance_closure_flag', 'ADVANCE_CLOSURE_FLAG')) {
        chips.push({
          label: 'Advance closure',
          cls: 'rw-flag rw-flag-advance',
          title: 'Approved at month level before the work happened (PROC-010).',
        });
      }
      if (on('overridden_flag', 'OVERRIDDEN_FLAG')) {
        chips.push({
          label: 'Overridden & approved',
          cls: 'rw-flag rw-flag-overridden',
          title: 'A manager changed the hours before approving. The original values are retained in the audit trail.',
        });
      }
      if (on('has_reversal_flag', 'HAS_REVERSAL_FLAG')) {
        chips.push({
          label: 'Reversal',
          cls: 'rw-flag rw-flag-reversal',
          title: 'Contains a Reversal(-) entry from a retro adjustment. Reversal rows carry negative hours so they net off against their Adjustment pair.',
        });
      }
      if (on('has_adjustment_flag', 'HAS_ADJUSTMENT_FLAG')) {
        chips.push({
          label: 'Adjustment',
          cls: 'rw-flag rw-flag-adjustment',
          title: 'Contains an Adjustment(+) entry from a retro adjustment.',
        });
      }
      return chips;
    }

    // ── Formatting ─────────────────────────────────────────────

    /**
     * Hours for display. Always two decimals, because quarter-hour blocks
     * (RULE-005) are meaningless at one.
     *
     * @param {number|string} h
     * @return {string}
     */
    fmtHours(h) {
      const n = Number(h);
      return isNaN(n) ? '0.00' : n.toFixed(2);
    }

    /**
     * Hours, but blank instead of 0.00. Used in the grid so an untouched cell
     * reads as empty rather than as a deliberate zero.
     *
     * @param {number|string} h
     * @return {string}
     */
    fmtHoursBlank(h) {
      const n = Number(h);
      return (!h && h !== 0) || isNaN(n) || n === 0 ? '' : n.toFixed(2);
    }

    /**
     * YYYY-MM-DD -> DD-Mon. Column headers only; the full date is in the title
     * attribute so the year is never actually lost.
     *
     * @param {string} d
     * @return {string}
     */
    fmtDayShort(d) {
      if (!d) return '';
      const parts = String(d).substring(0, 10).split('-');
      if (parts.length !== 3) return String(d);
      const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return parts[2] + '-' + (MON[parseInt(parts[1], 10) - 1] || parts[1]);
    }

    /**
     * YYYY-MM-DD -> DD-Mon-YYYY, matching appDateDisplay.
     *
     * @param {string} d
     * @return {string}
     */
    fmtDate(d) {
      if (!d) return '';
      const s = String(d).substring(0, 10);
      const parts = s.split('-');
      if (parts.length !== 3) return String(d);
      return this.fmtDayShort(s) + '-' + parts[0];
    }

    /**
     * Date-only string for an ORDS write.
     *
     * Oracle ORDS backed by the database expects a time component; a bare
     * YYYY-MM-DD is answered with a 400 carrying no useful message. Applied at
     * the moment the body is built, never to the stored variable, so the page
     * keeps working with plain dates.
     *
     * @param {string} d
     * @return {string}
     */
    toApiDate(d) {
      return (d && String(d).length === 10) ? d + 'T00:00:00Z' : d;
    }

    /**
     * The reason a REST failure happened, in words a user can act on.
     *
     * The ORDS handlers return the business rule's own message in `error`, which
     * is already user-facing, so it is preferred over anything generic. Falls
     * back through the standard ORDS error shape and finally to the status.
     *
     * @param {Object} response a callRest result
     * @return {string}
     */
    restError(response) {
      const r = response || {};
      const b = r.body || {};
      const msg = b.error || b.message || b.title || r.statusText || '';

      if (r.status === 401) return 'Your session has expired. Please sign in again.';
      if (r.status === 403) return 'You are not authorized to perform this action.';
      if (r.status === 404) return 'That record no longer exists. Refresh and try again.';
      if (r.status >= 500)  return 'The timesheet service failed' + (msg ? ': ' + msg : '. Please contact support.');

      return msg || 'The request was refused (' + (r.status || 'no status') + ').';
    }

    // ── Binding helpers ────────────────────────────────────────
    // S1 forbids conditional logic, concatenation and arithmetic inside [[ ]].
    // These take the raw value plus the two literal outcomes, so a binding stays
    // a single function call while the decision lives in testable JS.

    /**
     * Pick between two literals on a Y/N flag.
     *
     * @param {string} flag 'Y' or anything else
     * @param {string} whenY
     * @param {string} whenN
     * @return {string}
     */
    yesNo(flag, whenY, whenN) {
      return flag === 'Y' ? whenY : whenN;
    }

    /**
     * Pick between two literals on an equality test.
     *
     * @param {*} value
     * @param {*} match
     * @param {string} whenEqual
     * @param {string} otherwise
     * @return {string}
     */
    ifEq(value, match, whenEqual, otherwise) {
      return value === match ? whenEqual : otherwise;
    }

    /**
     * Pick between two literals on truthiness.
     *
     * @param {*} value
     * @param {string} whenTruthy
     * @param {string} whenFalsy
     * @return {string}
     */
    ifSet(value, whenTruthy, whenFalsy) {
      return value ? whenTruthy : whenFalsy;
    }

    /**
     * The icon a button shows while an action is in flight.
     *
     * @param {boolean} busy
     * @param {string} idleIcon
     * @return {string}
     */
    busyIcon(busy, idleIcon) {
      return busy ? 'oj-ux-ico-progress-circle oj-animation-spin' : idleIcon;
    }

    /**
     * Capsule class for the simple Approved / Rejected / in-progress statuses
     * used by adjustments, month rollups, coverage and salary holds. Distinct
     * from statusClass(), which maps the 7 week statuses.
     *
     * @param {string} status
     * @return {string}
     */
    outcomeClass(status) {
      if (status === 'Approved' || status === 'Released') {
        return 'rw-status rw-status-approved';
      }
      if (status === 'Rejected' || status === 'Held') {
        return status === 'Held' ? 'rw-status rw-status-defaulted'
                                 : 'rw-status rw-status-rejected';
      }
      if (status === 'No employees' || status === 'Open') {
        return 'rw-status rw-status-notsubmitted';
      }
      return 'rw-status rw-status-submitted';
    }

    /**
     * True for the aborted-fetch errors JET raises during normal rendering.
     *
     * JET cancels in-flight requests when a component re-renders, which surfaces
     * as an AbortError in the chain's catch block. It is not a failure and must
     * not be reported: telling a user "the service is unreachable" because a
     * table re-rendered is worse than saying nothing.
     *
     * @param {Error} e
     * @return {boolean}
     */
    isAbortError(e) {
      if (!e) { return false; }
      return e.name === 'AbortError' ||
             (typeof e.message === 'string' &&
              e.message.indexOf('Aborting stale fetch') !== -1);
    }

    /**
     * Message for an exception thrown out of callRest.
     *
     * A thrown callRest is not always a dead back end. When VB cannot resolve
     * the operation against the service definition it throws "unable to find
     * endpoint ..." — the server was never contacted at all. Reporting that as
     * "the timesheet service is unavailable" sent a whole debugging session
     * after ORDS while ORDS was answering every request in under a second; the
     * real fault was the spec not loading in the browser.
     *
     * Callers pass their own wording as the fallback, so a genuine outage still
     * reads the way it always did.
     */
    chainError(e, fallback) {
      const msg = (e && typeof e.message === 'string') ? e.message : '';

      if (msg.indexOf('unable to find endpoint') !== -1 ||
          msg.indexOf('Unable to find endpoint') !== -1) {
        return 'The app could not resolve this REST operation, so no request ' +
               'was sent. The service definition failed to load — check the ' +
               'browser console for a service load error. This is a front-end ' +
               'configuration problem, not a back-end outage.';
      }

      return fallback || 'Something went wrong. Please try again shortly.';
    }

    /**
     * Heading to go with chainError(). Kept separate so the summary never
     * contradicts the body — "Service unavailable" above a message explaining
     * that no request was sent is worse than no heading at all.
     */
    chainSummary(e, fallback) {
      const msg = (e && typeof e.message === 'string') ? e.message : '';
      if (msg.toLowerCase().indexOf('unable to find endpoint') !== -1) {
        return 'App configuration problem';
      }
      return fallback || 'Something went wrong';
    }

    /**
     * Correlation id for a write, so one user action can be followed across
     * VBCS -> ORDS -> OIC (OBS-001..008, NFR-011).
     *
     * @return {string}
     */
    newTraceId() {
      return 'vb-' + Date.now().toString(36) + '-' +
             Math.floor(Math.random() * 1e6).toString(36);
    }
  }

  return AppModule;
});
