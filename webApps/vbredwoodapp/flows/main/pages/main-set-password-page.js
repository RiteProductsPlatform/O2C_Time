/* O2C Timesheet Module — set-password page module */

define([], () => {
  'use strict';

  class PageModule {

    /** Submit button label. A page function rather than a ternary (S1). */
    saveLabel(isSaving) {
      return isSaving ? 'Saving…' : 'Set password';
    }
  }

  return PageModule;
});
