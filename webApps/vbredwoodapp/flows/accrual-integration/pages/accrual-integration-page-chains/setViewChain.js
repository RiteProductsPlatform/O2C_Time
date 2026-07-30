/* PAGE-011 Accrual Integration — switch the extract view */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Sets the view. Assigning extractView fires filterExtractChain through
   * onValueChanged, so the filtering itself stays in one place.
   */
  class setViewChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{view:string}} params 'all' | 'actual' | 'adjustment'
     */
    async run(context, { view }) {
      const { $page } = context;
      $page.variables.extractView = view || 'all';
    }
  }

  return setViewChain;
});
