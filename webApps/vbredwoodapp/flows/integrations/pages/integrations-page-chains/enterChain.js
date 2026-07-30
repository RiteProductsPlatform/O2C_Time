/* PAGE-012 Integrations — page entry */

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

      $application.variables.activeNav = 'integrations';

      await Actions.callChain(context, { chain: 'loadIntegrationsChain' });
    }
  }

  return enterChain;
});
