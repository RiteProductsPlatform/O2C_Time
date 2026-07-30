/* PAGE-009 Calendar — load the four layer rows */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Loads one summary row per calendar layer.
   *
   * A layer with no rows simply does not come back from the view, which would
   * silently hide it. The four layers are therefore always rendered, with the
   * missing ones shown as empty — an admin needs to see that Shift has never been
   * synced, not just fail to see Shift at all.
   */
  class loadLayersChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      $page.variables.busy = true;

      const TEMPLATE = [
        { layer: 'SHIFT',     layerLabel: 'Shift',
          sourceDescription: 'HCM Work Schedules — one shift per employee per day',
          precedence: 4, scopeHint: 'Employee id (PersonNumber)' },
        { layer: 'CLIENT',    layerLabel: 'Client Holiday',
          sourceDescription: 'CRM / Client — client site closures',
          precedence: 3, scopeHint: 'Customer name' },
        { layer: 'PROJECT',   layerLabel: 'Project Standard Hours',
          sourceDescription: 'Fusion PPM — project standard hours, country-wise',
          precedence: 2, scopeHint: 'Project id' },
        { layer: 'CORPORATE', layerLabel: 'Corporate + standard hours',
          sourceDescription: 'HCM / Corporate — country work days & holidays',
          precedence: 1, scopeHint: 'Country of work, e.g. IN or GB' },
      ];

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getCalendarLayers',
          uriParams: { _t: Date.now() },
        });

        const loaded = {};
        if (resp.ok && resp.body && resp.body.items) {
          resp.body.items.forEach((l) => { loaded[l.layer] = l; });
        } else if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Layers unavailable',
            message: 'Could not load the calendar layers: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
        }

        $page.variables.layers = TEMPLATE.map((t) => {
          const l = loaded[t.layer];
          return {
            layer: t.layer,
            layerLabel: (l && l.layer_label) || t.layerLabel,
            sourceDescription: (l && l.source_description) || t.sourceDescription,
            precedence: t.precedence,
            scopeHint: t.scopeHint,
            dayCount: (l && l.day_count) || 0,
            scopeCount: (l && l.scope_count) || 0,
            fromDate: (l && l.from_date) || '—',
            toDate: (l && l.to_date) || '—',
            sourceSystem: (l && l.source_system) || '—',
            lastSyncedOn: (l && l.last_synced_on) || '',
            nonWorkingDays: (l && l.non_working_days) || 0,
          };
        });

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Layers unavailable',
          message: 'The calendar service is unreachable.',
          severity: 'error',
          type: 'error',
          displayMode: 'transient',
        });
      } finally {
        $page.variables.busy = false;
      }
    }
  }

  return loadLayersChain;
});
