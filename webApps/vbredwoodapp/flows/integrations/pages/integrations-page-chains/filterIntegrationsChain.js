/* PAGE-012 Integrations — area filter */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Filters the cached catalogue by area.
   *
   * Client-side because the catalogue is a handful of rows; refetching on every
   * change of a dropdown would be a round-trip for nothing.
   */
  class filterIntegrationsChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      const all  = $page.variables.rowsRaw || [];
      const area = $page.variables.areaFilter || '';

      $page.variables.rows = !area
        ? all.slice()
        : all.filter((i) => i.area === area);
    }
  }

  return filterIntegrationsChain;
});
