/* PAGE-009 Calendar — open the day inspector */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Defaults the date range to the current month, which is what an admin
   * checking "did the sync land?" almost always wants to see.
   */
  class openInspectChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{layer:string, scopeHint:string}} params
     */
    async run(context, { layer }) {
      const { $page } = context;

      const now   = new Date();
      const pad   = (n) => String(n).padStart(2, '0');
      const first = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-01';
      const last  = new Date(now.getFullYear(), now.getMonth() + 1, 0);
      const lastS = last.getFullYear() + '-' + pad(last.getMonth() + 1) + '-' +
                    pad(last.getDate());

      $page.variables.inspectLayer = layer;
      $page.variables.inspectScope = '';
      $page.variables.inspectFrom  = first;
      $page.variables.inspectTo    = lastS;
      $page.variables.days         = [];
      $page.variables.showInspect  = true;
      $page.functions.setDialog('inspectDlg', true);
    }
  }

  return openInspectChain;
});
