/* PAGE-006 Leave Loss Coverage — read absence live from Fusion, for everyone
   on the project, then rebuild the absentee list */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/absence',
], (
  ActionChain,
  Actions,
  Absence
) => {
  'use strict';

  /**
   * "Refresh absences from HR" used to mean "re-read our own cache".
   *
   * The button called llc/generate, and generate_llc_lines selects from
   * OC_TIME_ABSENCE. So leave applied in Fusion reached this screen only when
   * something else had already fetched it — the nightly feed, or the absent
   * person opening their own timesheet, which triggers PAGE-001's live read for
   * that one person. Measured 20-Aug-2026: RI2894's 20-Aug leave was APPROVED
   * in Fusion, absent from OC_TIME_ABSENCE, and therefore missing from the
   * coverage list their manager works from. The button said it had refreshed
   * and it had, from the wrong place.
   *
   * SIX HOPS, and the roster is the one that is easy to leave out:
   *
   *   1  llc/roster            who is allocated here, and the month's window
   *   2  fa_hcm/getWorkers     PersonNumber -> PersonId, ALL of them in one call
   *   3  fa_hcm/getAbsences    the live read, ALL of them in one call
   *   4  oc_time/syncAbsence   per person, as a windowed claim
   *   5  oc_time/generateLlc   turn the absences into coverage lines
   *   6  loadLinesChain        show them
   *
   * TWO CALLS TO FUSION, NOT TWO PER PERSON. Both resources accept IN lists —
   * measured on the pod, PersonNumber IN (7 numbers) and personId IN (7 ids)
   * with the date window both return 200 with exactly the right rows. A
   * per-person loop would have made this scale with headcount for no reason.
   *
   * HOP 4 POSTS FOR EVERY PERSON ON THE ROSTER, including the ones Fusion
   * returned nothing for. That is not waste, it is the whole of scenario 23:
   * employeeId + windowFrom + windowTo turns the payload from a list into a
   * claim — "these are ALL the absences this person has between these dates" —
   * and the handler deletes what it was not sent inside that window. Skip the
   * empty ones and cancelled leave never retracts, because "no leave" and "we
   * did not ask" would look identical.
   *
   * FAILURE STILL REBUILDS FROM THE CACHE. If Fusion is unreachable the manager
   * is told so plainly and hop 5 still runs, so the button does at least what
   * it used to do. Refusing to do anything because the pod is down would be a
   * worse answer than a stale one that says it is stale.
   */
  class refreshHrAbsenceChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $page.variables.projectId;
      const periodId  = $page.variables.periodId;
      if (!projectId || !periodId) { return; }

      $page.variables.busy = true;

      let fusionNote = null;   // set when the live half could not complete

      try {
        // ── 1. who is on this project, and over what dates ───────
        const roster = await Actions.callRest(context, {
          endpoint: 'oc_time/getLlcRoster',
          uriParams: { projectId: projectId, periodId: periodId, _t: Date.now() },
        });

        const people = (roster.ok && roster.body && roster.body.items) || [];

        if (!roster.ok) {
          fusionNote = 'Could not read the project team, so leave was not '
                     + 'refreshed from Fusion. '
                     + $application.functions.restError(roster);
        } else if (!people.length) {
          fusionNote = 'Nobody is allocated to this project for this month, so '
                     + 'there is no leave to read.';
        } else {
          const from = people[0].window_from;
          const to   = people[0].window_to;

          await this.pullFromFusion(context, people, from, to);
        }

      } catch (e) {
        if ($application.functions.isAbortError(e)) {
          $page.variables.busy = false;
          return;
        }
        fusionNote = $application.functions.chainError(
          e, 'Fusion could not be reached, so leave was not refreshed.');
      }

      if (fusionNote) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Leave not refreshed from HR',
          message: fusionNote + ' The list below was rebuilt from the last '
                 + 'known leave.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
      }

      // ── 5 & 6. rebuild the coverage lines either way ───────────
      $page.variables.busy = false;
      await Actions.callChain(context, { chain: 'generateLinesChain' });
    }

    /**
     * Hops 2 to 4. Throws on a transport failure; a REST call that answers with
     * a status is handled here and reported through the thrown message, so the
     * caller has one place to decide what a partial refresh means.
     */
    async pullFromFusion(context, people, from, to) {
      const { $application } = context;

      const empIds = people.map((p) => p.employee_id).filter(Boolean);

      // ── 2. PersonNumber -> PersonId, in one call ───────────────
      const who = await Actions.callRest(context, {
        endpoint: 'fa_hcm/getWorkers',
        uriParams: {
          q: Absence.workerQuery(empIds),
          limit: 500, onlyData: true, fields: 'PersonNumber,PersonId',
        },
      });

      // A FAILED CALL AND AN EMPTY RESULT ARE DIFFERENT THINGS. Collapsing them
      // reports a stale backend credential as "no such person in Fusion", which
      // sends whoever reads it into HCM data instead of into the VB backend
      // configuration — the same trap PAGE-001 documents.
      if (!who.ok) {
        throw new Error('Fusion refused the worker lookup (HTTP ' + who.status
          + '). Leave was not refreshed.');
      }

      const byNumber = {};
      ((who.body && who.body.items) || []).forEach((w) => {
        byNumber[String(w.PersonNumber)] = w.PersonId;
      });

      const personIds = empIds.map((e) => byNumber[e]).filter(Boolean);
      if (!personIds.length) {
        throw new Error('Fusion answered, but none of this project’s '
          + empIds.length + ' colleagues could be matched to a person there.');
      }

      // ── 3. the live read, in one call ──────────────────────────
      const res = await Actions.callRest(context, {
        endpoint: 'fa_hcm/getAbsences',
        uriParams: {
          q: Absence.absenceQuery(personIds, from, to),
          // One month, one project team. 500 is far above any real answer and
          // well below the point where the response gets slow; a truncated
          // read would look exactly like cancelled leave and retract it.
          limit: 500, onlyData: true,
          fields: Absence.ABSENCE_FIELDS,
        },
      });

      if (!res.ok) {
        throw new Error('Fusion refused the absence read (HTTP ' + res.status
          + '). Leave was not refreshed.');
      }

      const items = (res.body && res.body.items) || [];

      // Group by person. personId comes back as a number and the map is keyed
      // by string, so both sides are stringified — an == would work and a ===
      // would silently group nothing.
      const byPerson = {};
      items.forEach((x) => {
        const k = String(x.personId);
        (byPerson[k] = byPerson[k] || []).push(x);
      });

      // ── 4. post one windowed claim per person ──────────────────
      let sent = 0;
      let failed = 0;

      for (const p of people) {
        const pid = byNumber[p.employee_id];
        if (!pid) { continue; }            // unmatched: say nothing about them

        const rows = Absence.absenceToRows(
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

      if (failed) {
        throw new Error(sent + ' of ' + (sent + failed)
          + ' colleagues were refreshed; the rest could not be saved.');
      }
    }
  }

  return refreshHrAbsenceChain;
});
