define([], () => {
  'use strict';

  /** PAGE-004 View Timesheet — page module functions. */
  class PageModule {

    /**
     * Cap type + hours as one string (FLD-045).
     *
     * The BRD is explicit that Cap is information only with no validation, so it
     * is rendered as text and never compared against the hours entered.
     */
    capDisplay(capType, capHours) {
      if (!capType && !capHours) { return '—'; }
      if (capType && capHours)   { return capType + ' · ' + capHours + 'h'; }
      return capType || (capHours + 'h');
    }


    /**
     * Selects every employee who can still be acted on.
     *
     * Deliberately skips employees already Approved: including them would send
     * pointless approvals and would make an approve-all look like it partly
     * failed when the server no-ops rows that were already done.
     */
    /**
     * Tick every row this manager can actually approve.
     *
     * Selects every employee whose month is not already Approved — INCLUDING
     * the acting manager's own row.
     *
     * It used to exclude them. RULE-015 sent a manager's own time to their
     * reporting manager, so offering the row here only produced a refusal.
     * That rule was relaxed on 21-Aug-2026 by explicit decision (db/104), and
     * the exclusion had to go with it: leaving it would have meant "Select all
     * pending" quietly skipping exactly the row the change was made to allow,
     * and the manager concluding the fix had not been applied.
     *
     * actorEmpId is still accepted so the signature and the caller do not
     * change, and so restoring the rule is a one-line edit here rather than a
     * chain change. It is deliberately unused.
     */
    // eslint-disable-next-line no-unused-vars
    selectAllEmployees(page, actorEmpId) {
      if (!page) { return; }
      page.selectedKeys = (page.employees || [])
        .filter((e) => e.monthStatus !== 'Approved')
        .map((e) => e.employeeId);
    }

    /**
     * Did the hand-off to accrual actually happen?
     *
     * A month can be confirmed and still have sent nothing: the manager's part
     * succeeds, the payload writes no rows, and accrual is handed an empty
     * batch it cannot tell from "nobody worked on this project". That happened
     * on 21-Aug-2026 and the screen reported it as a plain confirmation.
     *
     * Lives here rather than in the binding because bindings carry no logic
     * (S1), and takes both values as arguments because a page module does not
     * get this.$page.
     */
    accrualHandedOff(accrualStatus, accrualRows) {
      return accrualStatus === 'Success' && Number(accrualRows) > 0;
    }

    clearSelection(page) {
      if (page) { page.selectedKeys = []; }
    }

    /**
     * Drives the checkbox's checked state.
     *
     * Takes the key list as an argument rather than reading this.$page: a page
     * module does NOT get this.$page. Called from the FIRST column's cell
     * template, so throwing here took the whole table down with it — the
     * employee list rendered "No data to display" while the summary above it
     * correctly counted ten.
     */
    isSelected(selectedKeys, employeeId) {
      return (selectedKeys || []).indexOf(employeeId) >= 0;
    }

    // ── Row picker (oj-checkboxset) ───────────────────────────
    // oj-checkboxset carries an array value, so "ticked" is ['on'] and
    // "unticked" is []. These helpers keep that translation out of the markup,
    // which S1 requires bindings to be free of.

    /** @return {Array<string>} the checkboxset value for this row. */
    pickValue(selectedKeys, employeeId) {
      return this.isSelected(selectedKeys, employeeId) ? ['on'] : [];
    }

    // -- Header tick (select all) -----------------------------
    // Three states collapsed into two, because oj-checkboxset has no
    // indeterminate: ticked means "every pending row is selected", and a
    // partial selection reads as unticked. Clicking then selects the rest,
    // which is what somebody who can see some rows already ticked expects.
    //
    // A month with nothing pending returns unticked and toggling it is a
    // no-op -- there is nothing to select, and showing a permanently ticked
    // box on a fully approved month would suggest otherwise.

    /** @return {Array<string>} the header checkboxset value. */
    allPickValue(selectedKeys, employees) {
      const pending = (employees || [])
        .filter((e) => e.monthStatus !== 'Approved');
      if (pending.length === 0) { return []; }
      const keys = selectedKeys || [];
      return pending.every((e) => keys.indexOf(e.employeeId) >= 0)
        ? ['on'] : [];
    }

    /** Tick selects every pending row; untick clears the whole selection. */
    toggleAllPick(page, ticked) {
      if (!page) { return; }
      if (ticked) {
        this.selectAllEmployees(page, null);
      } else {
        page.selectedKeys = [];
      }
    }

    /** @return {string} accessible name for the row tick. */
    pickLabel(employeeName) {
      return 'Select ' + employeeName;
    }

    /** Mirrors the checkboxset value back into the id array. */
    togglePick(page, employeeId, picked) {
      if (!page) { return; }
      const on   = !!(picked && picked.length);
      const list = (page.selectedKeys || []).slice();
      const at   = list.indexOf(employeeId);

      if (on && at === -1)     { list.push(employeeId); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      page.selectedKeys = list;
    }

    /** Accessible name for an employee's open button. */
    openEmployeeLabel(employeeName) {
      return 'Open ' + employeeName;
    }


    /**
     * Open or close an oj-dialog by element id.
     *
     * oj-dialog has NO `opened` attribute — that is oj-drawer-popup. Binding
     * `opened="{{ ... }}"` therefore did nothing at all and every dialog on
     * this app was unopenable. JET exposes open()/close() methods instead, so
     * the boolean page variable stays the source of truth for logic and this
     * drives the component from it.
     */
    setDialog(dialogId, open) {
      const dlg = document.getElementById(dialogId);
      if (!dlg) { return; }
      if (open) { dlg.open(); } else { dlg.close(); }
    }

  }

  return PageModule;
});
