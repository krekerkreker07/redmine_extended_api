# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# SPR-383: the Sprintly role model end to end, over the REST API, on Redmine's fixtures.
#
# Fixtures used: project 1 (ecookbook, public) has jsmith (2, Manager) and dlopper (3,
# Developer) as members; only `admin` (1) is a Redmine administrator, and that account is
# not managed by the role model.
class SprintlyAccessTest < Redmine::ApiTest::Base
  Permissions = RedmineExtendedApi::Sprintly::Permissions
  Store = RedmineExtendedApi::Sprintly::Store

  DEV = %w[issues.view issues.create issues.edit issues.add_notes issues.change_status sprints.view
           wiki.view wiki.edit time.view time.log time.edit_own gists.view projects.view
           sections.board sections.issues].freeze
  VIEWER = %w[issues.view issues.add_notes wiki.view time.view projects.view].freeze

  def setup
    super
    Store.clear!
  end

  def import_config(extra = {})
    {
      roles: [
        { key: 'admin', name: 'Administrator', description: 'Everything', permissions: Permissions::APP_PERMISSIONS, preset: 'admin' },
        { key: 'developer', name: 'Developer', description: 'Works on issues', permissions: DEV, preset: 'developer' },
        { key: 'viewer', name: 'Viewer', description: 'Reads', permissions: VIEWER, preset: 'viewer' }
      ],
      users: { '2' => ['admin'], '3' => ['developer'] },
      groups: {},
      default_role: 'viewer',
      projects: {},
      company_icon: { attachmentId: 7 }
    }.merge(extra)
  end

  PASSWORDS = { 'dlopper' => 'foo' }.freeze

  def auth(login)
    credentials(login, PASSWORDS[login])
  end

  def json_headers(login)
    auth(login).merge('CONTENT_TYPE' => 'application/json')
  end

  def import!(config = import_config)
    post '/sprintly/import.json', params: { import: config }.to_json, headers: json_headers('admin')
    assert_response :success
    JSON.parse(response.body)['roles'].index_by { |r| r['name'] }
  end

  def me(login)
    get '/sprintly/me.json', headers: auth(login)
    assert_response :success
    JSON.parse(response.body)['me']
  end

  def role_named(name)
    Role.givable.find_by!(name: name)
  end

  def save_role(name, permissions)
    role = Role.givable.find_by(name: name)
    body = { role: { name: name, permissions: permissions } }.to_json
    if role
      put "/sprintly/roles/#{role.id}.json", params: body, headers: json_headers('jsmith')
    else
      post '/sprintly/roles.json', params: body, headers: json_headers('jsmith')
    end
    assert_response :success
    Role.givable.find_by!(name: name)
  end

  def override(project_id, user_id, role)
    put "/sprintly/projects/#{project_id}/assignments.json",
        params: { assignments: { users: { user_id.to_s => [role.id] } } }.to_json, headers: json_headers('jsmith')
    assert_response :success
  end

  # ---- before the import -------------------------------------------------------------

  def test_before_import_nothing_is_enforced_and_the_first_user_becomes_admin
    payload = me('dlopper')
    assert_equal false, payload['initialized']
    # Nobody but the unmanaged `admin` administers this tenant: the first person in does.
    assert payload['admin']
    assert User.find(3).admin?
    refute User.find(2).reload.admin?
  end

  # SPR-572: since SPR-538 the seed account is `support-<hex>`, not `admin`.
  def test_before_import_the_first_user_becomes_admin_whatever_the_seed_account_is_called
    User.find(1).update_column(:login, 'support-0123456789')
    assert me('dlopper')['admin']
    assert User.find(1).reload.admin?
  end

  def test_first_user_of_a_fresh_tenant_imports_and_keeps_admin
    User.find(1).update_column(:login, 'support-0123456789')
    assert me('dlopper')['admin']
    post '/sprintly/import.json', params: { import: import_config(users: {}, default_role: 'admin') }.to_json,
                                  headers: json_headers('dlopper')
    assert_response :success
    assert me('dlopper')['admin']
    assert User.find(1).reload.admin?
  end

  def test_before_import_core_permissions_rule
    User.find(3).update_column(:admin, true) # an administrator exists, no bootstrap
    put '/issues/1.json', params: { issue: { assigned_to_id: 2 } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    assert_equal 2, Issue.find(1).assigned_to_id
  end

  # ---- the import ----------------------------------------------------------------------

  def test_import_switches_the_tenant_over
    roles = import!

    assert_equal %w[Administrator Developer Viewer], roles.keys.first(3)
    assert_equal 2, roles['Developer']['id'], 'the existing Developer role is reused'
    assert_equal DEV.sort, roles['Developer']['permissions'].sort
    developer = role_named('Developer')
    assert developer.has_permission?(:view_issues)
    assert developer.has_permission?(:edit_issues)
    refute developer.has_permission?(:delete_issues)
    assert_equal 'default', developer.issues_visibility
    assert_equal 'own', developer.time_entries_visibility

    assert User.find(2).admin?, 'jsmith holds admin.access'
    refute User.find(3).admin?
    assert User.find(1).admin?, 'the built-in admin account is left alone'

    assert_equal [role_named('Administrator').id], Member.find_by(project_id: 1, user_id: 2).role_ids
    assert_equal [developer.id], Member.find_by(project_id: 1, user_id: 3).role_ids
    assert_equal [role_named('Viewer').id], Member.find_by(project_id: 1, user_id: 5).role_ids, 'default role'

    assert_empty Role.non_member.permissions
    assert_empty Role.anonymous.permissions
    assert_equal({ 'attachmentId' => 7 }, Store.read['company_icon'])
  end

  def test_import_twice_needs_force
    import!
    post '/sprintly/import.json', params: { import: import_config }.to_json, headers: json_headers('admin')
    assert_response :conflict
  end

  def test_import_is_admin_only
    User.find(2).update_column(:admin, true)
    post '/sprintly/import.json', params: { import: import_config }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden
  end

  def test_me_after_import
    import!
    payload = me('dlopper')
    assert payload['initialized']
    refute payload['admin']
    assert_equal [role_named('Developer').id], payload['global']['role_ids']
    assert_equal DEV.sort, payload['global']['permissions'].sort
    assert_includes payload['projects']['1']['permissions'], 'issues.edit'
  end

  # SPR-545: the admin flag taken away by hand (demo) while the global role still says
  # Administrator. Core answers 403 on every admin screen, so `me` must not offer them.
  def test_me_without_the_admin_flag_offers_no_admin_screens
    import!
    User.find(2).update_column(:admin, false)
    payload = me('jsmith')
    refute payload['admin']
    assert_equal [role_named('Administrator').id], payload['global']['role_ids']
    assert_empty payload['global']['permissions'].grep(/\Aadmin\./)
    assert_empty payload['projects']['1']['permissions'].grep(/\Aadmin\./)
    assert_includes payload['global']['permissions'], 'projects.create'
    assert_includes payload['projects']['1']['permissions'], 'projects.manage_members'

    get '/groups.json', headers: auth('jsmith')
    assert_response :forbidden
  end

  def test_me_of_an_administrator_keeps_the_admin_screens
    import!
    payload = me('jsmith')
    assert payload['admin']
    assert_includes payload['global']['permissions'], 'admin.access'
    assert_includes payload['global']['permissions'], 'admin.groups'
  end

  # ---- server-side enforcement -------------------------------------------------------

  def test_status_follows_change_status_without_any_workflow
    import!
    tester = save_role('Tester', DEV)
    WorkflowTransition.where(role_id: tester.id).delete_all
    override(1, 3, tester)

    put '/issues/1.json', params: { issue: { status_id: 2 } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    assert_equal 2, Issue.find(1).status_id

    save_role('Tester', DEV - ['issues.change_status'])
    put '/issues/1.json', params: { issue: { status_id: 1, subject: 'Still editable' } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    assert_equal 2, Issue.find(1).status_id, 'status stays'
    assert_equal 'Still editable', Issue.find(1).subject
  end

  def test_assignee_priority_and_sprint_need_their_permissions
    import!
    before = Issue.find(1)
    put '/issues/1.json', params: { issue: { assigned_to_id: 2, priority_id: 6, fixed_version_id: 3, subject: 'Edited' } }.to_json,
                          headers: json_headers('dlopper')
    assert_response :no_content
    issue = Issue.find(1)
    # Fixture issue 1 starts unassigned and outside any sprint (Minitest 6 refuses assert_equal nil).
    assert_nil before.assigned_to_id
    assert_nil before.fixed_version_id
    assert_nil issue.assigned_to_id
    assert_equal before.priority_id, issue.priority_id
    assert_nil issue.fixed_version_id
    assert_equal 'Edited', issue.subject

    save_role('Developer', DEV + %w[issues.assign issues.change_priority])
    put '/issues/1.json', params: { issue: { assigned_to_id: 2, priority_id: 6 } }.to_json, headers: json_headers('dlopper')
    assert_equal 2, Issue.find(1).assigned_to_id
    assert_equal 6, Issue.find(1).priority_id
  end

  def test_a_field_permission_works_without_edit_and_edit_covers_the_rest
    import!
    assigner = save_role('Assigner', %w[issues.view issues.create issues.assign projects.view])
    override(1, 3, assigner)
    put '/issues/1.json', params: { issue: { assigned_to_id: 2, subject: 'Not mine to change' } }.to_json,
                          headers: json_headers('dlopper')
    assert_response :no_content
    issue = Issue.find(1)
    assert_equal 2, issue.assigned_to_id
    refute_equal 'Not mine to change', issue.subject

    post '/projects/1/issues.json', params: { issue: { tracker_id: 1, subject: 'New one', priority_id: 6 } }.to_json,
                                    headers: json_headers('dlopper')
    assert_response :created
    created = Issue.order(:id).last
    assert_equal 'New one', created.subject, 'creating sets the fields without issues.edit'
    refute_equal 6, created.priority_id, 'but not priority without its own permission'
  end

  # SPR-512: a Developer (issues.edit, no admin rights) sets every kind of issue custom field
  # the tracker uses — on an existing issue and on a new one. The definitions themselves stay
  # an administrator's: reading one through the admin endpoint is refused, which is why the
  # SPA resolves picked options from /sprintly/custom_fields instead.
  def test_a_developer_sets_every_kind_of_custom_field
    import!
    scope = { is_for_all: false, project_ids: [1], tracker_ids: [1], visible: true }
    release = IssueCustomField.create!(scope.merge(name: 'Release Version', field_format: 'enumeration'))
    release.enumerations.create!(name: '0.0.15', position: 1)
    release.enumerations.create!(name: '0.0.29', position: 2)
    component = IssueCustomField.create!(scope.merge(name: 'Service/Component', field_format: 'list', multiple: true,
                                                     possible_values: %w[Tracker-UI cli]))
    commit = IssueCustomField.create!(scope.merge(name: 'Commit', field_format: 'bool'))
    shipped = IssueCustomField.create!(scope.merge(name: 'Release (version)', field_format: 'version'))
    option = release.enumerations.find_by!(name: '0.0.29')
    values = [
      { id: release.id, value: option.id.to_s },
      { id: component.id, value: %w[Tracker-UI cli] },
      { id: commit.id, value: '1' },
      { id: shipped.id, value: '3' }
    ]
    expected = {
      release.id => option.id.to_s, component.id => %w[Tracker-UI cli], commit.id => '1', shipped.id => '3'
    }
    read = ->(issue) { expected.keys.to_h { |id| [id, issue.reload.custom_field_value(CustomField.find(id))] } }

    put '/issues/1.json', params: { issue: { custom_fields: values } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    assert_equal expected, read.call(Issue.find(1))

    post '/projects/1/issues.json', params: { issue: { tracker_id: 1, subject: 'With fields', custom_fields: values } }.to_json,
                                    headers: json_headers('dlopper')
    assert_response :created
    assert_equal expected, read.call(Issue.find(JSON.parse(response.body)['issue']['id']))

    get "/custom_fields/#{release.id}.json", headers: auth('dlopper')
    assert_response :forbidden
    get '/sprintly/custom_fields.json', headers: auth('dlopper')
    listed = JSON.parse(response.body)['custom_fields'].detect { |f| f['id'] == release.id }
    assert_includes listed['enumerations'].map { |e| e['id'] }, option.id, 'the options come with the readable list'
  end

  def test_watching_yourself_is_free_watching_others_needs_assign
    import!
    post '/issues/2/watchers.json', params: { user_id: 3 }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    post '/issues/2/watchers.json', params: { user_id: 2 }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden
  end

  def test_sprint_actions
    import!
    save_role('Developer', DEV + ['sprints.edit'])
    post '/projects/1/versions.json', params: { version: { name: 'Sprint X' } }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden
    put '/versions/2.json', params: { version: { description: 'renamed' } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    delete '/versions/3.json', headers: auth('dlopper')
    assert_response :forbidden

    save_role('Developer', DEV + %w[sprints.create])
    post '/projects/1/versions.json', params: { version: { name: 'Sprint X' } }.to_json, headers: json_headers('dlopper')
    assert_response :created
  end

  def test_wiki_create_and_edit_are_separate
    import!
    put '/projects/ecookbook/wiki/Another_page.json',
        params: { wiki_page: { text: 'changed' } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    put '/projects/ecookbook/wiki/Brand_new.json', params: { wiki_page: { text: 'new' } }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden

    save_role('Developer', DEV + ['wiki.create'])
    put '/projects/ecookbook/wiki/Brand_new.json', params: { wiki_page: { text: 'new' } }.to_json, headers: json_headers('dlopper')
    assert_response :created
  end

  def test_time_entries_edit_own_and_delete
    import!
    post '/time_entries.json', params: { time_entry: { issue_id: 1, hours: 1.5, activity_id: 9 } }.to_json,
                               headers: json_headers('dlopper')
    assert_response :created
    entry_id = JSON.parse(response.body)['time_entry']['id']

    put "/time_entries/#{entry_id}.json", params: { time_entry: { hours: 2 } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    delete "/time_entries/#{entry_id}.json", headers: auth('dlopper')
    assert_response :forbidden

    save_role('Developer', DEV + ['time.delete'])
    delete "/time_entries/#{entry_id}.json", headers: auth('dlopper')
    assert_response :no_content
  end

  def test_gists_create_rename_and_delete_are_separate
    import!
    save_role('Developer', DEV + ['gists.edit'])
    post '/uploads.json?filename=gist.txt', params: 'gist', headers: auth('dlopper').merge('CONTENT_TYPE' => 'application/octet-stream')
    assert_response :created
    token = JSON.parse(response.body)['upload']['token']
    post '/projects/1/files.json', params: { file: { token: token, filename: 'gist.txt' } }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden

    patch '/attachments/8.json', params: { attachment: { filename: 'renamed.zip' } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    delete '/attachments/8.json', headers: auth('dlopper')
    assert_response :forbidden
    delete '/attachments/12.json', headers: auth('dlopper')
    assert_response :forbidden, 'a sprint file is a gist too'

    save_role('Developer', DEV + %w[gists.create gists.delete])
    post '/projects/1/files.json', params: { file: { token: token, filename: 'gist.txt' } }.to_json, headers: json_headers('dlopper')
    assert_response :no_content
    patch '/attachments/8.json', params: { attachment: { filename: 'again.zip' } }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden
    delete '/attachments/8.json', headers: auth('dlopper')
    assert_response :no_content
  end

  def test_creating_projects_is_a_global_permission
    import!
    creator = save_role('Creator', DEV + ['projects.create'])
    override(1, 3, creator)
    body = { project: { name: 'Mine', identifier: 'mine-project' } }.to_json
    post '/projects.json', params: body, headers: json_headers('dlopper')
    assert_response :forbidden, 'a project role does not lend a global permission'

    put '/sprintly/assignments.json', params: { assignments: { users: { '3' => [creator.id] } } }.to_json,
                                      headers: json_headers('jsmith')
    assert_response :success
    post '/projects.json', params: body, headers: json_headers('dlopper')
    assert_response :created
  end

  # ---- assignments -----------------------------------------------------------------------

  def test_the_last_administrator_cannot_be_removed
    import!
    put '/sprintly/assignments.json', params: { assignments: { users: { '2' => [] } } }.to_json, headers: json_headers('jsmith')
    assert_response :unprocessable_entity
    assert User.find(2).admin?
    assert_equal [role_named('Administrator').id], Store.read['users']['2']
  end

  def test_global_role_change_moves_admin_flag_and_memberships
    import!
    admin_role = role_named('Administrator')
    put '/sprintly/assignments.json', params: { assignments: { users: { '3' => [admin_role.id] } } }.to_json,
                                      headers: json_headers('jsmith')
    assert_response :success
    assert User.find(3).admin?
    assert_equal [admin_role.id], Member.find_by(project_id: 1, user_id: 3).role_ids
  end

  def test_project_override_replaces_the_global_role_there_only
    import!
    viewer = role_named('Viewer')
    override(1, 3, viewer)
    assert_equal [viewer.id], Member.find_by(project_id: 1, user_id: 3).role_ids
    assert_equal({ '3' => [viewer.id] }, Store.read['projects']['1']['users'])

    get '/sprintly/projects/1/assignments.json', headers: auth('dlopper')
    assert_response :success, 'members may read their project assignments'
    put '/sprintly/projects/1/assignments.json', params: { assignments: { users: { '3' => [] } } }.to_json,
                                                 headers: json_headers('dlopper')
    assert_response :forbidden
  end

  def test_a_new_member_gets_the_role_model_role
    import!
    post '/projects/1/memberships.json', params: { membership: { user_id: 4, role_ids: [role_named('Administrator').id] } }.to_json,
                                         headers: json_headers('jsmith')
    assert_response :created
    assert_equal [role_named('Viewer').id], Member.find_by(project_id: 1, user_id: 4).role_ids
  end

  def test_joining_a_group_brings_its_global_role
    import!
    put '/sprintly/assignments.json', params: { assignments: { groups: { '10' => [role_named('Administrator').id] } } }.to_json,
                                      headers: json_headers('jsmith')
    assert_response :success
    refute User.find(4).admin?
    post '/groups/10/users.json', params: { user_id: 4 }.to_json, headers: json_headers('jsmith')
    assert_response :no_content
    assert User.find(4).admin?
  end

  # SPR-4660: the default role is pinned on a newcomer, so the Users screen shows it and a later
  # change of the default does not move them.
  def test_a_new_user_is_pinned_on_the_default_role
    import!
    post '/users.json', params: { user: { login: 'newbie', firstname: 'New', lastname: 'User',
                                          mail: 'newbie@example.net', password: 'newbie-pass-123' } }.to_json,
                        headers: json_headers('jsmith')
    assert_response :created
    newbie = User.find_by!(login: 'newbie')
    viewer = role_named('Viewer')
    assert_equal [viewer.id], Store.read['users'][newbie.id.to_s]

    put '/sprintly/assignments.json', params: { assignments: { default_role_id: role_named('Developer').id } }.to_json,
                                      headers: json_headers('jsmith')
    assert_response :success
    assert_equal [viewer.id], RedmineExtendedApi::Sprintly::Access.global_role_ids(newbie.reload)
  end

  def test_signing_in_pins_the_default_role_on_a_user_without_one
    import!(import_config(users: { '2' => ['admin'] }))
    viewer = role_named('Viewer')
    assert_nil Store.read['users']['3']

    assert_equal [viewer.id], me('dlopper')['global']['role_ids']
    assert_equal [viewer.id], Store.read['users']['3']

    put '/sprintly/assignments.json', params: { assignments: { default_role_id: role_named('Developer').id } }.to_json,
                                      headers: json_headers('jsmith')
    assert_response :success
    assert_equal [viewer.id], me('dlopper')['global']['role_ids'], 'a new default is for the next newcomer'
    assert_equal [viewer.id], Member.find_by(project_id: 1, user_id: 3).role_ids
  end

  def test_a_user_whose_group_carries_a_role_is_not_pinned
    import!(import_config(users: { '2' => ['admin'] }))
    developer = role_named('Developer')
    put '/sprintly/assignments.json', params: { assignments: { groups: { '10' => [developer.id] } } }.to_json,
                                      headers: json_headers('jsmith')
    assert_response :success
    post '/groups/10/users.json', params: { user_id: 3 }.to_json, headers: json_headers('jsmith')
    assert_response :no_content

    assert_equal [developer.id], me('dlopper')['global']['role_ids']
    assert_nil Store.read['users']['3'], 'the role comes from the group'
  end

  def test_without_a_default_role_nothing_is_pinned
    import!(import_config(users: { '2' => ['admin'] }, default_role: nil))
    assert_empty me('dlopper')['global']['role_ids']
    assert_nil Store.read['users']['3']
  end

  # SPR-730: roles imported from the Developer preset before it could link issues get it once.
  def test_the_developer_preset_is_topped_up_with_issue_relations
    import!
    save_role('Tester', DEV)
    require File.expand_path('../../db/migrate/20261124120000_grant_issue_relations_to_developer_preset', __dir__)
    migration = GrantIssueRelationsToDeveloperPreset.new
    migration.verbose = false
    2.times { migration.up }

    developer = role_named('Developer').reload
    assert_includes Permissions.app_ids_of(developer), 'issues.manage_relations'
    assert developer.has_permission?(:manage_issue_relations)
    assert_equal (DEV + ['issues.manage_relations']).sort, Permissions.app_ids_of(developer).sort
    refute_includes Permissions.app_ids_of(role_named('Tester')), 'issues.manage_relations', 'custom roles are left alone'
  end

  def test_deleting_a_role_reassigns_its_holders
    import!
    tester = save_role('Tester', DEV)
    override(1, 3, tester)
    delete "/sprintly/roles/#{tester.id}.json", headers: auth('jsmith')
    assert_response :no_content
    assert_nil Role.find_by(id: tester.id)
    assert_equal [role_named('Developer').id], Member.find_by(project_id: 1, user_id: 3).role_ids
  end

  def test_role_writes_are_admin_only
    import!
    post '/sprintly/roles.json', params: { role: { name: 'Nope', permissions: [] } }.to_json, headers: json_headers('dlopper')
    assert_response :forbidden
  end

  # ---- reads for everybody --------------------------------------------------------------

  def test_principals_for_a_non_admin
    import!
    UserCustomField.create!(name: 'App data', field_format: 'text', visible: true)
    get '/sprintly/principals.json', headers: auth('dlopper')
    assert_response :success
    body = JSON.parse(response.body)
    jsmith = body['users'].detect { |u| u['login'] == 'jsmith' }
    assert jsmith
    assert_empty jsmith['custom_fields'].reject { |cf| cf['name'] == 'Avatar' }
    refute jsmith.key?('group_ids')
    refute body['users'].any? { |u| u['status'] != User::STATUS_ACTIVE }
    assert body['groups'].any?
  end

  # SPR-558: chat matches people by address, so a hidden one turned names into addresses.
  def test_principals_carry_the_mail_of_users_who_hide_it
    import!
    User.find_by_login('jsmith').pref.update!(hide_mail: true)
    get '/sprintly/principals.json', headers: auth('dlopper')
    assert_response :success
    jsmith = JSON.parse(response.body)['users'].detect { |u| u['login'] == 'jsmith' }
    assert_equal 'jsmith@somenet.foo', jsmith['mail']
  end

  def test_custom_fields_for_a_non_admin
    import!
    hidden = IssueCustomField.create!(name: 'Hidden', field_format: 'string', visible: false, is_for_all: true, role_ids: [1])
    get '/sprintly/custom_fields.json', headers: auth('dlopper')
    assert_response :success
    names = JSON.parse(response.body)['custom_fields'].map { |f| f['name'] }
    refute_includes names, hidden.name
    get '/sprintly/custom_fields.json', headers: auth('jsmith')
    field = JSON.parse(response.body)['custom_fields'].detect { |f| f['name'] == hidden.name }
    assert_equal true, field['is_for_all']
  end

  def test_app_config_strips_the_old_role_config
    Setting.welcome_text = "Hello\n<!--SPRINTLY_CONFIG:{\"roles\":[],\"companyIcon\":{\"x\":1}}-->"
    get '/sprintly/app_config.json', headers: auth('dlopper')
    assert_response :success
    settings = JSON.parse(response.body)['settings']
    assert_equal 'Hello', settings['welcome_text']
    assert_equal({ 'x' => 1 }, settings['company_icon'])
    refute settings.key?('mail_from')
  end

  def test_reachable_through_the_extended_api_prefix
    get '/extended_api/sprintly/roles.json', headers: auth('dlopper')
    assert_response :success
  end
end
