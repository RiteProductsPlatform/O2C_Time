/* PAGE-006 Leave Loss Coverage — open the assign dialog */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads the eligible-cover LOV for THIS absence date.
   *
   * The list is date-specific: someone free on Tuesday may be absent or already
   * covering on Wednesday, so it cannot be cached across rows. RULE-014 is
   * applied by the server view, not here, so the same filter governs the LOV and
   * the assign call.
   */
  class openAssignChain extends ActionChain {

    /**
     * @param {Object} context
     * @param {{llcId:number, absenceDate:string, label:string}} params
     */
    async run(context, { row } = {}) {
      const { $page, $application } = context;

      // The row whole, not pre-extracted fields: the label is built by a page
      // function, and a listener parameter cannot invoke one. It used to be
      // computed inside an inline handler that was never wired up.
      if (!row) { return; }

      const llcId       = row.llcId;
      const absenceDate = row.absenceDate;
      const label       = $page.functions.absenceLabel(row);

      if (!llcId) { return; }

      $page.variables.assignLlcId       = llcId;
      $page.variables.assignLabel       = label || '';
      $page.variables.assignCoverId     = '';
      $page.variables.coverOptionsArray = [];
      $page.variables.showAssign        = true;
      $page.functions.setDialog('assignDlg', true);

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getLlcCover',
          uriParams: {
            projectId: $page.variables.projectId,
            absenceDate: absenceDate,
            _t: Date.now(),
          },
        });

        if (resp.ok && resp.body && resp.body.items) {
          $page.variables.coverOptionsArray = resp.body.items.map((c) => ({
            value: c.value,
            label: c.label + (c.client_role ? ' (' + c.client_role + ')' : ''),
            clientRole: c.client_role || '',
          }));
        } else {
          await Actions.fireNotificationEvent(context, {
            summary: 'Eligible colleagues unavailable',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }
      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: $application.functions.chainSummary(e, 'Eligible colleagues unavailable'),
          message: $application.functions.chainError(e, 'Could not load the eligible colleagues — the service is unreachable.'),
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      }
    }
  }

  return openAssignChain;
});
