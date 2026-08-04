/* O2C Timesheet Module — load the context every page depends on */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/contextLoader',
], (
  ActionChain,
  Actions,
  contextLoader
) => {
  'use strict';

  /**
   * Runs once a session exists, from either path that creates one — the shell
   * restoring a stored token, or the login form.
   *
   * The work itself lives in resources/js/contextLoader so that loginChain can
   * await exactly the same thing before it navigates. A page chain cannot call a
   * chain belonging to the shell page, and firing an event at the shell is not a
   * substitute: awaiting fireEvent waits for the DISPATCH, not for the listener
   * chains, so login navigated while the periods were still loading and the
   * month selector stayed empty until a browser refresh.
   *
   * Neither list is fatal if it fails. A user with no period list can still see
   * their weeks, and a manager without the switcher still reviews their own
   * team. A silently empty month selector is worth saying out loud, though — it
   * reads as "there are no periods", which is a different and much more
   * alarming thing than "the list did not load".
   */
  class loadContextChain extends ActionChain {

    async run(context) {
      const { $application } = context;

      const ok = await contextLoader.loadAll(context, Actions, $application);

      if (!ok) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Periods unavailable',
          message: 'The month list could not be loaded, so cut-off dates and '
                 + 'period status will not be shown.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
      }

      // Belt and braces, now that both session paths load the context before
      // navigating: a page reached by some route that does neither still gets
      // its selector filled in.
      await Actions.fireEvent(context, { event: 'contextLoaded' });
    }
  }

  return loadContextChain;
});
