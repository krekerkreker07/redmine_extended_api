# frozen_string_literal: true

Rails.application.routes.draw do
  constraints format: /(json|xml)/, id: /\d+/ do
    get 'custom_fields/:id(.:format)', to: 'custom_fields#show', as: nil
    get 'enumerations/:id(.:format)', to: 'enumerations#show', as: nil
    get 'issue_statuses/:id(.:format)', to: 'issue_statuses#show', as: nil
    get 'trackers/:id(.:format)', to: 'trackers#show', as: nil
  end

  constraints format: /(json|xml)/ do
    get   'settings(.:format)', to: 'settings#edit', as: nil
    put   'settings(.:format)', to: 'settings#edit', as: nil
    patch 'settings(.:format)', to: 'settings#edit', as: nil
  end

  # SPR-383: the Sprintly role model. Also reachable as /extended_api/sprintly/... .
  scope 'sprintly', controller: 'sprintly_access' do
    get    'me(.:format)', action: 'me'
    get    'roles(.:format)', action: 'roles'
    post   'roles(.:format)', action: 'create_role'
    put    'roles/:id(.:format)', action: 'update_role', constraints: { id: /\d+/ }
    delete 'roles/:id(.:format)', action: 'destroy_role', constraints: { id: /\d+/ }
    get    'assignments(.:format)', action: 'assignments'
    put    'assignments(.:format)', action: 'update_assignments'
    get    'projects/:project_id/assignments(.:format)', action: 'project_assignments'
    put    'projects/:project_id/assignments(.:format)', action: 'update_project_assignments'
    post   'import(.:format)', action: 'import'
    get    'principals(.:format)', action: 'principals'
    get    'custom_fields(.:format)', action: 'custom_fields'
    get    'app_config(.:format)', action: 'app_config'
  end

  # SPR-523: watchers of a wiki page, which is named by `title` (a parameter).
  scope 'sprintly/projects/:project_id/wiki', controller: 'sprintly_wiki_watchers' do
    get    'watchers(.:format)', action: 'index'
    post   'watchers(.:format)', action: 'create'
    delete 'watchers(.:format)', action: 'destroy'
  end

  # SPR-529: comments of a wiki page.
  scope 'sprintly/projects/:project_id/wiki', controller: 'sprintly_wiki_comments' do
    get    'comments(.:format)', action: 'index'
    post   'comments(.:format)', action: 'create'
    put    'comments/:id(.:format)', action: 'update', constraints: { id: /\d+/ }
    delete 'comments/:id(.:format)', action: 'destroy', constraints: { id: /\d+/ }
  end

  # SPR-524 / SPR-530: wiki backlinks and labels (links lane). Also reachable as /extended_api/sprintly/... .
  scope 'sprintly/projects/:project_id/wiki' do
    get 'backlinks(.:format)', to: 'sprintly_wiki_links#backlinks', as: nil
    get 'labels(.:format)', to: 'sprintly_wiki_labels#index', as: nil
    put 'labels(.:format)', to: 'sprintly_wiki_labels#update', as: nil
  end

  # SPR-521/522: a wiki page's history, diff, annotate and lock as JSON. Also under /extended_api/... .
  scope 'sprintly/projects/:project_id/wiki/:id', controller: 'sprintly_wiki' do
    get 'history(.:format)', action: 'history'
    get 'diff(.:format)', action: 'diff'
    get 'annotate(.:format)', action: 'annotate'
    # SPR-522: the page's lock.
    get 'protect(.:format)', action: 'protection'
    put 'protect(.:format)', action: 'protect'
  end

  # SPR-4669: VCS integrations of a project, read by scv-adapter. Also reachable as /extended_api/sprintly/... .
  scope 'sprintly/projects/:project_id', controller: 'sprintly_integrations' do
    get    'integrations(.:format)', action: 'index'
    post   'integrations(.:format)', action: 'create'
    put    'integrations/:id(.:format)', action: 'update', constraints: { id: /[A-Za-z0-9-]+/ }
    delete 'integrations/:id(.:format)', action: 'destroy', constraints: { id: /[A-Za-z0-9-]+/ }
  end

  # SPR-553: the signed-in user's own "App data". Also reachable as /extended_api/sprintly/... .
  scope 'sprintly/me', controller: 'sprintly_app_data' do
    get 'app_data(.:format)', action: 'show'
    put 'app_data(.:format)', action: 'update'
  end

  mount RedmineExtendedApi.proxy_app => RedmineExtendedApi::API_PREFIX
end
