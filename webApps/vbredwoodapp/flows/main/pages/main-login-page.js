/* O2C Timesheet Module — login page module */

define([], () => {
  'use strict';

  class PageModule {

    /**
     * The submit button's label. A page function rather than a ternary in the
     * binding (S1), and a label swap rather than two oj-bind-if branches — the
     * button keeps its identity and its focus while the request is in flight.
     */
    signInLabel(isSigningIn) {
      return isSigningIn ? 'Signing in\u2026' : 'Sign In';
    }
  }

  return PageModule;
});
