/* O2C Timesheet Module — shell bootstrap: restore or demand a session */

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

  /**
   * Runs on every load of the shell.
   *
   *   no token           -> stay on the login page
   *   token, still valid -> restore the session and land on the role's page
   *   token, dead        -> clear it and fall back to the login page
   *
   * A dead token has to fail here rather than at the first write, or the user
   * spends ten minutes filling in a timesheet that cannot be saved.
   *
   * The identity comes from OUR store (oc.time.auth over OC_TIME_USER), not from
   * VB's $application.user. That is the point of the standalone model: the
   * common administrator is a real login who need not exist as a worker in HCM,
   * so there is nothing for an identity provider to resolve.
   */
  class checkSessionChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      // Same-tab remount with the session already in memory: nothing to restore,
      // but the page context still has to be rebuilt.
      if ($application.variables.isLoggedIn) {
        await Actions.callChain(context, { chain: 'loadContextChain' });
        return;
      }

      const token = session.readToken();
      if (!token) {
        return;                                  // stay on main-login
      }

      let identity;
      try {
        identity = await session.validateToken(
          $application.variables.ordsBaseUrl, token);
      } catch (e) {
        // Deliberately NOT falling back to a cached name and role: the module
        // cannot do anything without the service, and a restored session would
        // imply otherwise.
        $page.variables.shellError =
          'The timesheet service is unavailable, so your session could not be ' +
          'confirmed. Check your connection and reload the page.';
        return;
      }

      if (!identity) {
        session.clearToken();
        return;                                  // expired or revoked
      }

      session.apply($application, identity, token);
      await Actions.callChain(context, { chain: 'loadContextChain' });

      // A restored session has to announce itself exactly as a fresh login
      // does. On a refresh the router mounts the page before this validation
      // finishes, so the page's vbEnter finds no employeeId and loads nothing;
      // it listens for this event and loads then. Only loginChain used to fire
      // it, which is why a refresh left every page empty with a "worker record
      // could not be resolved" toast while the banner showed the right name.
      await Actions.fireEvent(context, { event: 'sessionEstablished' });

      const landing = navModel.landingFor(identity.role);
      if (!landing) {
        // A login that resolves to no entitlement is not an error to hide: the
        // person has valid credentials and needs to be told what is missing.
        $page.variables.shellError =
          'Your account is not entitled to any part of the Time module. ' +
          'Contact your administrator to be granted a role.';
        return;
      }

      await Actions.callChain(context, {
        chain: 'navigateToPageChain',
        params: { page: landing },
      });
    }
  }

  return checkSessionChain;
});
