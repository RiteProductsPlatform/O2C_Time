/* PAGE-009 Calendar — page entry */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class enterChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      $application.variables.activeNav = 'calendar-sync';

      await Actions.callChain(context, { chain: 'loadLayersChain' });
    }
  }

  return enterChain;
});
