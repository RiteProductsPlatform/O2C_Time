/* O2C Timesheet Module — back to sign in */

define(['vb/action/actionChain', 'vb/action/actions'], (ActionChain, Actions) => {
  'use strict';

  class goToLoginChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      await Actions.navigateToPage(context, {
        page: 'main-login',
        params: { email: ($page.variables.email || '').trim() },
      });
    }
  }

  return goToLoginChain;
});
