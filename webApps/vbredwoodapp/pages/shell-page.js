/* O2C Timesheet Module — shell page module */

define(['resources/js/navModel'], (navModel) => {
  'use strict';

  /**
   * Presentation helpers for the shell's bindings.
   *
   * S1 forbids expressions inside [[ ]], and these exist to honour it: each one
   * replaces a ternary or a chain of string operations that would otherwise sit
   * in the HTML, where it cannot be read, reused or tested.
   */
  const ROLE_LABELS = {
    ROLE_TIME_ADMIN:      'Finance / Admin',
    ROLE_TIME_MANAGER:    'Manager',
    ROLE_TIME_EMPLOYEE:   'Employee',
    ROLE_TIME_CONTRACTOR: 'Contractor',
    ROLE_TIME_NONE:       'No access',
  };

  // Manager only — the admin menu (PER-004) has no team pages, so there is
  // nothing for an acting-manager switch to change.
  // (MANAGER_ROLES was only used by canSwitchManager, which moved with the
  //  switcher to PAGE-003.)

  class PageModule {

    /** Up to two initials for the topbar avatar. */
    initials(fullName) {
      const parts = String(fullName || '').trim().split(/\s+/).filter(Boolean);
      if (!parts.length) {
        return '?';
      }
      return parts.map((w) => w.charAt(0)).join('').substring(0, 2).toUpperCase();
    }

    /**
     * ROLE_TIME_MANAGER reads as a database constant, not as a job. The badge
     * shows the human word; the raw role stays the value every check compares.
     */
    roleLabel(role) {
      return ROLE_LABELS[role] || '';
    }

    /**
     * The sidebar for the current role.
     *
     * Read straight from the nav model on each render rather than cached into a
     * page variable by a chain — so the menu cannot lag the role, and there is
     * one definition of who may see what rather than two that drift.
     */
    navGroups(role) {
      return navModel.groupsFor(role);
    }

    /** True when the role is entitled to nothing, so the nav can say why. */
    hasNoNav(role) {
      return navModel.groupsFor(role).length === 0;
    }


    /** Active state for a sidebar item. */
    navItemClass(page, activeNav) {
      return page === activeNav ? 'rw-nav-item active' : 'rw-nav-item';
    }
  }

  return PageModule;
});
