/* O2C Timesheet Module — navigation drawer toggle */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  class toggleDrawerChain extends ActionChain {

    /**
     * @param {Object} context
     */
    async run(context) {
      const { $page } = context;
      $page.variables.isDrawerOpen = !$page.variables.isDrawerOpen;
    }
  }

  return toggleDrawerChain;
});
