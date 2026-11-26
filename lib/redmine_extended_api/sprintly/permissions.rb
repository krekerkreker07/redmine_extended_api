# frozen_string_literal: true

module RedmineExtendedApi
  module Sprintly
    # SPR-383: the permission catalogue of the Sprintly SPA, mirrored on the server.
    #
    # Every SPA permission id (`issues.view`, `reports.agile.cfd`, ...) is stored on a Redmine
    # role as its own permission symbol — `sprintly__issues__view` — so the role keeps exactly
    # what the Roles screen saved, and `User#allowed_to?` answers for it like for any core
    # permission (project modules, archived projects and group memberships included).
    #
    # Next to those, a role carries the core permissions they imply (DERIVED), which is what
    # makes Redmine itself enforce the role: `issues.view` brings `view_issues`, and so on.
    # The derived set is recomputed on every save; it is never edited on its own.
    module Permissions
      PREFIX = 'sprintly__'

      # Keep in step with PERMISSION_CATEGORIES in tracker-ui (core/models/role.model.ts).
      # An id the SPA sends that is not listed here is still stored (see `valid_id?`), it just
      # gets no Redmine label and implies no core permission.
      APP_PERMISSIONS = %w[
        sections.dashboards sections.board sections.backlog sections.issues sections.gantt
        sections.calendar sections.wiki sections.reports sections.time_reports sections.sprints
        sections.gists sections.chat sections.filters
        issues.view issues.create issues.edit issues.delete issues.add_notes
        issues.view_private_notes issues.view_private issues.manage_relations issues.manage_subtasks
        issues.change_status issues.assign issues.change_priority issues.set_sprint issues.log_time
        sprints.view sprints.create sprints.edit sprints.start sprints.complete sprints.delete
        reports.project.overview reports.project.time reports.project.user reports.project.version
        reports.project.created_resolved reports.project.age reports.project.pie reports.project.resolution
        reports.agile.burndown reports.agile.burnup reports.agile.sprint_report reports.agile.velocity
        reports.agile.cfd reports.agile.control reports.agile.version
        wiki.view wiki.create wiki.edit wiki.delete wiki.protect
        time.view time.view_others time.log time.edit time.edit_own time.delete
        projects.view projects.create projects.edit projects.manage_members projects.manage_versions
        projects.manage_integrations
        admin.access admin.settings admin.users admin.groups admin.roles admin.trackers
        admin.statuses admin.priorities admin.custom_fields
        chat.view chat.send chat.edit_own chat.delete_own chat.attach chat.create_channel
        chat.rename_channel chat.join_channel chat.invite chat.create_dm
        gists.view gists.create gists.edit gists.delete
      ].freeze

      # The core Redmine permissions each SPA permission switches on. Sections, reports, chat
      # and the admin sub-screens have none: they are views the SPA computes or a service
      # Redmine does not run, and the SPA checks them itself.
      DERIVED = {
        'sections.calendar' => %i[view_calendar],
        'sections.gantt' => %i[view_gantt],
        'sections.filters' => %i[save_queries],
        # Watching an issue yourself needs no more than seeing it, as in Jira; managing other
        # people as watchers is `issues.assign`, checked in WatchersControllerPatch.
        'issues.view' => %i[view_issues view_issue_watchers add_issue_watchers delete_issue_watchers],
        'issues.create' => %i[add_issues copy_issues import_issues set_own_issues_private],
        'issues.edit' => %i[edit_issues set_issues_private set_own_issues_private],
        # Redmine lets an existing issue be changed only with `edit_issues`; these four bring it
        # too, and IssuePatch keeps every other field read-only without `issues.edit`.
        'issues.change_status' => %i[edit_issues],
        'issues.assign' => %i[edit_issues],
        'issues.change_priority' => %i[edit_issues],
        'issues.set_sprint' => %i[edit_issues],
        'issues.delete' => %i[delete_issues],
        # SPR-117: a comment belongs to whoever wrote it — editing and deleting your own comes
        # with the right to comment, and there is no "any comment" grant to derive.
        'issues.add_notes' => %i[add_issue_notes edit_own_issue_notes delete_own_issue_notes set_notes_private],
        'issues.view_private_notes' => %i[view_private_notes],
        'issues.manage_relations' => %i[manage_issue_relations],
        'issues.manage_subtasks' => %i[manage_subtasks],
        'issues.log_time' => %i[log_time],
        'sprints.create' => %i[manage_versions],
        'sprints.edit' => %i[manage_versions],
        'sprints.start' => %i[manage_versions],
        'sprints.complete' => %i[manage_versions],
        'sprints.delete' => %i[manage_versions],
        'projects.manage_versions' => %i[manage_versions],
        'wiki.view' => %i[view_wiki_pages view_wiki_edits export_wiki_pages],
        'wiki.create' => %i[edit_wiki_pages],
        'wiki.edit' => %i[edit_wiki_pages rename_wiki_pages],
        'wiki.delete' => %i[delete_wiki_pages delete_wiki_pages_attachments],
        # SPR-522: locking a page; a locked page is then editable only with this right.
        'wiki.protect' => %i[protect_wiki_pages],
        'time.view' => %i[view_time_entries],
        'time.log' => %i[log_time],
        'time.edit' => %i[edit_time_entries],
        'time.edit_own' => %i[edit_own_time_entries],
        # Redmine deletes only what the user may edit; TimelogControllerPatch then narrows
        # editing and deleting back to the SPA permissions.
        'time.delete' => %i[edit_time_entries],
        'projects.create' => %i[add_project add_subprojects],
        'projects.edit' => %i[edit_project select_project_modules select_project_publicity close_project
                              delete_project manage_categories manage_public_queries manage_project_activities],
        'projects.manage_members' => %i[manage_members],
        # Gists are files of the project's Files module.
        'gists.view' => %i[view_files],
        'gists.create' => %i[manage_files],
        'gists.edit' => %i[manage_files],
        'gists.delete' => %i[manage_files]
      }.freeze

      # Permissions that are not about any one project. In Redmine a "global" check accepts a
      # role from any membership; for these only the user's global roles count (UserPatch).
      GLOBAL_CORE = %i[add_project add_subprojects].freeze

      ID_FORMAT = /\A[a-z0-9_]+(\.[a-z0-9_]+)+\z/

      module_function

      def valid_id?(app_id)
        app_id.is_a?(String) && ID_FORMAT.match?(app_id)
      end

      def symbol_for(app_id)
        :"#{PREFIX}#{app_id.to_s.gsub('.', '__')}"
      end

      def app_id_for(symbol)
        name = symbol.to_s
        return nil unless name.start_with?(PREFIX)

        name.delete_prefix(PREFIX).gsub('__', '.')
      end

      def app_ids_of(role)
        Array(role.permissions).filter_map { |perm| app_id_for(perm) }.uniq
      end

      def derived_for(app_ids)
        app_ids.flat_map { |id| DERIVED.fetch(id, []) }.uniq
      end

      # The full permission list a role is saved with.
      def redmine_permissions_for(app_ids)
        app_ids.map { |id| symbol_for(id) } + derived_for(app_ids)
      end

      # Role attributes that are not permissions in Redmine but are in the SPA.
      def role_attributes_for(app_ids)
        {
          issues_visibility: app_ids.include?('issues.view_private') ? 'all' : 'default',
          time_entries_visibility: app_ids.include?('time.view_others') ? 'all' : 'own',
          # Like Jira's "Browse users and groups": pickers list everybody in the tracker.
          users_visibility: 'all',
          assignable: true,
          all_roles_managed: true
        }
      end
    end
  end
end
