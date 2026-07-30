/* PAGE-003 Team Approvals — confirm advance-approving a future month (ACT-024) */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Advance approval approves time that has not been worked yet and tags the
   * month "Advance closure", after which actuals arrive as flagged
   * adjustments. That is a finance decision, not a routine click.
   */
  class askAdvanceApproveChain extends ActionChain {

    async run(context) {
      const { $page, $application } = context;

      const projectId = $page.variables.advanceProjectId;
      if (!projectId) { return; }

      const project = ($page.variables.projectsRaw || [])
        .find((p) => p.projectId === projectId);
      const name = project ? project.projectName : 'this project';

      $page.variables.confirmMessage = 'Advance-approve ' + name + ' for ' +
        $application.variables.selectedPeriodName +
        '? The month will be approved for every employee on the project and ' +
        'tagged "Advance closure". Actual hours entered later will come ' +
        'through as flagged adjustments.';

      await Actions.callComponentMethod(context, {
        selector: '#advanceApproveDlg',
        method: 'open',
      });
    }
  }

  return askAdvanceApproveChain;
});
