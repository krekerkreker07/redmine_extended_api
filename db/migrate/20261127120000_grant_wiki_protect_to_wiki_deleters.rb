# frozen_string_literal: true

# SPR-4686: `wiki.protect` (Lock Pages, SPR-522) is new, and the presets are read only when a
# tenant is imported, so on every tenant imported before nobody could lock a page until an
# administrator ticked it by hand. Every role that may already delete wiki pages (`wiki.delete`:
# the Administrator and Project Manager presets, and any custom role an administrator gave it)
# gets it once.
#
# Idempotent like every migration here (see 20261026120000): a role that already has the
# permission is skipped. A tenant not imported yet has no role model to top up.
class GrantWikiProtectToWikiDeleters < ActiveRecord::Migration[6.1]
  PERMISSION = 'wiki.protect'
  DELETERS = 'wiki.delete'

  def up
    store = RedmineExtendedApi::Sprintly::Store
    permissions = RedmineExtendedApi::Sprintly::Permissions
    data = store.read
    return unless data

    ids = data['roles'].keys.map(&:to_i)
    Role.givable.where(id: ids).each do |role|
      app_ids = permissions.app_ids_of(role)
      next unless app_ids.include?(DELETERS)
      next if app_ids.include?(PERMISSION)

      role.add_permission!(*permissions.redmine_permissions_for([PERMISSION]))
    end
  end

  def down
    # Taking it away again would also take it from roles an administrator ticked it on since.
  end
end
