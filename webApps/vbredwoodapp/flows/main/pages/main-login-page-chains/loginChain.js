/* O2C Timesheet Module — sign in */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/session',
  'resources/js/navModel',
  'resources/js/contextLoader',
], (
  ActionChain,
  Actions,
  session,
  navModel,
  contextLoader
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

      // Load the period list and the manager switcher HERE, awaited, before
      // navigating anywhere.
      //
      // This used to fire sessionEstablished and let the shell's listener do it.
      // Awaiting fireEvent waits for the DISPATCH, not for the listener chains,
      // so the landing page mounted while getPeriods was still in flight and the
      // month selector was empty until the user pressed F5. A refresh always
      // worked because checkSessionChain awaits the load before it navigates —
      // this is now the same shape.
      //
      // Shared module rather than the shell's chain: a page chain cannot call a
      // chain that belongs to the shell page.
      await contextLoader.loadAll(context, Actions, $application);

      // Still fired, for anything that listens for a session beginning.
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
