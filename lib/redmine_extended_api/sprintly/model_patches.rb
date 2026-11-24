# frozen_string_literal: true

require_relative 'access'

module RedmineExtendedApi
  module Sprintly
    # SPR-383: model-level enforcement of the Sprintly permissions that have no core
    # counterpart. Every patch is inert until the tenant is switched over (Access.enabled?).
    module ModelPatches
      def self.active_for?(user)
        user.is_a?(User) && !user.admin? && Access.enabled?
      end

      module IssuePatch
        # Status changes. The product does not configure workflows: the transitions are seeded
        # once and administrators get all of them. Whoever may change status gets the same
        # list; whoever may not keeps the issue in its status.
        private def roles_for_workflow(user)
          return super unless ModelPatches.active_for?(user)
          return [] unless project && user.allowed_to?(Permissions.symbol_for('issues.change_status'), project)

          Role.all.to_a.select(&:consider_workflow?)
        end

        FIELD_PERMISSIONS = {
          'issues.assign' => 'assigned_to_id',
          'issues.change_priority' => 'priority_id',
          'issues.set_sprint' => 'fixed_version_id'
        }.freeze

        # Assignee, priority and sprint are editable only with their own permission, on new
        # issues too (as in Jira). Every other field of an existing issue needs `issues.edit` —
        # `edit_issues` alone may have come from one of the narrower permissions. Redmine drops
        # read-only attributes from an update, so the permitted part of an edit still goes through.
        def read_only_attribute_names(user = nil)
          names = super
          user ||= User.current
          return names unless ModelPatches.active_for?(user) && project

          FIELD_PERMISSIONS.each do |app_id, attribute|
            names |= [attribute] unless user.allowed_to?(Permissions.symbol_for(app_id), project)
          end
          if !new_record? && !user.allowed_to?(Permissions.symbol_for('issues.edit'), project)
            names |= Tracker::CORE_FIELDS_ALL - FIELD_PERMISSIONS.values
            names |= available_custom_fields.map { |field| field.id.to_s }
          end
          names
        end
      end

      module UserPatch
        def self.prepended(base)
          base.after_create_commit :sprintly_pin_default_role
        end

        # Global checks (no project): Redmine accepts a role from any membership. Sprintly adds
        # the global role to those, and for creating projects counts the global role only — in
        # Jira terms it is a global permission, not something a project role can lend you.
        def allowed_to?(action, context, options = {}, &block)
          return super unless context.nil? && options[:global] && ModelPatches.active_for?(self)

          roles = Access.global_roles_for(self)
          roles |= self.roles.to_a | [builtin_role] unless sprintly_global_only?(action)
          roles.any? { |role| role.allowed_to?(action) && (block ? yield(role, self) : true) }
        end

        private

        # SPR-4660: a new account starts on the default role, pinned (Access.pin_default_role!).
        def sprintly_pin_default_role
          Access.pin_default_role!(self)
        rescue StandardError => e
          Rails.logger.error "Sprintly: could not pin the default role on user #{id}: #{e.message}"
        end

        # `authorize_global` passes a controller/action hash; it is global-only when every
        # permission covering that action is.
        def sprintly_global_only?(action)
          names =
            if action.is_a?(Hash)
              key = "#{action[:controller]}/#{action[:action]}"
              Redmine::AccessControl.permissions.select { |p| p.actions.include?(key) }.map(&:name)
            else
              [action.to_sym]
            end
          names.any? && (names - Permissions::GLOBAL_CORE).empty?
        end
      end

      module MemberPatch
        def self.included(base)
          base.after_create_commit :sprintly_sync_roles
        end

        private

        # A member added through the API comes with whatever role the caller picked; the role
        # model decides what it actually holds.
        def sprintly_sync_roles
          return unless Access.enabled?

          Access.sync_member!(Member.preload(:member_roles, :principal).find_by(id: id))
        rescue StandardError => e
          Rails.logger.error "Sprintly: could not sync member #{id}: #{e.message}"
        end
      end

      module GroupPatch
        # Joining or leaving a group changes the user's global role: admin flag and own
        # memberships follow.
        def user_added(user)
          super
          sprintly_resync(user)
        end

        def user_removed(user)
          super
          sprintly_resync(user)
        end

        private

        def sprintly_resync(user)
          return unless Access.enabled?

          data = Store.read
          Access.sync_admin_flags!(data, user_ids: [user.id])
          Access.sync_memberships!(data, principal_ids: [user.id])
        rescue Access::LockoutError
          Rails.logger.warn "Sprintly: group change left #{user.login}'s admin flag as it was (last administrator)"
        end
      end
    end
  end
end
