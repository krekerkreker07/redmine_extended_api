# frozen_string_literal: true

require_relative 'permissions'
require_relative 'store'

module RedmineExtendedApi
  module Sprintly
    # SPR-383: the Sprintly role model on top of Redmine's.
    #
    #   global role   = the user's own roles ∪ their groups' roles, or the default role when
    #                   that is empty. Decides the permissions that belong to no project (chat,
    #                   dashboards, creating projects, the admin panel) and the Redmine `admin`
    #                   flag: whoever holds `admin.access` here is a Redmine administrator.
    #   project role  = the override set for that principal in that project, else its global
    #                   role. It is written into the principal's Redmine membership, so from
    #                   there on Redmine enforces it with its own machinery.
    #
    # A user who is in a project only through a group keeps exactly the group's roles there
    # (Redmine's inherited member roles) — the plugin never adds own roles to such a member.
    module Access
      class Error < StandardError; end

      # Refused because it would leave the tenant without a single administrator.
      class LockoutError < Error; end

      # The local account the tenant seed creates: `admin` on older tenants, `support-…` since
      # SPR-538. It is no person, the SPA hides it, and its admin flag is not the role model's
      # to take away.
      SERVICE_USER_ID = 1

      ADMIN_PERMISSION = 'admin.access'

      module_function

      def enabled?
        Store.initialized?
      end

      def managed_users
        User.where(type: 'User').where.not(id: SERVICE_USER_ID)
      end

      def managed?(user)
        user.is_a?(User) && user.logged? && user.id != SERVICE_USER_ID
      end

      # Assignments may still name a role deleted outside the SPA; those ids are ignored.
      def role_ids_in_use
        Role.givable.pluck(:id)
      end

      # ---- global role ------------------------------------------------------------------

      def global_role_ids(user, data = Store.read)
        return [] unless data && user.is_a?(User)

        ids = assigned_role_ids(user, data)
        ids = [data['default_role_id']].compact & role_ids_in_use if ids.empty?
        ids
      end

      # The user's own roles ∪ their groups' roles, without the default-role fallback.
      def assigned_role_ids(user, data)
        own = Array(data['users'][user.id.to_s])
        via_groups = user.groups.to_a.flat_map { |group| Array(data['groups'][group.id.to_s]) }
        (own + via_groups).uniq & role_ids_in_use
      end

      def group_role_ids(group, data = Store.read)
        return [] unless data

        ids = Array(data['groups'][group.id.to_s])
        ids = [data['default_role_id']].compact if ids.empty?
        ids & role_ids_in_use
      end

      def app_permissions_of_roles(roles)
        roles.flat_map { |role| Permissions.app_ids_of(role) }.uniq
      end

      def global_permissions(user, data = Store.read)
        app_permissions_of_roles(Role.where(id: global_role_ids(user, data)).to_a)
      end

      def admin_by_roles?(user, data = Store.read)
        global_permissions(user, data).include?(ADMIN_PERMISSION)
      end

      # What the SPA is told the user may do. The admin screens are core Redmine's, and core
      # checks the `admin` flag, not the role: when the two disagree — the flag taken away by
      # hand while the global role still holds `admin.access` (SPR-545, demo) — the SPA would
      # show screens whose every request answers 403. So `admin.*` goes only with the flag.
      def granted_permissions(user, ids)
        return ids if user.admin?

        ids.reject { |id| id.start_with?('admin.') }
      end

      # Roles of the user's memberships ∪ global roles — Redmine's "any of your roles" for
      # global checks, widened by the global role (UserPatch).
      def global_roles_for(user, data = Store.read)
        Role.where(id: global_role_ids(user, data)).to_a
      end

      # ---- default role -----------------------------------------------------------------

      # SPR-4660: the default role is what a newcomer starts with, not a setting they keep
      # following. The first time a user with no role of their own and none through a group is
      # seen — created, or signing in — it is pinned on them, the rule the SPA had before
      # SPR-383 (`pinFallbackRole`). Without the pin the Users screen showed them with no role,
      # and changing the default for the next newcomer moved everyone who relied on it.
      #
      # Their global role is the same before and after, so admin flags and memberships are left
      # as they are. Returns whether a pin was written.
      def pin_default_role!(user)
        return false unless managed?(user) && default_role_to_pin(user, Store.read)

        Store.update! do |data|
          role_id = default_role_to_pin(user, data)
          data['users'][user.id.to_s] = [role_id] if role_id
          role_id.present?
        end
      end

      def default_role_to_pin(user, data)
        return nil unless data

        role_id = data['default_role_id']
        return nil unless role_id && role_ids_in_use.include?(role_id)

        assigned_role_ids(user, data).empty? ? role_id : nil
      end

      # ---- project role -----------------------------------------------------------------

      def override_role_ids(project_id, principal, data)
        key = principal.is_a?(Group) ? 'groups' : 'users'
        Array(data.dig('projects', project_id.to_s, key, principal.id.to_s)) & role_ids_in_use
      end

      def desired_member_role_ids(member, data)
        principal = member.principal
        return [] unless principal

        override = override_role_ids(member.project_id, principal, data)
        return override if override.any?

        principal.is_a?(Group) ? group_role_ids(principal, data) : global_role_ids(principal, data)
      end

      def project_permissions(user, project)
        return [] unless project

        app_permissions_of_roles(user.roles_for_project(project))
      end

      # ---- writing memberships and admin flags ---------------------------------------------

      def sync_member!(member, data = Store.read)
        return false unless data
        return false if member.project_id.nil? || member.principal.nil?
        return false if member.principal.is_a?(User) && !managed?(member.principal)

        own = member.member_roles.reject(&:inherited_from)
        # In the project only through a group: the group's roles are the answer there.
        return false if own.empty? && member.member_roles.any?

        desired = desired_member_role_ids(member, data)
        return false if desired.empty? || own.map(&:role_id).sort == desired.sort

        member.role_ids = desired
        member.save!
        true
      end

      def sync_memberships!(data = Store.read, project_id: nil, principal_ids: nil)
        scope = Member.preload(:member_roles, :principal)
        scope = scope.where(project_id: project_id) if project_id
        scope = scope.where(user_id: principal_ids) if principal_ids
        scope.to_a.count { |member| sync_member!(member, data) }
      end

      # Users whose global role (and so admin flag and own memberships) depends on these
      # principals: the users themselves and everyone in the groups.
      def affected_user_ids(user_ids: [], group_ids: [])
        ids = Array(user_ids).map(&:to_i)
        ids += Group.where(id: group_ids).flat_map(&:user_ids) if group_ids.present?
        ids.uniq
      end

      # Sets `admin` from the role model. Raises LockoutError, writing nothing, when the
      # result would leave no administrator among the managed users.
      def sync_admin_flags!(data = Store.read, user_ids: nil)
        return [] unless data

        users = managed_users.where(status: [User::STATUS_ACTIVE, User::STATUS_REGISTERED, User::STATUS_LOCKED])
        users = users.where(id: user_ids) if user_ids
        changes = users.to_a.filter_map do |user|
          desired = admin_by_roles?(user, data)
          [user, desired] unless user.admin? == desired
        end
        return [] if changes.empty?

        promoted = changes.select { |_, admin| admin }.map { |user, _| user.id }
        demoted = changes.reject { |_, admin| admin }.map { |user, _| user.id }
        remaining = managed_users.active.where(admin: true).where.not(id: demoted).pluck(:id) | promoted
        raise LockoutError, 'at least one active administrator must remain' if remaining.empty?

        changes.each { |user, admin| user.update_column(:admin, admin) }
        changes.map(&:first)
      end

      # The global role of these principals changed: their memberships and admin flags follow.
      def resync_principals!(data, user_ids: [], group_ids: [])
        affected = affected_user_ids(user_ids: user_ids, group_ids: group_ids)
        sync_admin_flags!(data, user_ids: affected) if affected.any?
        sync_memberships!(data, principal_ids: affected + Array(group_ids).map(&:to_i)) if affected.any? || group_ids.present?
      end

      # ---- roles ----------------------------------------------------------------------------

      def save_role!(role, attrs, data)
        role ||= Role.new
        app_ids = Array(attrs['permissions']).map(&:to_s).select { |id| Permissions.valid_id?(id) }.uniq
        role.name = attrs['name'].to_s.strip if attrs.key?('name')
        role.position = attrs['position'].to_i if attrs['position'].present?
        Permissions.role_attributes_for(app_ids).each { |key, value| role.send(:"#{key}=", value) }
        role.permissions = Permissions.redmine_permissions_for(app_ids)
        role.save!

        meta = data['roles'][role.id.to_s] || {}
        meta['description'] = attrs['description'].to_s if attrs.key?('description')
        meta['preset'] = attrs['preset'].to_s.presence if attrs.key?('preset')
        data['roles'][role.id.to_s] = meta.compact
        role
      end

      def forget_role!(role_id, data)
        rid = role_id.to_i
        %w[users groups].each do |key|
          data[key].each_value { |ids| ids.delete(rid) }
          data[key].reject! { |_, ids| ids.empty? }
        end
        data['projects'].each_value do |scope|
          %w[users groups].each do |key|
            scope[key].each_value { |ids| ids.delete(rid) }
            scope[key].reject! { |_, ids| ids.empty? }
          end
        end
        data['default_role_id'] = nil if data['default_role_id'] == rid
        data['roles'].delete(rid.to_s)
      end

      def role_payload(role, data)
        meta = data ? data['roles'][role.id.to_s] || {} : {}
        {
          id: role.id,
          name: role.name,
          position: role.position,
          description: meta['description'].to_s,
          preset: meta['preset'],
          permissions: Permissions.app_ids_of(role)
        }
      end

      # ---- import ---------------------------------------------------------------------------

      # Switches the tenant over from the SPA's `welcome_text` config. The SPA sends that config
      # already migrated (it owns those migrations); roles are matched to existing Redmine roles
      # by name, so re-running it is harmless.
      #
      #   { roles: [{ key, name, description, permissions, preset }], users: { uid: [key] },
      #     groups: { gid: [key] }, default_role: key, projects: { pid: { users:, groups: } },
      #     company_icon: ... }
      def import!(payload)
        payload = payload.to_h.deep_stringify_keys
        Role.transaction do
          Store.update! do |data|
            ids_by_key = {}
            Array(payload['roles']).each_with_index do |spec, index|
              name = spec['name'].to_s.strip
              next if name.blank?

              role = Role.givable.detect { |r| r.name.casecmp?(name) }
              role = save_role!(role, spec.merge('position' => index + 1), data)
              ids_by_key[spec['key'].to_s] = role.id
            end

            map_keys = ->(keys) { Array(keys).filter_map { |k| ids_by_key[k.to_s] }.uniq }
            data['users'] = (payload['users'] || {}).transform_values { |keys| map_keys.call(keys) }
            data['groups'] = (payload['groups'] || {}).transform_values { |keys| map_keys.call(keys) }
            data['default_role_id'] = ids_by_key[payload['default_role'].to_s]
            data['projects'] = (payload['projects'] || {}).transform_values do |scope|
              scope = scope.to_h
              {
                'users' => (scope['users'] || {}).transform_values { |keys| map_keys.call(keys) },
                'groups' => (scope['groups'] || {}).transform_values { |keys| map_keys.call(keys) }
              }
            end
            data['company_icon'] = payload['company_icon'] if payload.key?('company_icon')
            data['imported_at'] = Time.now.utc.iso8601
            data['builtin_backup'] ||= close_builtin_roles!
            data.replace(Store.normalize(data))

            sync_admin_flags!(data)
            sync_memberships!(data)
            ids_by_key
          end
        end
      end

      # The SPA has no guest access (SPR-370 was reverted), so non-members of a public project
      # and anonymous visitors get nothing. Returns what the built-in roles had, for rollback.
      def close_builtin_roles!
        [Role.non_member, Role.anonymous].each_with_object({}) do |role, backup|
          backup[role.builtin.to_s] = Array(role.permissions).map(&:to_s)
          role.permissions = []
          role.save!
        end
      end

      # A tenant nobody administers yet (fresh, before the import) hands the role to the first
      # person who signs in — the same rule the SPA had for its very first user.
      def bootstrap_admin!(user)
        return false if enabled? || !managed?(user) || user.admin?
        return false if managed_users.active.where(admin: true).exists?

        user.update_column(:admin, true)
        true
      end
    end
  end
end
