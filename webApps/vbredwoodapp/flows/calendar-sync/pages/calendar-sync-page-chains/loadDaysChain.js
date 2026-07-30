/* PAGE-009 Calendar — load days for one layer + scope */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  class loadDaysChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const layer = $page.variables.inspectLayer;
      const scope = $page.variables.inspectScope;

      if (!layer || !scope) { return; }

      $page.variables.busy = true;

      try {
        const resp = await Actions.callRest(context, {
          endpoint: 'oc_time/getCalendarDays',
          uriParams: {
            layer: layer,
            scopeKey: scope,
            fromDate: $page.variables.inspectFrom,
            toDate: $page.variables.inspectTo,
            _t: Date.now(),
          },
        });

        if (!resp.ok) {
          await Actions.fireNotificationEvent(context, {
            summary: 'Days unavailable',
            message: 'Could not load the calendar days: ' +
                     $application.functions.restError(resp),
            severity: 'error',
            type: 'error',
            displayMode: 'transient',
          });
          return;
        }

        const rows = ((resp.body && resp.body.items) || []).map((d) => ({
          calendarId: d.calendar_id,
          calDate: d.cal_date,
          dayName: d.day_name,
          isWorkingDay: d.is_working_day,
          stdHours: d.std_hours,
          holidayName: d.holiday_name || '',
          shiftCode: d.shift_code || '',
          sourceSystem: d.source_system || '',
          syncedOn: d.synced_on || '',
        }));

        $page.variables.days = rows;

        if (!rows.length) {
          // An empty result reads like "the sync never ran", when the usual
          // cause is a mistyped scope key — so say which it might be.
          await Actions.fireNotificationEvent(context, {
            summary: 'No days found',
            message: 'Nothing for that scope key in this range. Scope keys are exact — ' +
                     $page.functions.scopeHintFor(layer) + '.',
            severity: 'warning',
            type: 'warning',
            displayMode: 'transient',
          });
        }

      } catch (e) {
        // JET aborts in-flight requests on re-render; that is not a failure.
        if ($application.functions.isAbortError(e)) { return; }

        await Actions.fireNotificationEvent(context, {
          summary: 'Days unavailable',
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

  return loadDaysChain;
});
