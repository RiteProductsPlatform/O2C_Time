/* PAGE-009 Calendar — close the day inspector */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  class closeInspectChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.showInspect = false;
      $page.variables.days        = [];
    }
  }

  return closeInspectChain;
});
