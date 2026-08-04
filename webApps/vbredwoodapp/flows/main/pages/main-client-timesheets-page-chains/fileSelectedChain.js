/* PAGE-011 Client timesheets — a file was picked */

define(['vb/action/actionChain'], (ActionChain) => {
  'use strict';

  /**
   * Hands the picked file to the page module, which reads and base64-encodes it.
   *
   * A declared listener rather than an inline function in the markup: an inline
   * function literal in a binding is never wired up (S1), so the picker looked
   * like it accepted a file and then nothing happened. The file list is taken
   * from $event.detail.files in the listener declaration, so the page function
   * never has to know the shape of a JET event.
   */
  class fileSelectedChain extends ActionChain {
    async run(context, { files } = {}) {
      const { $page } = context;
      $page.functions.fileSelected($page.variables, files);
    }
  }

  return fileSelectedChain;
});
