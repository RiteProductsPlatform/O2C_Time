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

    /** Probe button label. A page function rather than a ternary (S1). */
    probeLabel(probing) {
      return probing ? 'Testing\u2026' : 'Test connection';
    }

    /**
     * One sentence over the readiness rows: how many projects are blocked and
     * by what. The table gives the detail; this says whether it is worth
     * reading, which is the question someone opening the page actually has.
     */
    poetSummary(rows) {
      const list = rows || [];
      const blocked = list.filter((r) => r.otlReadiness === 'Blocked');

      if (!blocked.length) {
        return 'Every active project has a full POET. Nothing here blocks the '
             + 'OTL push.';
      }

      const tasks = blocked.reduce((n, r) => n + (r.tasksNoExpType || 0), 0);
      const staff = blocked.reduce((n, r) => n + (r.workersNoExpOrg || 0), 0);

      const parts = [];
      if (tasks) {
        parts.push(tasks + (tasks === 1 ? ' chargeable task has' : ' chargeable tasks have')
                 + ' no expenditure type');
      }
      if (staff) {
        parts.push(staff + (staff === 1 ? ' allocated worker has' : ' allocated workers have')
                 + ' no expenditure organization');
      }

      return blocked.length + ' of ' + list.length + ' projects cannot be pushed '
           + 'to OTL: ' + parts.join(', and ')
           + '. Both are set in Fusion, not here.';
    }

    /**
     * Map readiness onto the vocabulary outcomeClass() already understands, so
     * the badge matches every other status capsule in the module rather than
     * introducing a third palette.
     */
    readinessOutcome(readiness) {
      return readiness === 'Ready' ? 'Approved' : 'Held';
    }

    /**
     * Turn an HTTP status into the sentence that names who can fix it.
     *
     * Every one of these failures looks identical from the button, and each
     * needs a different person and a different console. Saying "the call
     * failed" would send whoever is holding this on a hunt.
     */
    probeDiagnosis(status) {
      switch (status) {
        case 401:
          return 'The proxy reached Fusion, but the credentials were refused ' +
                 '(401). Fix the fa backend\u2019s authentication in VB Studio \u2014 ' +
                 'Services \u203a Backends \u203a fa \u203a Settings.';
        case 403:
          return 'Authenticated, but this service account is not entitled to ' +
                 'read workers (403). It needs an HCM data role; that is a ' +
                 'change in the Fusion security console, not here.';
        case 404:
          return 'Fusion answered but the resource was not found (404). The ' +
                 'REST path or version in services/fa_hcm/service.json does ' +
                 'not match this pod \u2014 check /hcmRestApi/resources/11.13.18.05.';
        case 0:
          return 'The request never completed, so the proxy itself did not ' +
                 'answer. Most often the backend exists in Designer but has ' +
                 'not been published, leaving nothing for ' +
                 'vb-catalog://backends/fa/hcm to resolve against.';
        default:
          return 'Fusion returned ' + (status || 'no status') + '. The ' +
                 'connection reached something \u2014 check the Network tab for ' +
                 'the response body.';
      }
    }

  }

  return PageModule;
});
