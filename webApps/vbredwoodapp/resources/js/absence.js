/**
 * resources/js/absence.js — the live Fusion absence read, in one place.
 *
 * TWO SCREENS ASK FUSION THE SAME QUESTION and until 20-Aug-2026 only one of
 * them asked at all:
 *
 *   PAGE-001 My Timesheet        one person, one week   (refreshAbsenceChain)
 *   PAGE-006 Leave Loss Coverage every person on a       (refreshHrAbsenceChain)
 *                                project, one month
 *
 * PAGE-006 read OC_TIME_ABSENCE — our cache — and called it a refresh. So leave
 * applied in Fusion stayed invisible to the manager until either the nightly
 * feed ran or the absent person happened to open their own timesheet. Measured
 * 20-Aug: RI2894's approved 20-Aug leave was live in Fusion, absent from
 * OC_TIME_ABSENCE, and therefore missing from the coverage list its manager
 * works from.
 *
 * Both callers now come through here, so the query syntax, the day expansion
 * and the status mapping cannot drift apart between them — which matters
 * because every one of those three has already been wrong once.
 *
 * WHY A RESOURCE MODULE RATHER THAN $application.functions: these are used by
 * CHAINS, which can require a module by path but reach application functions
 * only through a context they may not have; and keeping them out of app scope
 * avoids the ArrayDataProvider2 class of app-variable initialisation problem
 * the shell already documents.
 */
define([], () => {
  'use strict';

  return {

    /**
     * The Fusion `q` for an absence read.
     *
     * ' and ', NOT ';'. THIS IS THE REVERSE OF WHAT THIS CODE SAID UNTIL TODAY.
     *
     * refreshAbsenceChain carried a measured-looking comment asserting that
     * ' AND ' returns 500 and ';' returns 200, dated 12-Aug-2026. Re-measured
     * against the same pod on 20-Aug, every combination is the other way round:
     *
     *   personId=<id>;endDate>='2026-08-01';startDate<='2026-08-31'      400
     *   personId=<id> and endDate>='2026-08-01' and startDate<='2026-08-31'  200
     *   personId IN (<id>,<id>) and endDate>=... and startDate<=...          200
     *
     * URL-encoded or raw, the ';' form fails identically, so this is Fusion's
     * ViewCriteria parser and not a transport artefact. A single predicate
     * works either way, which is what made the wrong version look right for as
     * long as it did.
     *
     * The consequence was invisible rather than loud: the chain treats a failed
     * read as non-fatal by design, so every live refresh had been quietly
     * warning and leaving the last-known leave on screen.
     *
     * The window test is OVERLAP, not containment — leave that began before
     * the window and runs into it still puts leave on these days.
     *
     * Verify after any change by asking for a window that must be empty
     * (September, here) and checking that it really is: a predicate Fusion
     * ignores returns 200 with everything in it, which reads as success.
     */
    absenceQuery(personIds, from, to) {
      const ids = (Array.isArray(personIds) ? personIds : [personIds])
        .filter((x) => x !== undefined && x !== null && x !== '');
      if (!ids.length) { return null; }

      const who = ids.length === 1
        ? 'personId=' + ids[0]
        : 'personId IN (' + ids.join(',') + ')';

      return who + " and endDate>='" + from + "' and startDate<='" + to + "'";
    },

    /** The `q` that resolves employee numbers to Fusion PersonIds in one call. */
    workerQuery(employeeIds) {
      const ids = (Array.isArray(employeeIds) ? employeeIds : [employeeIds])
        .filter(Boolean);
      if (!ids.length) { return null; }
      if (ids.length === 1) { return "PersonNumber='" + ids[0] + "'"; }
      return 'PersonNumber IN (' + ids.map((e) => "'" + e + "'").join(',') + ')';
    },

    /**
     * approvalStatusCd -> our APPROVAL_STATUS.
     *
     * NULL WHEN FUSION DID NOT SAY, NOT 'Pending'.
     *
     * This read String(x.approvalStatusCd).toUpperCase() === 'APPROVED'
     * ? 'Approved' : 'Pending' — so a missing field became String(undefined)
     * === 'UNDEFINED', which is not 'APPROVED', which became a positive claim
     * that the absence is NOT approved.
     *
     * That claim is destructive. v_oc_ts_leave_share only counts Approved
     * absences, so the retract half of oc_time_sync_leave sees no share behind
     * the leave rows, deletes them with an AbsenceSync audit row saying the
     * absence was withdrawn — which nobody did — and db/80 then hands the
     * worked hours back. One page load and the leave is gone from the
     * timesheet while Fusion still shows it.
     *
     * The handler already does the right thing with a null:
     * NVL(r.approval_status,'Approved'). Silence has to stay silence so that
     * default can apply. A real non-approved status still maps to Pending and
     * still blocks — that part was never wrong.
     */
    approvalOf(cd) {
      if (cd === undefined || cd === null || String(cd).trim() === '') {
        return null;
      }
      return String(cd).toUpperCase() === 'APPROVED' ? 'Approved' : 'Pending';
    },

    /**
     * Fusion absence headers -> one sync row per calendar day in the window.
     *
     * EVERY Date HERE IS PINNED TO UTC — the 'Z' suffix and the setUTCDate walk
     * below are both load-bearing, not tidiness.
     *
     * These are CALENDAR DATES, not instants. Without the 'Z', JavaScript
     * parses '2026-08-14T00:00:00' in the BROWSER's zone, and toISOString()
     * then converts to UTC: at UTC+5:30 that is 2026-08-13T18:30Z, and
     * substring(0,10) yields '2026-08-13'. Leave applied for Friday landed on
     * Thursday — measured 12-Aug-2026, and the shift is silent because every
     * date involved is still a valid date.
     *
     * The failure is timezone-dependent, which is what makes it nasty: it never
     * appears for a viewer at or behind UTC, so it cannot be reproduced from
     * London and is guaranteed from India.
     *
     * @param items  Fusion absence headers
     * @param employeeId  who they belong to — the caller groups by person
     * @param from,to  the window, as YYYY-MM-DD
     * @param stdHoursPerDay  THAT person's standard day, not a global 8
     */
    absenceToRows(items, employeeId, from, to, stdHoursPerDay) {
      const std = Number(stdHoursPerDay) || 8;
      const lo = new Date(from + 'T00:00:00Z');
      const hi = new Date(to + 'T00:00:00Z');
      const out = [];
      const self = this;

      (items || []).forEach((x) => {
        const s = new Date(String(x.startDate).substring(0, 10) + 'T00:00:00Z');
        const e = new Date(String(x.endDate).substring(0, 10) + 'T00:00:00Z');
        if (isNaN(s) || isNaN(e)) { return; }

        const whole = Math.round((e - s) / 86400000) + 1;
        const days = Number(x.duration) || whole;
        const perDay = whole ? days / whole : 0;

        const start = s > lo ? s : lo;
        const end = e < hi ? e : hi;

        // setUTCDate / getUTCDate, not setDate / getDate. The local-zone pair
        // would walk the calendar in the browser's zone while toISOString()
        // reads it back in UTC, reintroducing the same off-by-one on the second
        // and later days of a multi-day absence.
        for (let d = new Date(start); d <= end; d.setUTCDate(d.getUTCDate() + 1)) {
          out.push({
            EMPLOYEE_ID: employeeId,
            ABSENCE_DATE: d.toISOString().substring(0, 10),
            // TRIMMED. Fusion returns "Earned leave " with a trailing space on
            // this pod — measured 12-Aug-2026, and invisible everywhere it is
            // displayed because both the Fusion screen and the grid collapse
            // it. Untrimmed it reaches OC_TIME_ABSENCE.ABSENCE_TYPE and then
            // OC_TS_ENTRY.ABSENCE_TYPE, where nothing compares it today and the
            // first thing that does — a lookup join, a report filter, a GROUP
            // BY against 'Earned leave' — fails silently and looks like missing
            // data rather than a whitespace mismatch.
            ABSENCE_TYPE: String(x.absenceType || 'Leave').trim() || 'Leave',
            // CHK_OC_TABS_HRS caps the column at 24
            DURATION_HOURS: Math.round(Math.min(perDay * std, 24) * 100) / 100,
            APPROVAL_STATUS: self.approvalOf(x.approvalStatusCd),
            // WITHDRAWAL IS NOT VISIBLE IN approvalStatusCd. Fusion leaves a
            // withdrawn absence APPROVED there and marks it ORA_WITHDRAWN in
            // absenceStatusCd, so on approval status alone a cancelled leave
            // reads as an approved one and the day stays blocked.
            ABSENCE_STATUS: String(x.absenceStatusCd || '').toUpperCase(),
          });
        }
      });

      return out;
    },

    /** The field list both reads need. absenceStatusCd is not optional — see above. */
    ABSENCE_FIELDS: 'personId,startDate,endDate,duration,absenceType,'
                  + 'absenceStatusCd,approvalStatusCd',
  };
});
