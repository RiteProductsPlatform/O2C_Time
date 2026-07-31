/* O2C Timesheet Module — go to set-password, carrying the typed email */

define(['vb/action/actionChain', 'vb/action/actions'], (ActionChain, Actions) => {
  'use strict';

  class goToSetPasswordChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      // Carry whatever they already typed, so a user who came here after a
      // failed sign-in does not retype their address.
      await Actions.navigateToPage(context, {
        page: 'main-set-password',
        params: { email: ($page.variables.email || '').trim() },
      });
    }
  }

  return goToSetPasswordChain;
});
