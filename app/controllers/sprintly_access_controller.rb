# frozen_string_literal: true

# SPR-383: the Sprintly role model over the API, plus the reads the SPA needs that core
# Redmine keeps admin-only (the user directory, custom field definitions, display settings).
#
# Reached as /sprintly/... and, through the proxy, as /extended_api/sprintly/... .
class SprintlyAccessController < ApplicationController
  Access = RedmineExtendedApi::Sprintly::Access
  Store = RedmineExtendedApi::Sprintly::Store
  Permissions = RedmineExtendedApi::Sprintly::Permissions

  # The avatar is the one profile field other people need to see. "App data" (personal
  # dashboards, filters) is its owner's only (SPR-553, SprintlyAppDataController).
  PRINCIPAL_FIELD_NAMES = %w[Avatar].freeze

  # Read-only settings any signed-in user may know: how to render dates and names, upload
  # limits, issue rules. Mail and host settings stay admin-only.
  APP_CONFIG_KEYS = %w[
    app_title text_formatting per_page_options
    default_language start_of_week date_format time_format timespan_format user_format
    gravatar_enabled thumbnails_enabled thumbnails_size
    cross_project_issue_relations cross_project_subtasks close_duplicate_issues
    default_issue_start_date_to_creation_date non_working_week_days issues_export_limit
    parent_issue_dates parent_issue_priority parent_issue_done_ratio issue_done_ratio_interval
    attachment_max_size attachment_extensions_allowed attachment_extensions_denied
  ].freeze

  LEGACY_CONFIG = /<!--SPRINTLY_CONFIG:(.*?)-->/m

  accept_api_auth :me, :roles, :create_role, :update_role, :destroy_role, :assignments,
                  :update_assignments, :project_assignments, :update_project_assignments,
                  :import, :principals, :custom_fields, :app_config

  before_action :require_login
  before_action :require_admin, only: %i[create_role update_role destroy_role assignments update_assignments]
  before_action :find_project_for_assignments, only: %i[project_assignments update_project_assignments]
  before_action :require_initialized, only: %i[create_role update_role destroy_role update_assignments
                                               update_project_assignments]

  # What the signed-in user may do. The SPA asks this once at startup instead of working it
  # out from a config only administrators can read.
  def me
    user = User.current
    Access.bootstrap_admin!(user)
    Access.pin_default_role!(user)
    data = Store.read
    payload = { initialized: data.present?, user_id: user.id, admin: user.admin?, group_ids: user.group_ids }
    if data
      payload[:default_role_id] = data['default_role_id']
      payload[:global] = { role_ids: Access.global_role_ids(user, data),
                           permissions: Access.granted_permissions(user, Access.global_permissions(user, data)) }
      payload[:projects] = Member.where(user_id: user.id).preload(:roles).each_with_object({}) do |member, out|
        permissions = Access.app_permissions_of_roles(member.roles.to_a)
        out[member.project_id.to_s] = { role_ids: member.roles.map(&:id).uniq,
                                        permissions: Access.granted_permissions(user, permissions) }
      end
    end
    render json: { me: payload }
  end

  def roles
    data = Store.read
    render json: { roles: Role.givable.sorted.map { |role| Access.role_payload(role, data) } }
  end

  def create_role
    save_role(nil)
  end

  def update_role
    role = Role.givable.find_by(id: params[:id])
    return render_404 unless role

    save_role(role)
  end

  def destroy_role
    role = Role.givable.find_by(id: params[:id])
    return render_404 unless role

    Role.transaction do
      Store.update! do |data|
        Access.forget_role!(role.id, data)
        Access.sync_memberships!(data)
        Access.sync_admin_flags!(data)
      end
      role.reload.destroy!
    end
    head :no_content
  rescue Access::LockoutError => e
    render_error_json(e.message, :unprocessable_entity)
  rescue StandardError
    render_error_json(l(:error_can_not_remove_role), :unprocessable_entity)
  end

  def assignments
    data = Store.read || Store.blank_document
    render json: { assignments: data.slice('users', 'groups', 'default_role_id', 'projects') }
  end

  # Merges: every principal sent gets exactly the role ids sent for it ([] removes it); the
  # ones not sent are left as they are.
  def update_assignments
    body = assignments_params
    Role.transaction do
      Store.update! do |data|
        merge_principals!(data['users'], body['users'])
        merge_principals!(data['groups'], body['groups'])
        data['default_role_id'] = body['default_role_id'].presence&.to_i if body.key?('default_role_id')

        if body.key?('default_role_id')
          Access.sync_admin_flags!(data)
          Access.sync_memberships!(data)
        else
          Access.resync_principals!(data, user_ids: (body['users'] || {}).keys, group_ids: (body['groups'] || {}).keys)
        end
      end
    end
    assignments
  rescue Access::LockoutError => e
    render_error_json(e.message, :unprocessable_entity)
  end

  def project_assignments
    data = Store.read || Store.blank_document
    scope = data.dig('projects', @project.id.to_s) || { 'users' => {}, 'groups' => {} }
    render json: { assignments: scope.merge('project_id' => @project.id) }
  end

  def update_project_assignments
    body = assignments_params
    Store.update! do |data|
      scope = (data['projects'][@project.id.to_s] ||= { 'users' => {}, 'groups' => {} })
      merge_principals!(scope['users'], body['users'])
      merge_principals!(scope['groups'], body['groups'])
      data.replace(Store.normalize(data))
      Access.sync_memberships!(data, project_id: @project.id)
    end
    project_assignments
  end

  # Switches the tenant over from the SPA's old `welcome_text` config (see Access.import!).
  def import
    return render_403 unless User.current.admin?
    if Store.initialized? && params[:force].to_s != 'true'
      return render_error_json('already imported', :conflict)
    end

    payload = params.require(:import).permit!.to_h
    Access.import!(payload)
    render json: { roles: Role.givable.sorted.map { |role| Access.role_payload(role, Store.read) } }
  rescue Access::LockoutError => e
    render_error_json(e.message, :unprocessable_entity)
  end

  # The user directory for pickers and avatars, readable by everybody (Jira's "Browse users
  # and groups"). `GET /users` stays an administrators' screen.
  def principals
    admin = User.current.admin?
    users = User.active.visible.sorted.preload(:preference, :groups, custom_values: :custom_field).to_a
    groups = Group.givable.sorted.preload(:users).to_a
    render json: {
      users: users.map { |user| principal_user(user, admin) },
      groups: groups.map do |group|
        entry = { id: group.id, name: group.name }
        entry[:user_ids] = group.user_ids if admin || group.user_ids.include?(User.current.id)
        entry
      end
    }
  end

  # Custom field definitions the user may see, with their project scope (which the core list
  # leaves out). Administrators get all of them.
  def custom_fields
    user = User.current
    role_ids = user.admin? ? [] : user.members.preload(:roles).flat_map { |m| m.roles.map(&:id) }.uniq
    fields = CustomField.sorted.to_a.select do |field|
      user.admin? || field.visible? || (field.respond_to?(:role_ids) && (field.role_ids & role_ids).any?)
    end
    render json: { custom_fields: fields.map { |field| custom_field_payload(field) } }
  end

  def app_config
    settings = APP_CONFIG_KEYS.each_with_object({}) do |key, out|
      out[key] = Setting.send(key) if Setting.respond_to?(key)
    end
    welcome = Setting.welcome_text.to_s
    settings['welcome_text'] = welcome.sub(LEGACY_CONFIG, '').rstrip
    # The global settings screen still keeps the logo in the welcome_text config; the copy the
    # import took is only a fallback.
    settings['company_icon'] = legacy_config(welcome)['companyIcon'] || Store.read&.dig('company_icon')
    render json: { settings: settings }
  end

  private

  def require_initialized
    return true if Store.initialized?

    render_error_json('roles have not been imported yet', :conflict)
    false
  end

  def find_project_for_assignments
    @project = Project.find(params[:project_id])
    return true if User.current.admin?
    return true if action_name == 'project_assignments' && User.current.member_of?(@project)
    return true if User.current.allowed_to?(:manage_members, @project)

    render_403
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def save_role(role)
    attrs = params.require(:role).permit(:name, :description, :preset, :position, permissions: []).to_h
    saved = nil
    Role.transaction do
      Store.update! do |data|
        saved = Access.save_role!(role, attrs, data)
        Access.sync_admin_flags!(data)
      end
    end
    render json: { role: Access.role_payload(saved, Store.read) }, status: role ? :ok : :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  rescue Access::LockoutError => e
    render_error_json(e.message, :unprocessable_entity)
  end

  def assignments_params
    raw = params[:assignments]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    (raw || {}).to_h.deep_stringify_keys
  end

  def merge_principals!(target, updates)
    (updates || {}).each do |id, role_ids|
      list = Array(role_ids).map(&:to_i).reject(&:zero?).uniq
      list.empty? ? target.delete(id.to_s) : target[id.to_s] = list
    end
  end

  def principal_user(user, admin)
    entry = { id: user.id, login: user.login, firstname: user.firstname, lastname: user.lastname,
              name: user.name, status: user.status }
    # SPR-558: the address goes to every signed-in user, whatever "hide my e-mail" says. Chat
    # knows people only by it (rooms, authors, mentions), so without it everybody but you is a
    # bare address there and cannot be written to; chat members already see it anyway.
    entry[:mail] = user.mail
    entry[:group_ids] = user.group_ids if admin || user == User.current
    entry[:custom_fields] = user.custom_field_values.select { |cv| PRINCIPAL_FIELD_NAMES.include?(cv.custom_field.name) }
                                .map { |cv| { id: cv.custom_field.id, name: cv.custom_field.name, value: cv.value } }
    entry
  end

  def custom_field_payload(field)
    payload = {
      id: field.id, name: field.name, description: field.description, type: field.type,
      customized_type: field.class.customized_class&.name&.underscore,
      field_format: field.field_format, position: field.position, regexp: field.regexp.presence,
      min_length: field.min_length, max_length: field.max_length, is_required: field.is_required?,
      is_filter: field.is_filter?, searchable: field.searchable, multiple: field.multiple?,
      default_value: field.default_value, visible: field.visible?, editable: field.editable?,
      is_for_all: field.respond_to?(:is_for_all?) ? field.is_for_all? : nil
    }
    %i[url_pattern text_formatting full_width_layout edit_tag_style version_status
       extensions_allowed thousands_delimiter user_role].each do |attr|
      value = field.try(attr)
      payload[attr] = value unless value.nil? || value == ''
    end
    values = field.possible_values_options
    payload[:possible_values] = values.map { |label, value| { value: value || label, label: label } } if values.present?
    if field.respond_to?(:enumerations)
      payload[:enumerations] = field.enumerations.map { |e| { id: e.id, name: e.name, active: e.active?, position: e.position } }
    end
    if field.respond_to?(:trackers)
      payload[:trackers] = field.trackers.map { |t| { id: t.id, name: t.name } }
      payload[:tracker_ids] = field.tracker_ids
    end
    if field.respond_to?(:roles)
      payload[:roles] = field.roles.map { |r| { id: r.id, name: r.name } }
      payload[:role_ids] = field.role_ids
    end
    if field.respond_to?(:projects)
      payload[:projects] = field.projects.map { |p| { id: p.id, name: p.name, identifier: p.identifier } }
    end
    payload.compact
  end

  def legacy_config(welcome)
    match = LEGACY_CONFIG.match(welcome)
    match ? JSON.parse(match[1]) : {}
  rescue JSON::ParserError
    {}
  end

  def render_error_json(message, status)
    render json: { errors: [message] }, status: status
  end
end
