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

    // The signed-in identity is NOT read here. `this.securityContext` is not a
    // VBCS page-module API — it is always undefined, which is what stranded the
    // app on "Could not determine the signed-in user". bootstrapChain reads VB's
    // built-in $application.user instead.
  }

  return PageModule;
});
