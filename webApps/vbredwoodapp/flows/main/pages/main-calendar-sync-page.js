define([], () => {
  'use strict';

  /** PAGE-009 Calendar (Fusion Sync) — page module functions. */
  class PageModule {

    /**
     * What a scope key means for a given layer.
     *
     * Scope keys are exact strings and each layer keys on something different —
     * a country for CORPORATE, a customer for CLIENT, a project id for PROJECT,
     * an employee id for SHIFT. Getting that wrong returns an empty result that
     * looks like "the sync never ran", so the inspector says it up front.
     */
    scopeHintFor(layer) {
      switch (layer) {
        case 'CORPORATE': return 'Country of work, e.g. IN or GB';
        case 'PROJECT':   return 'Project id';
        case 'CLIENT':    return 'Customer name';
        case 'SHIFT':     return 'Employee id (PersonNumber)';
        default:          return 'Scope key';
      }
    }

    /** Accessible name for a layer's inspect button. */
    inspectLabel(layerLabel) {
      return 'Inspect ' + layerLabel;
    }


    /** Accessible name for a layer's sync button (ACT-030). */
    syncLabel(layerLabel) {
      return 'Sync ' + layerLabel + ' from Fusion';
    }


    /**
     * Open or close an oj-dialog by element id.
     *
     * oj-dialog has NO `opened` attribute — that is oj-drawer-popup. Binding
     * `opened="{{ ... }}"` therefore did nothing at all and every dialog on
     * this app was unopenable. JET exposes open()/close() methods instead, so
     * the boolean page variable stays the source of truth for logic and this
     * drives the component from it.
     */
    setDialog(dialogId, open) {
      const dlg = document.getElementById(dialogId);
      if (!dlg) { return; }
      if (open) { dlg.open(); } else { dlg.close(); }
    }

  }

  return PageModule;
});
