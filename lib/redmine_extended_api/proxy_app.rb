# frozen_string_literal: true
# lib/redmine_extended_api/proxy_app.rb

require 'active_support/inflector'      # module-API: camelize/safe_constantize
require 'json'
require 'rack/request'

module RedmineExtendedApi
  class ProxyApp
    ROUTE_ENV_KEYS = %w[
      action_dispatch.request.parameters
      action_dispatch.request.path_parameters
      action_dispatch.request.query_parameters
      action_dispatch.request.request_parameters
      action_dispatch.request.formats
      action_dispatch.request.content_type
      action_dispatch.request.filtered_parameters
    ].freeze

    API_FORMATS = %w[json xml].freeze

    def call(env)
      rewritten_env = rewrite_env(env)
      request = build_request(rewritten_env)

      return not_found_response unless api_request?(request)

      status, headers, body = Rails.application.call(rewritten_env)
      headers = headers ? headers.dup : {}
      headers['X-Redmine-Extended-API'] ||= 'native'

      [status, headers, body]
    end

    private

    def build_request(env)
      if defined?(ActionDispatch::Request)
        ActionDispatch::Request.new(env)
      else
        Rack::Request.new(env)
      end
    end

    def api_request?(request)
      route_params = recognize_route(request)
      return false unless route_params

      return false unless api_format?(route_params)

      controller_name = route_params[:controller] || route_params['controller']
      controller = controller_for_route(controller_name)
      return false unless controller

      action = route_params[:action] || route_params['action']
      accepts_api_auth?(controller, action)
    end

    def api_format?(route_params)
      fmt = (route_params[:format] || route_params['format']).to_s.downcase
      API_FORMATS.include?(fmt)
    end

    def recognize_route(request)
      # >>> Only change: pass method as uppercase STRING to satisfy strict RSpec doubles
      method_str =
        if request.respond_to?(:request_method)
          request.request_method.to_s.upcase   # "GET", "POST", ...
        else
          # ultra-fallback (shouldn't hit)
          (request.request_method_symbol || :get).to_s.upcase
        end

      Rails.application.routes.recognize_path(
        request.path,
        method: method_str
      )
    rescue StandardError
      nil
    end

    def controller_for_route(controller_path)
      return nil if controller_path.nil? || controller_path.empty?

      camel = ActiveSupport::Inflector.camelize(controller_path) # "roles" -> "Roles"
      ActiveSupport::Inflector.safe_constantize("#{camel}Controller")
    end

    def accepts_api_auth?(controller, action)
      return false if action.nil?

      sym = action.to_sym

      # 1. accept_api_auth?(action) – some Redmine versions accept an action argument;
      #    others define it as a no-arg boolean flag.  Rescue ArgumentError so we fall
      #    through to the explicit list checks when the method doesn't accept args.
      if controller.respond_to?(:accept_api_auth?)
        begin
          result = controller.accept_api_auth?(sym)
          return result
        rescue ArgumentError
          # no-arg version – fall through to list-based checks below
        end
      end

      # 2. Some custom setups expose the list via accept_api_auth_actions
      if controller.respond_to?(:accept_api_auth_actions)
        return Array(controller.accept_api_auth_actions).include?(sym)
      end

      # 3. Standard Redmine: accept_api_auth() with no args returns the registered Array
      #    This is also how our patches register actions via `base.accept_api_auth :edit`.
      if controller.respond_to?(:accept_api_auth)
        begin
          return Array(controller.accept_api_auth).include?(sym)
        rescue ArgumentError
          # unexpected – just fall through
        end
      end

      false
    end

    def not_found_response
      body = { error: 'Not a REST API endpoint' }.to_json
      [
        404,
        { 'Content-Type' => 'application/json; charset=utf-8' },
        [body]
      ]
    end

    def rewrite_env(env)
      env = env.dup

      original_script_name = env['SCRIPT_NAME'].to_s
      original_path_info   = env['PATH_INFO'].to_s
      query_string         = env['QUERY_STRING'].to_s

      new_script_name = remove_proxy_prefix_from(original_script_name)
      new_path_info   = normalize_path(strip_proxy_prefix_from(original_path_info))

      request_path = build_request_path(new_script_name, new_path_info)
      full_path    = build_full_path(request_path, query_string)

      env['redmine_extended_api.original_script_name'] = original_script_name
      env['redmine_extended_api.original_path_info']   = original_path_info

      env['SCRIPT_NAME']                    = new_script_name
      env['PATH_INFO']                      = new_path_info
      env['RAW_PATH_INFO']                  = new_path_info
      env['REQUEST_PATH']                   = request_path
      env['REQUEST_URI']                    = full_path
      env['ORIGINAL_FULLPATH']              = full_path
      env['action_dispatch.original_path']  = request_path
      env['action_dispatch.original_fullpath'] = full_path

      ROUTE_ENV_KEYS.each { |key| env.delete(key) }
      env.delete('action_dispatch.routes')
      env.delete('rack.request.query_string')
      env.delete('rack.request.query_hash')
      env.delete('rack.request.form_hash')
      env.delete('rack.request.form_vars')

      env
    end

    def remove_proxy_prefix_from(script_name)
      script_name.sub(%r{#{Regexp.escape(RedmineExtendedApi::API_PREFIX)}\z}, '')
    end

    def build_request_path(script_name, path_info)
      combined = "#{script_name}#{path_info}"
      combined.empty? ? '/' : combined
    end

    def build_full_path(request_path, query_string)
      return request_path if query_string.empty?

      "#{request_path}?#{query_string}"
    end

    def strip_proxy_prefix_from(path)
      path.sub(%r{\A#{Regexp.escape(RedmineExtendedApi::API_PREFIX)}}, '')
    end

    def normalize_path(path)
      p = path.to_s
      p.empty? ? '/' : p
    end

  end
end
