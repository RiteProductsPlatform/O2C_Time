/* O2C Timesheet Module — the one place navigation happens */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/navModel',
], (
  ActionChain,
  Actions,
  navModel
) => {
  'use strict';

  /**
   * Every navigation in the module goes through here, from the sidebar and from
   * page chains alike, so that entitlement is checked once and activeNav can
   * never disagree with what is on screen.
   *
   * navigateToFlow, not navigateToPage. This chain belongs to the SHELL page, so
   * a bare page id would be resolved among the shell's own siblings — of which
   * there are none — rather than inside the 'main' flow the shell hosts. Naming
   * the flow is what makes the target resolvable from here. Chains that live
   * inside the flow already (the login page's, for instance) use navigateToPage
   * with a bare id, because for them the page IS a sibling.
   */
  class navigateToPageChain extends ActionChain {

    async run(context, { page } = {}) {
      const { $page, $application } = context;

      if (!page) {
        return;
      }

      // RULE-022, second enforcement point. The sidebar already omits pages the
      // role may not open, but a URL can be typed and a stale bookmark can be
      // followed, and neither goes through the sidebar.
      if (!navModel.canOpen($application.variables.currentRole, page)) {
        $page.variables.shellError =
          'You are not entitled to open that page. If you believe this is ' +
          'wrong, contact your administrator.';
        return;
      }

      $page.variables.shellError = '';
      $application.variables.activeNav = page;

      await Actions.navigateToFlow(context, { flow: 'main', page, history: 'push' });
    }
  }

  return navigateToPageChain;
});
