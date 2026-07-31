/* PAGE-001 My Timesheet — ACT-003 Add Line */

define([
  'vb/action/actionChain',
  'vb/action/actions',
], (
  ActionChain,
  Actions
) => {
  'use strict';

  /**
   * Adds a project-task line to the grid.
   *
   * The line is created client-side with zero hours and is NOT written to the
   * server yet: an empty line has nothing to persist, and creating a row of
   * zeros on every "Add line" would litter the week with entries the user then
   * has to remove. It becomes real on the first hour entered plus Save draft.
   *
   * Multi-line / multi-task per day is expressly supported (SC-03), so the only
   * thing rejected is the exact same project+task twice — which would give two
   * rows the grid cannot tell apart.
   */
  class addLineChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      const projectId = $page.variables.newLineProjectId;
      const taskId    = $page.variables.newLineTaskId;

      // Validated before anything is added, per the checklist.
      if (!projectId || !taskId) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Incomplete',
          message: 'Select both a project and a task.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        return;
      }

      const rowKey = projectId + '|' + taskId;
      const rows   = ($page.variables.gridRows || []).slice();

      if (rows.some((r) => r.rowKey === rowKey)) {
        await Actions.fireNotificationEvent(context, {
          summary: 'Already on the grid',
          message: 'That project and task are already on the grid — enter the hours on the existing line.',
          severity: 'warning',
          type: 'warning',
          displayMode: 'transient',
        });
        $page.variables.showAddLine = false;
        return;
      }

      const projects = $page.variables.projectOptionsArray || [];
      const tasks    = $page.variables.taskOptionsArray || [];

      const proj = projects.find((p) => p.value === projectId) || {};
      const task = tasks.find((t) => t.value === taskId) || {};

      // The dialog decorates non-billable tasks with a suffix; strip it so the
      // grid shows the plain task name.
      const plainTaskName = (task.label || '').replace('  (non-billable)', '');

      const row = {
        rowKey: rowKey,
        projectId: projectId,
        projectNumber: '',
        projectName: proj.label || '',
        projectType: proj.projectType || 'Billable',
        taskId: taskId,
        taskCode: '',
        taskName: plainTaskName,
        taskType: task.taskGroup === 'WBS' ? 'WBS' : 'COMMON',
        billableType: task.billableType || 'Billable',
        // RULE-002: for a common non-billable task the task IS the reason, so it
        // is seeded here rather than asked for again.
        unbilledReason: task.billableType === 'Non-billable' ? plainTaskName : null,
        isLeave: 'N',
        lineTotal: 0,
        lineStatus: 'Pending',
        readOnly: false,
      };

      for (let i = 0; i < 7; i++) { row['d' + i] = 0; }

      rows.push(row);

      // Assigning gridRows is enough — gridADP is live-bound to it.
      $page.variables.gridRows = rows;

      $page.variables.showAddLine      = false;
      $page.variables.newLineProjectId = null;
      $page.variables.newLineTaskId    = null;

      await Actions.fireNotificationEvent(context, {
        summary: 'Line added',
        message: 'Enter the hours and save.',
        severity: 'confirmation',
        type: 'confirmation',
        displayMode: 'transient',
      });
    }
  }

  return addLineChain;
});
