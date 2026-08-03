/* PAGE-012 Integrations — what blocks the OTL push (INT-007 prerequisite) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Reads V_OC_TIME_POET_READINESS: per project, how many chargeable tasks have
   * no expenditure type and how many allocated workers no expenditure
   * organization.
   *
   * The counts come from the view rather than being derived here, so the number
   * on screen is the same one the push itself will act on. Deriving it in the
   * page would let the two disagree, and the whole point of this panel is to be
   * trusted about what will happen.
   */
  class loadPoetChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.busy = true;
      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getPoetReadiness',
          uriParams: { _t: Date.now() },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Readiness unavailable',
            message: $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        $page.variables.poet = ((resp.body && resp.body.items) || []).map((r) => ({
          projectId:        r.project_id,
          projectNumber:    r.project_number,
          projectName:      r.project_name,
          tasksChargeable:  r.tasks_chargeable || 0,
          tasksNoExpType:   r.tasks_no_exp_type || 0,
          tasksUnresolvable: r.tasks_unresolvable || 0,
          workersAllocated: r.workers_allocated || 0,
          workersNoExpOrg:  r.workers_no_exp_org || 0,
          otlReadiness:     r.otl_readiness,
        }));

      } catch (e) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Readiness unavailable',
          message: 'The service was unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadPoetChain;
});
