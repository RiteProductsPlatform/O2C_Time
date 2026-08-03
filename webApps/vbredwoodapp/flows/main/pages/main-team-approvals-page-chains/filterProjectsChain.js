/* PAGE-003 Team Approvals — FLD-028 project filter */

define([
  'vb/action/actionChain',
], (
  ActionChain
) => {
  'use strict';

  /**
   * Derives the visible project rows from the cached full list.
   *
   * Filtering client-side from projectsRaw rather than refetching means the
   * filter responds on every keystroke and a slow network cannot make the table
   * flicker or empty while the user is still typing.
   *
   * Matches on both name and number, because managers refer to projects by
   * either.
   */
  class filterProjectsChain extends ActionChain {

    async run(context) {
      const { $page } = context;

      const all  = $page.variables.projectsRaw || [];
      const pick = $page.variables.projectPick;

      // null means "All projects" — the placeholder on the select, and what a
      // cleared LOV reports.
      $page.variables.projects = (pick === null || pick === undefined || pick === '')
        ? all.slice()
        : all.filter((p) => p.projectId === pick);
    }
  }

  return filterProjectsChain;
});
