/* PAGE-001 My Timesheet — read leave live from Fusion for the open week */

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
   * Absence is the one timesheet input that cannot be prepopulated and left
   * alone. Leave is system-owned by Absence Management (RULE-008) — the
   * employee can neither type it nor delete it — and it can be applied,
   * shortened or cancelled after the week has already been built. So it is read
   * per person per date, live, whenever a week is opened.
   *
   * FOUR HOPS, AND THE LAST TWO ARE THE ONES PEOPLE LEAVE OUT
   *
   *   1  fa_hcm/getWorkers     PersonNumber -> PersonId
   *   2  fa_hcm/getAbsences    the live read, overlapping this week
   *   3  oc_time/syncAbsence   cache it in OC_TIME_ABSENCE
   *   4  oc_time/runPopulation build the Leave cells in OC_TS_ENTRY
   *
   * Hops 3 and 4 are not bureaucracy. A value fetched straight into the page
   * never reaches the database, so no rule in OC_TIME_PKG sees it, it is not on
   * the sheet the manager approves, and it never reaches accrual. Writing it
   * back through ORDS is what keeps the database the one place the rules live —
   * the note on the fa backend in services/catalog.json says the same thing.
   *
   * Hop 1 exists only because OC_TIME_WORKER does not store the Fusion
   * PersonId — open point S-12. Once it does, this loses a round trip.
   *
   * FAILURE IS NON-FATAL BY DESIGN. If Fusion is unreachable the week still
   * opens, showing leave as it was last known, with a warning. Blocking a
   * timesheet on a pod outage is a worse failure than a stale leave row
   * (open point S-04).
   */
  class refreshAbsenceChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const empId  = $application.variables.employeeId;
      const period = $page.variables.periodId;
      const week   = $page.variables.weekRow;

      if (!empId || !period || !week || !week.week_start) { return; }

      const from = String(week.week_start).substring(0, 10);
      const to   = String(week.week_end).substring(0, 10);

      $page.variables.absenceState = 'running';

      try {
        // ── 1. PersonNumber -> PersonId ──────────────────────────
        // Cached on the page: it cannot change while the same employee's
        // timesheet is open, and re-resolving on every week arrow is a wasted
        // round trip to Fusion.
        let personId = $page.variables.fusionPersonId;

        if (!personId) {
          const who = await Actions.callRest(context, {
            endpoint: 'fa_hcm/getWorkers',
            uriParams: {
              q: Absence.workerQuery(empId),
              limit: 1, onlyData: true, fields: 'PersonNumber,PersonId',
            },
          });
          // A FAILED CALL AND AN EMPTY RESULT ARE DIFFERENT THINGS, and this
          // used to collapse them: `(who.ok && who.body.items) || []` makes a
          // 401 indistinguishable from "no such person", so a stale backend
          // credential was reported as "could not match RI2824 to a person in
          // Fusion" — pointing whoever read it at HCM data when the actual
          // fault was the password in the VB Studio backend. Same family as the
          // "0 entries saved" message: the words have to name the real cause.
          if (!who.ok) {
            return this.warn(context, $page.functions.absenceDiagnosis(who.status, 'worker lookup'));
          }
          const found = (who.body && who.body.items) || [];
          if (!found.length) {
            return this.warn(context,
              'Fusion answered, but no worker has employee number ' + empId
              + '. Leave was not refreshed and the hours below are unchanged.');
          }
          personId = found[0].PersonId;
          $page.variables.fusionPersonId = personId;
        }

        // ── 2. the live read ───────────────────────────────────────
        // BY PERSON ONLY. The window is applied below, in absenceToRows, which
        // was always clamping to it anyway.
        //
        // resources/js/absence.js carries the measurements. Short version: a
        // `q` with a SPACE in it does not survive the VB proxy (500, which is
        // what the screen reported on 21-Aug) and a `q` with a ';' does not
        // survive Fusion's parser (400). There is no multi-predicate form that
        // works on both paths, so the date predicate goes and the window is
        // applied in the browser -- which is where it was being applied anyway.
        //
        // limit 500 rather than 100, because this now asks for the person's
        // whole absence history. A short read is dangerous rather than merely
        // incomplete; see the hasMore check below.
        const res = await Actions.callRest(context, {
          endpoint: 'fa_hcm/getAbsences',
          uriParams: {
            q: Absence.absenceQuery(personId),
            limit: 500, onlyData: true,
            fields: Absence.ABSENCE_FIELDS,
          },
        });

        if (!res.ok) {
          return this.warn(context,
            $page.functions.absenceDiagnosis(res.status, 'absence read'));
        }

        // A TRUNCATED READ MUST NOT BE POSTED. Hop 3 sends a windowed claim and
        // the handler deletes what it was not sent inside that window, so a
        // short read is indistinguishable from cancelled leave and would delete
        // leave that is still live.
        if (Absence.wasTruncated(res.body)) {
          return this.warn(context,
            'Fusion returned only part of this person\'s absence history, so '
            + 'leave was not refreshed rather than risk removing leave that is '
            + 'still live. The hours below are unchanged.');
        }

        const rows = Absence.absenceToRows(
          (res.body && res.body.items) || [], empId, from, to,
          $application.variables.stdHoursPerDay);

        // ── 3. cache it ──────────────────────────────────────────
        // NO EARLY RETURN ON AN EMPTY RESULT, and that is the whole of
        // scenario 23. This used to skip the call when Fusion returned
        // nothing, on the reading that there was nothing to save — but
        // "Fusion has no leave for this person this month" is exactly what
        // cancelled leave looks like, and skipping meant the cached row and
        // its timesheet line survived forever. The empty answer is the
        // signal, so it has to be delivered.
        //
        // employeeId + windowFrom/windowTo turn this into a statement rather
        // than a list: "these are ALL the absences this person has between
        // these dates". That lets the handler delete what it was not sent and
        // retract the leave entries behind them. The BIP feed sends no window
        // and is unaffected — it could not honestly make the same claim.
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

        if (!sync.ok) {
          return this.warn(context,
            'Leave was read from Fusion but could not be saved, so the grid '
            + 'may not show it. ' + $application.functions.restError(sync));
        }

        // ── 4. turn it into timesheet cells ──────────────────────
        // populate_month leaves an existing entry untouched, so this never
        // overwrites anything already typed.
        //
        // employeeId goes in the BODY, not in uriParams. Only periodId is
        // declared as a path parameter, and VB drops uriParams the operation
        // does not declare — which would silently widen this from one person to
        // every allocation in the period, on every page load. The operation's
        // own schema says so: "Omit to populate every allocation."
        const pop = await Actions.callRest(context, {
          endpoint: 'oc_time/runPopulation',
          uriParams: { periodId: period },
          body: {
            employeeId: empId,
            actor: $application.variables.currentEmail || 'VBCS_USER',
          },
        });

        if (!pop.ok) {
          return this.warn(context,
            'Leave was saved but the timesheet rows could not be rebuilt. '
            + $application.functions.restError(pop));
        }

        // 'none' still means "no leave this week" and is set here rather than
        // by returning early, so the reconciliation above always runs first.
        // A cancellation lands as 'none' AFTER the old row has been retracted,
        // which is the state the user should see.
        $page.variables.absenceState = rows.length ? 'ok' : 'none';

      } catch (e) {
        // No status at all — the proxy never answered. Most often the fa
        // backend is configured in Designer but not published, so there is
        // nothing to resolve vb-catalog://backends/fa/hcm against.
        await this.warn(context, $page.functions.absenceDiagnosis(0, 'Fusion'));
      }
    }

    /**
     * Warn without stopping the week from opening.
     *
     * Separate from the module's other failures on purpose: every one of these
     * means "your hours are fine, the leave beside them may be stale", which is
     * a different thing to tell somebody than "that did not save".
     */
    async warn(context, message) {
      context.$page.variables.absenceState = 'fail';
      await Actions.fireNotificationEvent(context, {
        summary: 'Leave not refreshed',
        message: message,
        severity: 'warning',
        type: 'warning',
        displayMode: 'transient',
      });
    }
  }

  return refreshAbsenceChain;
});
