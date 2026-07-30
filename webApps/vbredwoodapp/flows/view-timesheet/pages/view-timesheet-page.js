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
     * Toggles one employee in the bulk selection.
     *
     * An explicit checkbox column is used rather than oj-table's selection-mode
     * because selected-row-keys expects a JET KeySet, while the bulk
     * approve/reject calls need a plain array of employee ids to post as JSON.
     * Keeping the selection as an array end to end avoids converting a KeySet on
     * every action, and it matches the pattern the daily view already uses for
     * date selection.
     */
    toggleEmployee(employeeId, event) {
      const page = this.$page.variables;
      const list = (page.selectedKeys || []).slice();
      const on   = event && event.target && event.target.checked;
      const at   = list.indexOf(employeeId);

      if (on && at === -1)     { list.push(employeeId); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      page.selectedKeys = list;
    }

    /**
     * Selects every employee who can still be acted on.
     *
     * Deliberately skips employees already Approved: including them would send
     * pointless approvals and would make an approve-all look like it partly
     * failed when the server no-ops rows that were already done.
     */
    selectAllEmployees() {
      const page = this.$page.variables;
      page.selectedKeys = (page.employees || [])
        .filter((e) => e.monthStatus !== 'Approved')
        .map((e) => e.employeeId);
    }

    clearSelection() {
      this.$page.variables.selectedKeys = [];
    }

    /** Drives the checkbox's checked state. */
    isSelected(employeeId) {
      return (this.$page.variables.selectedKeys || []).indexOf(employeeId) >= 0;
    }

    // ── Row picker (oj-checkboxset) ───────────────────────────
    // oj-checkboxset carries an array value, so "ticked" is ['on'] and
    // "unticked" is []. These three helpers keep that translation out of the
    // markup, which S1 requires bindings to be free of.

    /** @return {Array<string>} the checkboxset value for this row. */
    pickValue(employeeId) {
      return this.isSelected(employeeId) ? ['on'] : [];
    }

    /** @return {string} accessible name for the row tick. */
    pickLabel(employeeName) {
      return 'Select ' + employeeName;
    }

    /** Mirrors the checkboxset value back into the id array. */
    togglePick(employeeId, event) {
      const on = !!(event && event.detail && event.detail.value &&
                    event.detail.value.length);
      const list = (this.$page.variables.selectedKeys || []).slice();
      const at = list.indexOf(employeeId);

      if (on && at === -1)     { list.push(employeeId); }
      else if (!on && at >= 0) { list.splice(at, 1); }

      this.$page.variables.selectedKeys = list;
    }

    /** Accessible name for an employee's open button. */
    openEmployeeLabel(employeeName) {
      return 'Open ' + employeeName;
    }

  }

  return PageModule;
});
