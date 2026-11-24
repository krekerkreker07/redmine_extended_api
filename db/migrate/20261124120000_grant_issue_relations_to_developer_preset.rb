# frozen_string_literal: true

# SPR-730: the Developer preset shipped without `issues.manage_relations`, so a developer could
# not link two issues (403 on POST /issues/:id/relations) — only administrators and project
# managers could. The preset in the SPA now has it, but the preset is read only when a tenant
# is imported; roles imported before keep what they were created with. This tops up the roles
# that came from the Developer preset, once per tenant.
#
# A role still lacking the permission is the old preset, not a choice: nothing in the SPA said
# otherwise before this release. Custom roles are left alone. A tenant not imported yet has no
# role model to fix — it imports the new preset.
#
# Idempotent like every migration here (see 20261026120000): a role that already has the
# permission is skipped, so a dump without its schema_migrations row runs it again harmlessly.
class GrantIssueRelationsToDeveloperPreset < ActiveRecord::Migration[6.1]
  PERMISSION = 'issues.manage_relations'

  def up
    store = RedmineExtendedApi::Sprintly::Store
    permissions = RedmineExtendedApi::Sprintly::Permissions
    data = store.read
    return unless data

    ids = data['roles'].select { |_, meta| meta['preset'] == 'developer' }.keys.map(&:to_i)
    Role.givable.where(id: ids).each do |role|
      next if permissions.app_ids_of(role).include?(PERMISSION)

      role.add_permission!(*permissions.redmine_permissions_for([PERMISSION]))
    end
  end

  def down
    # Taking it away again would also take it from roles an administrator ticked it on since.
  end
end
