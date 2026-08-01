/* PAGE-012 Integrations — prove the Fusion backend answers */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * One request to HCM for one worker, through VB's server-side proxy.
   *
   * The value is in the diagnosis, not the data. Every way this can fail means
   * something different and needs a different person to fix it, so each status
   * gets its own sentence rather than "the call failed":
   *
   *   401  the proxy reached Fusion; the credentials were refused        -> VB Studio backend auth
   *   403  authenticated, but the account lacks the HCM data role        -> Fusion security console
   *   404  wrong resource path or REST version for this pod             -> catalog.json / service.json
   *   0    the proxy itself never answered                              -> backend not published
   *
   * PersonNumber is reported back because OC_TIME_WORKER.EMPLOYEE_ID holds the
   * same value — seeing one proves the two systems agree on the key, which is
   * the thing INT-001 actually depends on.
   */
  class testFusionChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      $page.variables.probing = true;
      $page.variables.probeState = '';
      $page.variables.probeMessage = '';

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'fa_hcm/probeWorkers',
          uriParams: { limit: 1, onlyData: true, fields: 'PersonNumber,PersonId' },
        });

        if (resp.ok) {
          const items = (resp.body && resp.body.items) || [];
          const who = items.length ? items[0].PersonNumber : null;

          $page.variables.probeState = 'ok';
          $page.variables.probeMessage = who
            ? 'HCM answered. Sample PersonNumber ' + who +
              ' — the same key OC_TIME_WORKER.EMPLOYEE_ID uses, so the two ' +
              'systems agree on identity.'
            : 'HCM answered, but returned no workers. The connection is good; ' +
              'the service account may be scoped to a population that is empty.';
          return;
        }

        $page.variables.probeState = 'fail';
        $page.variables.probeMessage =
          $page.functions.probeDiagnosis(resp.status);

      } catch (e) {
        // No status at all: the request did not complete. Usually the backend
        // has been configured in Designer but not published, so the runtime has
        // nothing to resolve vb-catalog://backends/fa/hcm against.
        $page.variables.probeState = 'fail';
        $page.variables.probeMessage = $page.functions.probeDiagnosis(0);
      } finally {
        $page.variables.probing = false;
      }
    }
  }

  return testFusionChain;
});
