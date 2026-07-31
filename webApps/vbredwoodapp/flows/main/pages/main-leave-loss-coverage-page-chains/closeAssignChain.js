/* PAGE-006 Leave Loss Coverage — close the assign dialog */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  class closeAssignChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.showAssign    = false;
      $page.variables.assignCoverId = '';
    }
  }

  return closeAssignChain;
});
