/* O2C Timesheet Module — sign out */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/session',
], (
  ActionChain,
  Actions,
  session
) => {
  'use strict';

  /**
   * Signs out locally first, then tells the server.
   *
   * That order is deliberate: the user asked to be signed out, and a failed or
   * slow call to the service is not a reason to leave them signed in. The token
   * is dropped here and expires server-side within 24 hours regardless.
   */
  class logoutChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const token   = $application.variables.sessionToken;
      const baseUrl = $application.variables.ordsBaseUrl;

      session.clear($application);
      session.clearToken();

      $page.variables.shellError          = '';
      $page.variables.sidebarCollapsed    = true;
      $application.variables.periodOptionsArray = [];
      $application.variables.periodOptions = {
        itemType: 'periodOptionType', keyAttributes: 'value', data: [],
      };

      // Not awaited before navigating — see above.
      session.logout(baseUrl, token);

      // navigateToFlow, not navigateToPage — see navigateToPageChain: this chain
      // is on the shell page, so the flow has to be named for main-login to
      // resolve. Not routed through navigateToPageChain because that checks
      // entitlement against a role we have just cleared.
      await Actions.navigateToFlow(context, {
        flow: 'main', page: 'main-login', history: 'replace',
      });
    }
  }

  return logoutChain;
});
