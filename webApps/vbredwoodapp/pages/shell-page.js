/* Copyright (c) 2026, Oracle and/or its affiliates */

define([], () => {
  'use strict';

  class PageModule {

    /**
     * Human-readable name for the signed-in role.
     *
     * A page function rather than a ternary chain in the binding: S1 forbids
     * conditional logic inside [[ ]], and this is the kind of mapping that would
     * otherwise be duplicated wherever the role is shown.
     */
    roleLabel(role) {
      switch (role) {
        case 'ROLE_TIME_EMPLOYEE':   return 'Employee';
        case 'ROLE_TIME_CONTRACTOR': return 'Contractor';
        case 'ROLE_TIME_MANAGER':    return 'Manager';
        case 'ROLE_TIME_ADMIN':      return 'Finance / Admin';
        default:                     return 'No access';
      }
    }

    /**
     * Signed-in user's email.
     *
     * The employee id (HCM PersonNumber) is NOT derivable from the token, so
     * bootstrapChain resolves it from OC_TIME_WORKER by email. This function
     * only supplies the email, and deliberately returns '' rather than a guess
     * when the security context is missing, so bootstrapChain can show a real
     * error instead of silently loading someone else's timesheet.
     */
    currentUserEmail() {
      try {
        const p = this.securityContext && this.securityContext.userProfile;
        return (p && (p.email || p.username)) || '';
      } catch (e) {
        return '';
      }
    }
  }

  return PageModule;
});
