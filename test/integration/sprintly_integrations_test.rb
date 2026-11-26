# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# SPR-4669: VCS integrations of a project, kept as project custom fields scv-adapter reads.
#
# Fixtures used: project 1 (ecookbook, public) and 2 (onlinestore, private); jsmith (2) is a
# Manager of both, dlopper (3) a Developer of project 1 only. Both fixture roles have edit_project.
class SprintlyIntegrationsTest < Redmine::ApiTest::Base
  Permissions = RedmineExtendedApi::Sprintly::Permissions
  Store = RedmineExtendedApi::Sprintly::Store
  MARKER = SprintlyIntegrationsController::INTEGRATION_MARKER
  GQ = 'AQIDBAUGBwgJCgsMj4GjiKuxk2acvrjwzl8fnPj6sMZLLlg='

  PASSWORDS = { 'dlopper' => 'foo' }.freeze

  def setup
    super
    Store.clear!
  end

  def headers(login)
    credentials(login, PASSWORDS[login]).merge('CONTENT_TYPE' => 'application/json')
  end

  def json
    JSON.parse(response.body)
  end

  def add(name: 'cort-github', provider: 'github', gq: GQ, enable: true, project: 'ecookbook', login: 'jsmith', prefix: '')
    body = { integration: { name: name, provider: provider, gq: gq, enable: enable }.compact }
    post "#{prefix}/sprintly/projects/#{project}/integrations.json", params: body.to_json, headers: headers(login)
  end

  def list(project: 'ecookbook', login: 'jsmith')
    get "/sprintly/projects/#{project}/integrations.json", headers: headers(login)
  end

  def change(id, attrs, project: 'ecookbook', login: 'jsmith')
    put "/sprintly/projects/#{project}/integrations/#{id}.json", params: { integration: attrs }.to_json, headers: headers(login)
  end

  def remove(id, project: 'ecookbook', login: 'jsmith')
    delete "/sprintly/projects/#{project}/integrations/#{id}.json", headers: headers(login)
  end

  def stored(name, project_id: 1)
    field = ProjectCustomField.find_by!(name: name)
    JSON.parse(CustomValue.find_by!(customized_type: 'Project', customized_id: project_id, custom_field_id: field.id).value)
  end

  def test_adding_creates_a_marked_visible_string_field_holding_the_contract_json
    add
    assert_response :created
    created = json['integration']
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, created['id'])
    assert_equal({ 'name' => 'cort-github', 'provider' => 'github', 'enable' => true }, created.slice('name', 'provider', 'enable'))
    refute created.key?('gq'), 'the sealed token is never sent back'

    field = ProjectCustomField.find(created['field_id'])
    assert_equal ['cort-github', 'string', MARKER, true], [field.name, field.field_format, field.description, field.visible]
    assert_equal({ 'id' => created['id'], 'name' => 'cort-github', 'provider' => 'github', 'gq' => GQ, 'enable' => true },
                 stored('cort-github'))
  end

  # scv-adapter reads GET /projects with the user's own token: a plain member must see the value.
  def test_the_value_reaches_the_project_payload_of_a_plain_member
    add
    get '/projects.json?limit=100', headers: headers('dlopper')
    assert_response :success
    project = json['projects'].find { |p| p['identifier'] == 'ecookbook' }
    value = project['custom_fields'].find { |cf| cf['name'] == 'cort-github' }['value']
    assert_equal 'github', JSON.parse(value)['provider']
  end

  def test_listing_shows_the_project_integrations_without_the_token
    add
    add name: 'client-github', enable: false
    list login: 'dlopper'
    assert_response :success
    assert_equal [%w[cort-github github], %w[client-github github]].sort,
                 json['integrations'].map { |i| [i['name'], i['provider']] }.sort
    assert_equal [false, true], json['integrations'].map { |i| i['enable'] }.sort_by { |b| b ? 1 : 0 }
    json['integrations'].each { |i| refute i.key?('gq') }
  end

  def test_listing_skips_values_that_are_not_an_integration
    add
    field = ProjectCustomField.find_by!(name: 'cort-github')
    CustomValue.create!(customized_type: 'Project', customized_id: 2, custom_field_id: field.id, value: 'not json')
    list project: 'onlinestore'
    assert_response :success
    assert_equal [], json['integrations']
  end

  def test_the_same_name_in_another_project_shares_the_field_with_its_own_value
    add
    first = json['integration']
    add project: 'onlinestore', gq: 'b3RoZXItcHJvamVjdC10b2tlbg=='
    assert_response :created
    second = json['integration']

    assert_equal first['field_id'], second['field_id']
    refute_equal first['id'], second['id']
    assert_equal GQ, stored('cort-github')['gq']
    assert_equal 'b3RoZXItcHJvamVjdC10b2tlbg==', stored('cort-github', project_id: 2)['gq']
  end

  def test_a_project_cannot_have_two_integrations_of_one_name
    add
    add
    assert_response :unprocessable_entity
    assert_match(/already has an integration named cort-github/, json['errors'].join)
  end

  def test_a_name_taken_by_an_ordinary_field_is_refused_and_that_field_left_alone
    ordinary = ProjectCustomField.create!(name: 'Department', field_format: 'string')
    add name: 'Department'
    assert_response :unprocessable_entity
    assert_match(/taken by another custom field/, json['errors'].join)
    assert_nil CustomValue.find_by(customized_type: 'Project', customized_id: 1, custom_field_id: ordinary.id)
  end

  def test_invalid_input_is_refused
    { { name: '  ' } => 'name is missing',
      { name: 'x' * 31 } => 'longer than 30',
      { provider: 'Git Hub!' } => 'provider is invalid',
      { gq: 'short' } => 'gq is invalid',
      { gq: 'not base64 at all, has spaces' } => 'gq is invalid' }.each do |attrs, message|
      add(**attrs)
      assert_response :unprocessable_entity, attrs.inspect
      assert_match(/#{message}/, json['errors'].join, attrs.inspect)
    end
    assert_nil ProjectCustomField.find_by(description: MARKER)
  end

  def test_provider_is_stored_lower_case_and_enable_defaults_to_on
    add provider: 'GitHub', enable: nil
    assert_response :created
    assert_equal ['github', true], stored('cort-github').values_at('provider', 'enable')
  end

  def test_switching_off_and_replacing_the_token
    add
    id = json['integration']['id']

    change id, { enable: false }
    assert_response :success
    assert_equal false, json['integration']['enable']
    assert_equal [false, GQ], stored('cort-github').values_at('enable', 'gq')

    change id, { gq: 'bmV3LXNlYWxlZC10b2tlbi12YWx1ZQ==' }
    assert_response :success
    assert_equal ['bmV3LXNlYWxlZC10b2tlbi12YWx1ZQ==', false], stored('cort-github').values_at('gq', 'enable')
    assert_equal id, stored('cort-github')['id']

    change id, { gq: 'bad token' }
    assert_response :unprocessable_entity

    change 'no-such-id', { enable: true }
    assert_response :not_found
  end

  def test_removing_keeps_the_field_while_another_project_uses_it
    add
    ours = json['integration']
    add project: 'onlinestore'
    theirs = json['integration']

    remove ours['id']
    assert_response :no_content
    assert ProjectCustomField.exists?(ours['field_id'])
    assert_nil CustomValue.find_by(customized_type: 'Project', customized_id: 1, custom_field_id: ours['field_id'])

    remove theirs['id'], project: 'onlinestore'
    assert_response :no_content
    refute ProjectCustomField.exists?(ours['field_id']), 'the last project takes the field with it'

    remove theirs['id'], project: 'onlinestore'
    assert_response :not_found
  end

  def test_without_the_role_model_writing_takes_edit_project
    Role.find_by!(name: 'Developer').remove_permission!(:edit_project)
    add login: 'dlopper'
    assert_response :forbidden
    list login: 'dlopper'
    assert_response :success

    add login: 'admin'
    assert_response :created
    remove json['integration']['id'], login: 'dlopper'
    assert_response :forbidden
  end

  def test_a_project_the_user_cannot_see_is_not_found
    add project: 'onlinestore'
    list project: 'onlinestore', login: 'dlopper'
    assert_response :not_found
    add project: 'onlinestore', login: 'dlopper', name: 'x'
    assert_response :not_found
  end

  def test_with_the_role_model_writing_takes_manage_integrations
    post '/sprintly/import.json', params: { import: {
      roles: [
        { key: 'admin', name: 'Administrator', description: 'All', permissions: Permissions::APP_PERMISSIONS, preset: 'admin' },
        { key: 'manager', name: 'PM', description: 'Edits', permissions: %w[projects.view projects.edit issues.view], preset: 'manager' }
      ],
      users: { '1' => ['admin'], '2' => ['manager'], '3' => ['manager'] },
      groups: {}, default_role: nil, projects: {}
    } }.to_json, headers: headers('admin')
    assert_response :success

    add login: 'jsmith'
    assert_response :forbidden, 'projects.edit alone is not enough'

    pm = Role.givable.find_by!(name: 'PM')
    pm.add_permission!(*Permissions.redmine_permissions_for(['projects.manage_integrations']))
    add login: 'jsmith'
    assert_response :created
  end

  def test_the_migration_gives_the_permission_to_roles_that_edit_project_settings
    post '/sprintly/import.json', params: { import: {
      roles: [
        { key: 'manager', name: 'PM', description: 'Edits', permissions: %w[projects.view projects.edit], preset: 'manager' },
        { key: 'developer', name: 'Dev', description: 'Works', permissions: %w[projects.view issues.view], preset: 'developer' }
      ],
      users: { '1' => ['manager'] }, groups: {}, default_role: nil, projects: {}
    } }.to_json, headers: headers('admin')
    assert_response :success

    require File.expand_path('../../db/migrate/20261125120000_grant_integrations_to_project_editors', __dir__)
    migration = GrantIntegrationsToProjectEditors.new
    migration.verbose = false
    2.times { migration.up }

    assert_equal %w[projects.edit projects.manage_integrations projects.view],
                 Permissions.app_ids_of(Role.givable.find_by!(name: 'PM').reload).sort
    refute_includes Permissions.app_ids_of(Role.givable.find_by!(name: 'Dev').reload), 'projects.manage_integrations'
  end

  def test_through_the_proxy_prefix
    add prefix: '/extended_api'
    assert_response :created
  end
end
