define([], () => {
  'use strict';

  /** PAGE-012 Integrations — page module functions. */
  class PageModule {

    /**
     * Empty-state text.
     *
     * Distinguishes "the filter excluded everything" from "there is nothing to
     * show at all" — the two need different actions from the user.
     */
    emptyMessage(allRows) {
      return (allRows && allRows.length)
        ? 'No integration in that area.'
        : 'Show endpoints \u2014 the integration catalogue has not been seeded.';
    }

  }

  return PageModule;
});
