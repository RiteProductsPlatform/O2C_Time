/* O2C Timesheet Module — drawer nav selection */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * oj-navigation-list writes its selection back to activeNav, and fires
   * selectionChanged for BOTH a user click and a programmatic write. navigateChain
   * performs such a write, so without a guard every navigation would bounce back
   * through here and navigate a second time.
   *
   * currentRoute is what the router is actually on. If the incoming selection
   * already matches it, this event is the echo of a navigation that has already
   * happened and there is nothing to do.
   */
  class onNavSelectionChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{target:string}} params
     */
    async run(context, { target }) {
      const { $page } = context;

      if (!target || target === $page.variables.currentRoute) {
        return;
      }

      await Actions.callChain(context, {
        chain: 'navigateChain',
        params: { target },
      });
    }
  }

  return onNavSelectionChain;
});
