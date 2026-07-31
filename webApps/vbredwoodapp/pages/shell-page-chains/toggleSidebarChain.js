/* O2C Timesheet Module — open/close the navigation sidebar */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * A page variable rather than a DOM class toggle. The main O2C application
   * reaches for document.querySelector here; that works, but it puts layout
   * state somewhere the framework cannot see, so it is lost on re-render and
   * invisible to anything that wants to react to it.
   */
  class toggleSidebarChain extends ActionChain {

    async run(context) {
      const { $page } = context;
      $page.variables.sidebarCollapsed = !$page.variables.sidebarCollapsed;
    }
  }

  return toggleSidebarChain;
});
