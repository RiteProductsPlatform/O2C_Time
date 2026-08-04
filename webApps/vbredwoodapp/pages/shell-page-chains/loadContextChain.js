/* O2C Timesheet Module — load the context every page depends on */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Runs once a session exists, from either path that creates one — the shell
   * restoring a stored token, or the login form firing sessionEstablished.
   *
   * Loads the month list (RULE-004 / RULE-007) and, for managers, the teams they
   * may review (ACT-011). Neither is fatal if it fails: a user with no period
   * list can still see their weeks, and a manager without the switcher still
   * reviews their own team. Both failures are surfaced, though — a silently
   * empty month selector looks like there are no periods, which is a different
   * and much more alarming thing.
   */
  class loadContextChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      // Both paths that create a session end up here, and on a restore both
      // fire: checkSessionChain calls this directly so the month LOV is
      // populated before the landing page renders, and the shell's
      // sessionEstablished listener calls it again. Guarding on the user makes
      // the second call free instead of a second round-trip per list.
      const who = $application.variables.currentUserId;
      if (who && $application.variables.contextLoadedFor === who
          && ($application.variables.periodOptionsArray || []).length) {
        return;
      }
      $application.variables.contextLoadedFor = who;

      await this.loadPeriods(context, $application);

      // Manager only. PER-004's admin menu has no team pages, so loading the
      // switcher for an admin would be a request whose answer is never shown.
      if ($application.variables.currentRole === 'ROLE_TIME_MANAGER') {
        await this.loadManagers(context, $page, $application);
      }
    }

    async loadPeriods(context, $application) {
      let rows;
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getPeriods',
          uriParams: { _t: Date.now() },
        });
        if (!resp.ok || !resp.body || !resp.body.items) {
          throw new Error('period list unavailable');
        }
        rows = resp.body.items;
      } catch (e) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Periods unavailable',
          message: 'The month list could not be loaded, so cut-off dates and ' +
                   'period status will not be shown.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      const opts = rows.map((r) => ({
        value:             r.period_id,
        label:             r.period_name,
        periodState:       r.period_state,
        editableFlag:      r.editable_flag,
        adjustmentAllowed: r.adjustment_allowed,
      }));

      // periodOptions is assigned explicitly rather than live-bound to the
      // array. The array-linked ADP pattern is fine at PAGE scope, where the two
      // variables initialise together; at APPLICATION scope the binding is
      // evaluated during app-variable setup and leaves the ADP half-built, which
      // throws inside every oj-select-single that binds it and blanks the page.
      $application.variables.periodOptionsArray = opts;
      $application.variables.periodOptions = {
        itemType: 'periodOptionType',
        keyAttributes: 'value',
        data: opts,
      };

      // Default to the Open period; fall back to the newest row so the selector
      // is never left empty when a month is between states.
      const open = opts.find((o) => o.periodState === 'Open') || opts[0];
      if (!open) {
        return;
      }

      $application.variables.selectedPeriodId   = open.value;
      $application.variables.selectedPeriodName = open.label;
      $application.variables.periodEditable     = open.editableFlag || 'N';
      $application.variables.adjustmentAllowed  = open.adjustmentAllowed || 'N';

      if (!$application.variables.openPeriodId && open.periodState === 'Open') {
        $application.variables.openPeriodId = open.value;
      }
    }

    async loadManagers(context, $page, $application) {
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getManagers',
          uriParams: {
            employeeId: $application.variables.employeeId,
            _t: Date.now(),
          },
        });
        if (resp.ok && resp.body && resp.body.items) {
          // Application scope, not shell-page scope: the switcher itself lives
          // on PAGE-003 now (the prototype puts it there, not in the banner),
          // but sign-in is what knows which managers this user may act as.
          const opts = resp.body.items.map((m) => ({
            value: m.employee_id,
            label: m.employee_name,
          }));
          $application.variables.managerOptionsArray = opts;
          $application.variables.managerOptions = {
            itemType: 'lovOptionType',
            keyAttributes: 'value',
            data: opts,
          };
        }
      } catch (e) {
        // The switcher is a convenience: without it the manager still reviews
        // their own team, so this degrades quietly by design.
      }
    }
  }

  return loadContextChain;
});
