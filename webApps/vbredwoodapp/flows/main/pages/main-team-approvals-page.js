define([], () => {
  'use strict';

  /**
   * PAGE-003 Team Approvals — page module functions.
   */
  class PageModule {

    /**
     * Explains who a retro adjustment is actually waiting on.
     *
     * RA-014 routes a cross-project change to BOTH the old and the new project
     * manager, so a manager looking at the panel needs to know whether they are
     * the blocker or whether they have already done their part. Without this the
     * row just says "Awaiting Approval" and reads as if nobody has acted.
     */
    waitingOn(row) {
      if (!row) { return ''; }

      const meOld = row.isOldProjectManager === 'Y';
      const meNew = row.isNewProjectManager === 'Y';

      const oldDone = !!row.oldMgrApprovedBy;
      const newDone = !!row.newMgrApprovedBy;

      // Reversal-only: there is no second manager to wait for.
      if (!row.newProjectName) {
        return oldDone ? 'Approved' : 'You';
      }

      // Same manager owns both sides — one approval finishes it.
      if (meOld && meNew) {
        return (oldDone || newDone) ? 'Approved' : 'You';
      }

      const myPart    = meOld ? oldDone : newDone;
      const otherPart = meOld ? newDone : oldDone;

      if (!myPart) { return 'You'; }
      if (!otherPart) {
        return meOld ? 'The new project manager' : 'The old project manager';
      }
      return 'Approved';
    }

    /**
     * True when this manager has nothing left to do on the row, so the Approve
     * button can be disabled rather than offering an action the server will
     * refuse.
     */
    alreadyActed(row) {
      return this.waitingOn(row) !== 'You';
    }

    /**
     * Empty-state text.
     *
     * Distinguishes "the filter excluded everything" from "you manage nothing
     * this month" — the two need different actions from the manager.
     */
    emptyMessage(allRows) {
      return (allRows && allRows.length)
        ? 'No project matches that filter.'
        : 'No projects managed \u2014 you do not manage any project with time in this month.';
    }

    /** Accessible name for an adjustment's approve button. */
    approveAdjLabel(employeeName) {
      return 'Approve adjustment for ' + employeeName;
    }

    /** Accessible name for a project's open button. */
    openProjectLabel(projectName) {
      return 'Open ' + projectName;
    }

  }

  return PageModule;
});
