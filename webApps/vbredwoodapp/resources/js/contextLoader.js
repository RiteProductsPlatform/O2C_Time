define([], () => {
  'use strict';

  /**
   * The context every page depends on: the month list (RULE-004 / RULE-007) and,
   * for a manager, the teams they may review (ACT-011).
   *
   * WHY THIS IS A MODULE AND NOT JUST THE SHELL'S CHAIN
   *
   * Two paths create a session and BOTH must have the periods in place before
   * the landing page mounts:
   *
   *   refresh  checkSessionChain awaits loadContextChain, then navigates.
   *            This always worked.
   *   login    loginChain fired sessionEstablished and navigated. Awaiting
   *            fireEvent waits for the DISPATCH, not for the listener chains,
   *            so the page mounted while the periods were still loading — and
   *            the month selector was empty until a browser refresh.
   *
   * A page chain cannot call a chain that belongs to the shell page (that
   * resolves against the calling page's own -chains folder and 404s), so the
   * shared work lives here, where either chain can await it. No duplicated
   * getPeriods call, and no cross-page event in the critical path.
   *
   * Actions is passed in rather than imported: callRest needs the CALLER's
   * chain context, and a module has none of its own.
   */
  return {

    /**
     * @return {Promise<boolean>} true when the period list was populated.
     */
    async loadPeriods(context, Actions, $application) {
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
        return false;
      }

      const opts = rows.map((r) => ({
        value:             r.period_id,
        label:             r.period_name,
        periodState:       r.period_state,
        editableFlag:      r.editable_flag,
        adjustmentAllowed: r.adjustment_allowed,
      }));

      // Assigned explicitly, never live-bound to the array. The array-linked ADP
      // pattern is fine at PAGE scope, where the two variables initialise
      // together; at APPLICATION scope the binding is evaluated during variable
      // setup and leaves the ADP half-built, which throws inside every
      // oj-select-single that binds it and blanks the page.
      $application.variables.periodOptionsArray = opts;
      $application.variables.periodOptions = {
        itemType: 'periodOptionType',
        keyAttributes: 'value',
        data: opts,
      };

      // Default to an Open period. RULE-017 is relaxed, so there can be more
      // than one — take the one containing today, else the earliest open, which
      // is the same order get_open_period_id uses on the server. Falling back to
      // the newest row keeps the selector from being left empty between months.
      const today = new Date().toISOString().substring(0, 10);
      const open = opts.filter((o) => o.periodState === 'Open');
      const chosen = open.find((o) => o.value === $application.variables.openPeriodId)
                  || open[0] || opts[0];
      if (!chosen) { return true; }

      $application.variables.selectedPeriodId   = chosen.value;
      $application.variables.selectedPeriodName = chosen.label;
      $application.variables.periodEditable     = chosen.editableFlag || 'N';
      $application.variables.adjustmentAllowed  = chosen.adjustmentAllowed || 'N';

      if (!$application.variables.openPeriodId && chosen.periodState === 'Open') {
        $application.variables.openPeriodId = chosen.value;
      }
      return true;
    },

    /**
     * The managers this user may act as (ACT-011). Application scope because
     * sign-in is what knows them, while the control that uses them lives on a
     * page. A failure degrades quietly: without the list a manager still
     * reviews their own team.
     */
    async loadManagers(context, Actions, $application) {
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getManagers',
          uriParams: {
            employeeId: $application.variables.employeeId,
            _t: Date.now(),
          },
        });
        if (resp.ok && resp.body && resp.body.items) {
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
        // Convenience only — see above.
      }
    },

    /** Both, in the order the pages need them. */
    async loadAll(context, Actions, $application) {
      const ok = await this.loadPeriods(context, Actions, $application);
      if ($application.variables.currentRole === 'ROLE_TIME_MANAGER') {
        await this.loadManagers(context, Actions, $application);
      }
      return ok;
    },
  };
});
