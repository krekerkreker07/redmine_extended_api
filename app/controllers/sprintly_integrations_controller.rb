# frozen_string_literal: true

require 'securerandom'

# SPR-4669: VCS integrations of a project (GitHub today; GitLab and Bitbucket later), read by the
# scv-adapter service through the project's custom fields.
#
# Each integration is a project custom field of format `string` named like the integration, whose
# value in this project is the JSON the service reads (scv-adapter docs/tracker-contract.md):
#
#   {"id":"<uuid>","name":"cort-github","provider":"github","gq":"<sealed token>","enable":true}
#
# A project custom field exists once for the whole tracker and has a value per project, so one
# field serves every project that names an integration the same; a project without a value has
# no such integration. The fields carry INTEGRATION_MARKER as their description, which is how the
# SPA hides them from the custom field admin and this controller refuses a name already taken by
# an ordinary field. They are `visible`: the service asks the tracker with the user's own token.
#
#   GET    /sprintly/projects/:project_id/integrations.json
#     → { "integrations": [{ "id", "name", "provider", "enable", "field_id" }, …] }  (no gq)
#   POST   /sprintly/projects/:project_id/integrations.json  { "integration": { name, provider, gq, enable } }
#     → 201 { "integration": {…} }
#   PUT    /sprintly/projects/:project_id/integrations/:id.json  { "integration": { gq?, enable? } }
#     → { "integration": {…} }
#   DELETE /sprintly/projects/:project_id/integrations/:id.json → 204; the field goes with the
#     last project that used it.
#
# Reading needs the project to be visible; writing needs `projects.manage_integrations` under the
# Sprintly role model and `edit_project` without it. Creating the field is done here, so a project
# manager who is not a Redmine administrator can add an integration.
# Also reachable through the proxy as /extended_api/sprintly/... .
class SprintlyIntegrationsController < ApplicationController
  include RedmineExtendedApi::Sprintly::ControllerPatches::Guard

  INTEGRATION_MARKER = 'sprintly:vcs-integration'
  PROVIDER_FORMAT = /\A[a-z0-9_-]{1,30}\z/
  GQ_FORMAT = %r{\A[A-Za-z0-9+/]+={0,2}\z}
  NAME_MAX = 30
  GQ_MAX = 4096

  accept_api_auth :index, :create, :update, :destroy

  before_action :find_project
  before_action :authorize_manage, except: :index

  def index
    render json: { integrations: integrations.map { |entry| view(entry) } }
  end

  def create
    attrs = integration_params
    name = attrs[:name].to_s.strip
    provider = attrs[:provider].to_s.strip.downcase
    gq = attrs[:gq].to_s.strip
    errors = []
    errors << 'name is missing' if name.empty?
    errors << "name is longer than #{NAME_MAX} characters" if name.length > NAME_MAX
    errors << 'provider is invalid' unless PROVIDER_FORMAT.match?(provider)
    errors << 'gq is invalid' unless valid_gq?(gq)
    return render_errors(errors) if errors.any?

    field = ProjectCustomField.find_by(name: name)
    return render_errors(["name is taken by another custom field: #{name}"]) if field && !integration_field?(field)
    return render_errors(["this project already has an integration named #{name}"]) if field && value_of(field).present?

    entry = { 'id' => SecureRandom.uuid, 'name' => name, 'provider' => provider, 'gq' => gq,
              'enable' => attrs.key?(:enable) ? truthy?(attrs[:enable]) : true }
    ProjectCustomField.transaction do
      field ||= create_field!(name)
      write!(field, entry)
    end
    render json: { integration: view([field, entry]) }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_errors(e.record.errors.full_messages)
  end

  def update
    field, entry = find_entry
    return render_404 unless field

    attrs = integration_params
    if attrs.key?(:gq)
      gq = attrs[:gq].to_s.strip
      return render_errors(['gq is invalid']) unless valid_gq?(gq)

      entry['gq'] = gq
    end
    entry['enable'] = truthy?(attrs[:enable]) if attrs.key?(:enable)
    write!(field, entry)
    render json: { integration: view([field, entry]) }
  end

  def destroy
    field, = find_entry
    return render_404 unless field

    ProjectCustomField.transaction do
      CustomValue.where(customized_type: 'Project', customized_id: @project.id, custom_field_id: field.id).delete_all
      field.destroy unless CustomValue.where(custom_field_id: field.id).where.not(value: [nil, '']).exists?
    end
    head :no_content
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
    return render_404 unless @project.visible?

    true
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_manage
    allowed =
      if sprintly_enforced?
        sprintly_allowed?('projects.manage_integrations')
      else
        User.current.allowed_to?(:edit_project, @project)
      end
    allowed ? true : deny_access
  end

  def integration_params
    raw = params[:integration]
    raw.respond_to?(:permit) ? raw.permit(:name, :provider, :gq, :enable).to_h.with_indifferent_access : {}.with_indifferent_access
  end

  def integration_field?(field)
    field.description.to_s.strip == INTEGRATION_MARKER
  end

  def integration_fields
    ProjectCustomField.where(description: INTEGRATION_MARKER).sorted.to_a
  end

  # [field, parsed value] for every integration this project has, in the fields' order.
  def integrations
    fields = integration_fields
    return [] if fields.empty?

    values = CustomValue.where(customized_type: 'Project', customized_id: @project.id, custom_field_id: fields.map(&:id))
                        .index_by(&:custom_field_id)
    fields.filter_map do |field|
      entry = parse(values[field.id]&.value)
      entry && [field, entry]
    end
  end

  def find_entry
    integrations.find { |_, entry| entry['id'] == params[:id].to_s } || [nil, nil]
  end

  def parse(value)
    return nil if value.blank?

    entry = JSON.parse(value)
    return nil unless entry.is_a?(Hash) && entry['id'].is_a?(String) && entry['name'].is_a?(String) &&
                      entry['provider'].is_a?(String) && entry['gq'].is_a?(String) && [true, false].include?(entry['enable'])

    entry
  rescue JSON::ParserError
    nil
  end

  def value_of(field)
    CustomValue.find_by(customized_type: 'Project', customized_id: @project.id, custom_field_id: field.id)&.value
  end

  def create_field!(name)
    ProjectCustomField.create!(
      name: name,
      field_format: 'string',
      description: INTEGRATION_MARKER,
      visible: true,
      is_required: false,
      is_filter: false,
      searchable: false
    )
  end

  # Straight into the custom value: saving the project would also validate (and could refuse
  # over) every other field of it.
  def write!(field, entry)
    value = CustomValue.find_or_initialize_by(customized_type: 'Project', customized_id: @project.id, custom_field_id: field.id)
    value.value = entry.slice('id', 'name', 'provider', 'gq', 'enable').to_json
    value.save!
  end

  def view((field, entry))
    { id: entry['id'], name: entry['name'], provider: entry['provider'], enable: entry['enable'], field_id: field.id }
  end

  def valid_gq?(gq)
    gq.length.between?(16, GQ_MAX) && GQ_FORMAT.match?(gq)
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  def render_errors(messages)
    render json: { errors: messages }, status: :unprocessable_entity
  end
end
