/* Copyright (c) 2026, Oracle and/or its affiliates */

define([
  'vb/action/actionChain',
  'vb/action/actions',
  'vb/action/actionUtils',
], (
  ActionChain,
  Actions,
) => {
  'use strict';

  /**
   * The single place notifications are rendered. Every page chain fires
   * Actions.fireNotificationEvent; that raises vbNotification, which lands here.
   *
   * Three details this chain has to get right, all of them consequences of JS
   * chains and JSON chains delivering different payloads:
   *
   *  1. `severity` is not forwarded by the JS Actions.fireNotificationEvent —
   *     only `type` is. Reading `event.severity || event.type` supports both
   *     chain styles, so a success never renders in error colours.
   *
   *  2. `displayMode` is likewise not forwarded from JS chains, so it arrives
   *     undefined. Testing `!== 'persist'` treats undefined as transient;
   *     testing `=== 'transient'` would be false every time and nothing would
   *     ever auto-dismiss.
   *
   *  3. The ADP key type must match the declared type. MessagesBannerType.id is
   *     a string, so ids are stored and removed as strings — a numeric key would
   *     not match on remove and the message could never be dismissed. messageId
   *     also carries a defaultValue, because `undefined + 1` is NaN and a NaN
   *     key matches nothing.
   */
  class showNotificationMessage extends ActionChain {

    /**
     * @param {Object} context
     * @param {Object} params
     * @param {{summary:string,message:string,displayMode:string,type:string,severity:string,key:string,target:string}} params.event
     */
    async run(context, { event }) {
      const { $page } = context;

      const notifType = event.severity || event.type || 'info';

      // Pages sheet, error_state_behavior: every page specifies "Toast error".
      // Transient messages therefore render in the toast; the banner is reserved
      // for anything explicitly marked persist, which is the one case a user has
      // to dismiss deliberately.
      if (event.displayMode !== 'persist') {
        $page.variables.messageToast = event.message || event.summary || '';

        await Actions.callComponentMethod(context, {
          selector: '#messageToast',
          method: 'open',
        });
        return;
      }

      const msgId = String($page.variables.messageId);
      $page.variables.messageId = String(parseInt($page.variables.messageId, 10) + 1);

      const msg = {
        id: msgId,
        messageType: notifType === 'confirmation' ? 'general-success' : 'general-' + notifType,
        primaryText: event.summary,
        secondaryText: event.message,
      };

      await Actions.fireDataProviderEvent(context, {
        target: $page.variables.messagesBannerADP,
        add: {
          data: msg,
        },
      });
    }
  }

  return showNotificationMessage;
});
