/* O2C Timesheet Module — set or change a password */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'resources/js/session',
], (
  ActionChain,
  Actions,
  session
) => {
  'use strict';

  const MIN_LENGTH = 8;

  class setPasswordChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{event: Object}} params - the form's submit event
     */
    async run(context, { event } = {}) {
      const { $page, $application } = context;

      // The same listener serves the button and the confirmation field, so
      // Enter saves. Every other keystroke arrives here and must do nothing.
      if (event && event.type === 'keyup' && event.key !== 'Enter') {
        return;
      }

      const email   = ($page.variables.email || '').trim();
      const current = $page.variables.currentPassword || '';
      const next    = $page.variables.newPassword || '';
      const confirm = $page.variables.confirmPassword || '';

      $page.variables.errorMessage   = '';
      $page.variables.successMessage = '';

      if (!email) {
        $page.variables.errorMessage = 'Enter your email address.';
        return;
      }

      // Length is checked here as well as on the server. Catching it before the
      // round trip tells the user immediately; the server check is still the one
      // that enforces it, since nothing here is trusted.
      if (next.length < MIN_LENGTH) {
        $page.variables.errorMessage =
          'The new password must be at least ' + MIN_LENGTH + ' characters.';
        return;
      }

      // Confirmation is a client-only concern: the server is given one password
      // and has no way to know the user typed it twice.
      if (next !== confirm) {
        $page.variables.errorMessage = 'The two new passwords do not match.';
        return;
      }

      $page.variables.isSaving = true;
      try {
        await session.setPassword(
          $application.variables.ordsBaseUrl, email, current, next);
      } catch (err) {
        $page.variables.errorMessage = err.message;
        $page.variables.isSaving     = false;
        return;
      }

      // Nothing typed here outlives the request that used it.
      $page.variables.currentPassword = '';
      $page.variables.newPassword     = '';
      $page.variables.confirmPassword = '';
      $page.variables.isSaving        = false;

      // The server drops every session for this user on a password change, so a
      // token this browser still holds is already dead. Clear it rather than let
      // the shell try to restore it on the next load.
      session.clearToken();

      await Actions.navigateToPage(context, {
        page: 'main-login',
        params: { email },
      });
    }
  }

  return setPasswordChain;
});
