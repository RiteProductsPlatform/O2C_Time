/* O2C Timesheet Module — sign in */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/session',
  'resources/js/navModel',
], (
  ActionChain,
  Actions,
  session,
  navModel
) => {
  'use strict';

  class loginChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{event: Object}} params - the form's submit event
     */
    async run(context, { event } = {}) {
      const { $page, $application } = context;

      // One listener serves the button and both input fields, so Enter signs in
      // from either. Every other keystroke lands here too and must leave without
      // doing anything.
      if (event && event.type === 'keyup' && event.key !== 'Enter') {
        return;
      }

      const email    = ($page.variables.email || '').trim();
      const password = $page.variables.password || '';

      if (!email || !password) {
        $page.variables.errorMessage = 'Enter both your email address and password.';
        return;
      }

      $page.variables.isSigningIn  = true;
      $page.variables.errorMessage = '';

      let identity;
      try {
        identity = await session.login(
          $application.variables.ordsBaseUrl, email, password);
      } catch (err) {
        // An Invited account is not a failed sign-in, it is an unfinished setup,
        // so send them where they can finish it instead of showing a dead end.
        if (err.needsPassword) {
          $page.variables.isSigningIn = false;
          await Actions.navigateToPage(context, {
            page: 'main-set-password',
            params: { email },
          });
          return;
        }
        $page.variables.errorMessage = err.message;
        $page.variables.isSigningIn  = false;
        return;
      }

      // The password never outlives the request that used it.
      $page.variables.password = '';

      session.apply($application, identity, identity.token);
      session.writeToken(identity.token);

      // Tells the shell to load the period list and the manager switcher. An
      // event because this page is in the 'main' flow and cannot call a chain
      // that belongs to the shell page.
      await Actions.fireEvent(context, { event: 'sessionEstablished' });

      const landing = navModel.landingFor(identity.role);
      if (!landing) {
        // Valid credentials, no entitlement. Say so plainly rather than dropping
        // them on an empty page: the fix is an administrator's, not theirs.
        $page.variables.errorMessage =
          'Your sign-in was accepted, but your account is not entitled to any ' +
          'part of the Time module. Contact your administrator.';
        session.clear($application);
        session.clearToken();
        $page.variables.isSigningIn = false;
        return;
      }

      $application.variables.activeNav = landing;
      await Actions.navigateToPage(context, { page: landing, history: 'replace' });

      $page.variables.isSigningIn = false;
    }
  }

  return loginChain;
});
