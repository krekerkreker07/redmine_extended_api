# frozen_string_literal: true

# SPR-4669: `projects.manage_integrations` is new — adding a VCS integration to a project. It is a
# project setting, so every role that may already edit the project's settings (`projects.edit`:
# the Administrator and Project Manager presets, and any custom role an administrator gave it)
# gets it once, instead of leaving integrations to Redmine administrators until somebody edits
# the roles. Roles imported later take it from the SPA's presets.
#
# Idempotent like every migration here (see 20261026120000): a role that already has the
# permission is skipped. A tenant not imported yet has no role model to top up.
class GrantIntegrationsToProjectEditors < ActiveRecord::Migration[6.1]
  PERMISSION = 'projects.manage_integrations'
  EDITORS = 'projects.edit'

  def up
    store = RedmineExtendedApi::Sprintly::Store
    permissions = RedmineExtendedApi::Sprintly::Permissions
    data = store.read
    return unless data

    ids = data['roles'].keys.map(&:to_i)
    Role.givable.where(id: ids).each do |role|
      app_ids = permissions.app_ids_of(role)
      next unless app_ids.include?(EDITORS)
      next if app_ids.include?(PERMISSION)

      role.add_permission!(*permissions.redmine_permissions_for([PERMISSION]))
    end
  end

  def down
    # Taking it away again would also take it from roles an administrator ticked it on since.
  end
end
