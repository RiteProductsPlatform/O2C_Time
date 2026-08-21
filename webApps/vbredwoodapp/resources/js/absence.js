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
     * The Fusion `q` for an absence read. NO SPACES, AND NO DATE PREDICATE.
     *
     * THREE MEASUREMENTS, TWO PATHS, AND THEY DISAGREE BECAUSE THEY ARE NOT THE
     * SAME REQUEST.
     *
     * The browser reaches Fusion through the VB `fa` backend, which is a
     * server-side proxy. Direct curl does not. Measured 20-Aug against the same
     * pod on the same day:
     *
     *                                          direct   via the VB proxy
     *   personId=<id>;endDate>='…';…             400          200
     *   personId=<id> and endDate>='…' and …     200          500
     *
     * Neither column is wrong. A `q` containing a SPACE does not survive the
     * proxy, and a `q` containing a `;` does not survive Fusion's ViewCriteria
     * parser -- `;` is a matrix-parameter separator, so the proxy path almost
     * certainly delivers only `q=personId=<id>` and Fusion answers 200 with the
     * person's ENTIRE absence history. That 200 is why the `;` version looked
     * healthy for weeks: absenceToRows clamps to the window afterwards, so the
     * screen was right while the query was not.
     *
     * A comment here asserted the second row as a universal fact on 12-Aug and
     * I overwrote it with the first on 20-Aug. Both of us measured one path and
     * wrote it down as the truth.
     *
     * SO THE PREDICATE FILTERS BY PERSON ONLY, and by a form with no space in
     * it -- `IN(a,b)`, not `IN (a,b)`. The window is applied in absenceToRows,
     * which was already clamping every generated day to it, so nothing about
     * the result changes. The date predicate was an optimisation; it was never
     * what made the answer correct.
     *
     * The cost is that Fusion returns the whole history for the people asked
     * about. That is fine for a person or a project team, and wasTruncated()
     * below is what keeps it honest when it is not.
     */
    absenceQuery(personIds) {
      const ids = (Array.isArray(personIds) ? personIds : [personIds])
        .filter((x) => x !== undefined && x !== null && x !== '');
      if (!ids.length) { return null; }

      return ids.length === 1
        ? 'personId=' + ids[0]
        : 'personId IN(' + ids.join(',') + ')';
    },

    /** The `q` that resolves employee numbers to Fusion PersonIds in one call. */
    workerQuery(employeeIds) {
      const ids = (Array.isArray(employeeIds) ? employeeIds : [employeeIds])
        .filter(Boolean);
      if (!ids.length) { return null; }
      // IN(...), not IN (...) -- same no-space rule as above.
      return ids.length === 1
        ? "PersonNumber='" + ids[0] + "'"
        : 'PersonNumber IN(' + ids.map((e) => "'" + e + "'").join(',') + ')';
    },

    /**
     * Did Fusion have more rows than it gave us?
     *
     * THIS IS A CORRECTNESS GUARD, NOT A NICETY. Both callers post the result
     * as a WINDOWED CLAIM -- employeeId + windowFrom + windowTo, meaning "these
     * are ALL the absences this person has between these dates" -- and the
     * handler deletes anything inside that window it was not sent. That is what
     * makes a cancelled leave retract.
     *
     * A truncated read is indistinguishable from a cancellation. Hitting the
     * limit and posting anyway would delete real, current leave and hand the
     * worked hours back, exactly as if HR had withdrawn it. So a short read
     * must abort the post, not proceed with what it happened to get.
     *
     * `hasMore` survives onlyData=true -- checked, since the flag being
     * stripped by that parameter is precisely the kind of thing that would make
     * this guard silently useless.
     */
    wasTruncated(body) {
      return !!(body && body.hasMore === true);
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

    /**
     * Read HR for a whole project team and write what it says.
     *
     * WHY THIS IS HERE AND NOT IN A CHAIN. Three manager screens need it -- Leave
     * Loss Coverage, Monthly Summary, and Approval Detail behind it -- and a VB
     * action chain belongs to one page. Copying it three times is how the
     * Fusion query came to be wrong in two places at once.
     *
     * IT EXISTS BECAUSE THE MANAGER CANNOT WAIT FOR THE EMPLOYEE. Every manager
     * screen reads OC_TS_ENTRY, which is only current once somebody has synced
     * the absence -- and until now the only things that did were the nightly
     * feed and the ABSENT PERSON opening their own timesheet. So a manager
     * approving a month could be looking at leave that HR changed days ago,
     * with nothing on the screen to say so. Reported 21-Aug: leave withdrawn in
     * Fusion, correct on the employee's timesheet, stale on every screen the
     * manager works from.
     *
     * Two Fusion calls regardless of headcount -- both resources take IN lists,
     * written without the space. The per-person POST is one each, and it goes
     * for EVERYBODY on the roster including those Fusion returned nothing for:
     * employeeId + windowFrom + windowTo makes it a claim rather than a list,
     * and the handler deletes what it was not sent inside that window. Skip the
     * empty ones and a withdrawal never retracts, because "no leave" and "we
     * did not ask" would look the same.
     *
     * Returns {pulled, people, note}. `note` is non-null when the live half
     * could not complete, and the caller decides how loudly to say so -- on
     * PAGE-006 that is a warning beside a list rebuilt from cache, which is a
     * better answer than refusing to show anything.
     */
    async pullForRoster(context, Actions, opts) {
      const $application = context.$application;
      const projectId = opts.projectId;
      const periodId  = opts.periodId;

      const roster = await Actions.callRest(context, {
        endpoint: 'oc_time/getLlcRoster',
        uriParams: { projectId: projectId, periodId: periodId, _t: Date.now() },
      });

      if (!roster.ok) {
        return { pulled: 0, people: 0, note: 'Could not read the project team, '
          + 'so leave was not refreshed from HR. '
          + $application.functions.restError(roster) };
      }

      const people = (roster.body && roster.body.items) || [];
      if (!people.length) {
        return { pulled: 0, people: 0, note: null };   // nobody allocated: nothing to ask
      }

      const from = people[0].window_from;
      const to   = people[0].window_to;
      const empIds = people.map((p) => p.employee_id).filter(Boolean);

      // PersonNumber -> PersonId, one call
      const who = await Actions.callRest(context, {
        endpoint: 'fa_hcm/getWorkers',
        uriParams: {
          q: this.workerQuery(empIds),
          limit: 500, onlyData: true, fields: 'PersonNumber,PersonId',
        },
      });
      // A FAILED CALL AND AN EMPTY RESULT ARE DIFFERENT THINGS: collapsing them
      // reports a stale backend credential as "no such person in Fusion".
      if (!who.ok) {
        return { pulled: 0, people: people.length,
          note: 'Fusion refused the worker lookup (HTTP ' + who.status + ').' };
      }

      const byNumber = {};
      ((who.body && who.body.items) || []).forEach((w) => {
        byNumber[String(w.PersonNumber)] = w.PersonId;
      });

      const personIds = empIds.map((e) => byNumber[e]).filter(Boolean);
      if (!personIds.length) {
        return { pulled: 0, people: people.length,
          note: 'Fusion answered, but none of this project\'s ' + empIds.length
            + ' colleagues could be matched to a person there.' };
      }

      // the live read, one call, by person only -- see absenceQuery
      const res = await Actions.callRest(context, {
        endpoint: 'fa_hcm/getAbsences',
        uriParams: {
          q: this.absenceQuery(personIds),
          limit: 1000, onlyData: true,
          fields: this.ABSENCE_FIELDS,
        },
      });

      if (!res.ok) {
        return { pulled: 0, people: people.length,
          note: 'Fusion refused the absence read (HTTP ' + res.status + ').' };
      }

      // A SHORT READ IS WORSE THAN NO READ. The windowed claim would delete
      // whatever fell off the end, for the whole team at once.
      if (this.wasTruncated(res.body)) {
        return { pulled: 0, people: people.length,
          note: 'Fusion returned only part of this team\'s absence history, so '
            + 'nothing was refreshed rather than risk removing leave that is '
            + 'still live. The read limit needs raising.' };
      }

      // personId comes back a number and the map is keyed by string.
      const byPerson = {};
      ((res.body && res.body.items) || []).forEach((x) => {
        const k = String(x.personId);
        (byPerson[k] = byPerson[k] || []).push(x);
      });

      let sent = 0;
      let failed = 0;

      for (const p of people) {
        const pid = byNumber[p.employee_id];
        if (!pid) { continue; }          // unmatched: claim nothing about them

        const rows = this.absenceToRows(
          byPerson[String(pid)] || [], p.employee_id, from, to,
          p.std_hours_per_day);

        const sync = await Actions.callRest(context, {
          endpoint: 'oc_time/syncAbsence',
          body: {
            actor: $application.variables.currentEmail || 'VBCS_USER',
            final: 'Y',
            traceId: $application.variables.traceId,
            employeeId: p.employee_id,
            windowFrom: from,
            windowTo: to,
            rows: rows,
          },
        });

        if (sync.ok) { sent += 1; } else { failed += 1; }
      }

      return {
        pulled: sent,
        people: people.length,
        note: failed
          ? (sent + ' of ' + (sent + failed) + ' colleagues were refreshed; '
             + 'the rest could not be saved.')
          : null,
      };
    },

    /** The field list both reads need. absenceStatusCd is not optional — see above. */
    ABSENCE_FIELDS: 'personId,startDate,endDate,duration,absenceType,'
                  + 'absenceStatusCd,approvalStatusCd',
  };
});
