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
     * The Fusion `q` for one person's absences. ONE PERSON, NO SPACES.
     *
     * THERE IS NO BATCHED FORM THAT SURVIVES THE PROXY. The browser reaches
     * Fusion through the VB `fa` backend, and a `q` containing a SPACE does not
     * come out the other side intact -- measured three ways now:
     *
     *                                            direct   via the VB proxy
     *   personId=<id>;endDate>='…';…               400          200 (unfiltered)
     *   personId=<id> and endDate>='…'             200          500
     *   PersonNumber IN('a','b',…)                 200          200, matches nobody
     *
     * That third row is this fix. `IN(...)` was written without the space after
     * IN and still carries the one BEFORE it -- `PersonNumber IN(` -- which is
     * all it takes. It came back 200 and matched none of the seven people on
     * the project, so the Monthly Summary reported "none of this project's 7
     * colleagues could be matched to a person there" while every one of them
     * exists in Fusion.
     *
     * Every space-free predicate works on both paths, and the only space-free
     * predicate is a single equality. So the roster is read ONE PERSON AT A
     * TIME. That is 2 Fusion calls each rather than 2 for the whole team, which
     * is the price of the proxy and not a design choice; PAGE-001 has always
     * paid it for one person.
     *
     * The obvious way to halve it is open point S-12: OC_TIME_WORKER does not
     * store the Fusion PersonId, so every read pays for a lookup first. Store
     * it and the worker call disappears.
     */
    absenceQuery(personId) {
      if (personId === undefined || personId === null || personId === '') {
        return null;
      }
      return 'personId=' + personId;
    },

    /** One employee number to one PersonId. Space-free, for the reason above. */
    workerQuery(employeeId) {
      if (!employeeId) { return null; }
      return "PersonNumber='" + employeeId + "'";
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
     * TWO FUSION CALLS PER PERSON, not two for the team. An IN list needs a
     * space and no space survives the proxy -- see absenceQuery, where the
     * measurements are. It goes for EVERYBODY on the roster including those
     * Fusion returned nothing for: employeeId + windowFrom + windowTo makes the
     * post a claim rather than a list, and the handler deletes what it was not
     * sent inside that window. Skip the empty ones and a withdrawal never
     * retracts, because "no leave" and "we did not ask" would look the same.
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

      // ONCE PER PROJECT-MONTH, ACROSS PAGES. The marker is an APPLICATION
      // variable, not a page one, so a manager who opens the Monthly Summary
      // and then drills into Approval Detail and Leave Loss Coverage asks HR
      // once, not three times -- and a deep link straight to any of them still
      // asks. Page scope would have re-read the whole team on every hop.
      //
      // opts.force is the Refresh button saying "ask again", which is a
      // different statement from "make sure you have asked".
      const key = projectId + '|' + periodId;
      if (!opts.force && $application.variables.absencePulledKey === key) {
        return { pulled: 0, people: 0, note: null, skipped: true };
      }
      $application.variables.absencePulledKey = key;

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

      let sent = 0;
      let failed = 0;
      let unmatched = 0;

      // ONE PERSON AT A TIME. See absenceQuery: no batched predicate survives
      // the VB proxy, because every one of them needs a space.
      for (const person of people) {
        const empId = person.employee_id;
        if (!empId) { continue; }

        // PersonNumber -> PersonId
        const who = await Actions.callRest(context, {
          endpoint: 'fa_hcm/getWorkers',
          uriParams: {
            q: this.workerQuery(empId),
            limit: 1, onlyData: true, fields: 'PersonNumber,PersonId',
          },
        });

        // A FAILED CALL AND AN EMPTY RESULT ARE DIFFERENT THINGS. Collapsing
        // them reports a stale backend credential as "no such person".
        if (!who.ok) {
          return { pulled: sent, people: people.length,
            note: 'Fusion refused the worker lookup for ' + empId
              + ' (HTTP ' + who.status + '). Leave was not fully refreshed.' };
        }

        const found = (who.body && who.body.items) || [];
        if (!found.length) { unmatched += 1; continue; }
        const personId = found[0].PersonId;

        // the live read for this person
        const res = await Actions.callRest(context, {
          endpoint: 'fa_hcm/getAbsences',
          uriParams: {
            q: this.absenceQuery(personId),
            limit: 500, onlyData: true,
            fields: this.ABSENCE_FIELDS,
          },
        });

        if (!res.ok) {
          return { pulled: sent, people: people.length,
            note: 'Fusion refused the absence read for ' + empId
              + ' (HTTP ' + res.status + '). Leave was not fully refreshed.' };
        }

        // A SHORT READ MUST NOT BE POSTED: the windowed claim below would
        // delete whatever fell off the end, which is indistinguishable from a
        // cancellation.
        if (this.wasTruncated(res.body)) {
          return { pulled: sent, people: people.length,
            note: 'Fusion returned only part of ' + empId + "'s absence history, "
              + 'so nothing further was refreshed rather than risk removing '
              + 'leave that is still live.' };
        }

        const rows = this.absenceToRows(
          (res.body && res.body.items) || [], empId, from, to,
          person.std_hours_per_day);

        // POSTED EVEN WHEN EMPTY. employeeId + windowFrom + windowTo makes this
        // a claim rather than a list, and the handler deletes what it was not
        // sent inside that window. Skip the empty ones and a withdrawal never
        // retracts, because "no leave" and "we did not ask" would look alike.
        const sync = await Actions.callRest(context, {
          endpoint: 'oc_time/syncAbsence',
          body: {
            actor: $application.variables.currentEmail || 'VBCS_USER',
            final: 'Y',
            traceId: $application.variables.traceId,
            employeeId: empId,
            windowFrom: from,
            windowTo: to,
            rows: rows,
          },
        });

        if (sync.ok) { sent += 1; } else { failed += 1; }
      }

      let note = null;
      if (failed) {
        note = sent + ' of ' + (sent + failed)
             + ' colleagues were refreshed; the rest could not be saved.';
      } else if (unmatched === people.length) {
        note = 'Fusion answered, but none of this project\'s ' + people.length
             + ' colleagues could be matched to a person there.';
      } else if (unmatched) {
        note = unmatched + ' of ' + people.length
             + ' colleagues could not be matched to a person in Fusion; the '
             + 'rest were refreshed.';
      }

      return { pulled: sent, people: people.length, note: note };
    },

    /** The field list both reads need. absenceStatusCd is not optional — see above. */
    ABSENCE_FIELDS: 'personId,startDate,endDate,duration,absenceType,'
                  + 'absenceStatusCd,approvalStatusCd',
  };
});
