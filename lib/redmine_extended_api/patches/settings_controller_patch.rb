# frozen_string_literal: true

require_relative 'api_helpers'

module RedmineExtendedApi
  module Patches
    module SettingsControllerPatch
      include ApiHelpers

      SETTINGS_BY_TAB = {
        'general' => %w[
          app_title
          welcome_text
          default_language
          login_required
          self_registration
          lost_password
          autologin
          rest_api_enabled
          jsonp_enabled
          default_projects_public
          default_projects_modules
          default_projects_tracker_ids
          default_issue_start_date_to_creation_date
          attachment_max_size
          bulk_download_max_size
          attachment_extensions_allowed
          attachment_extensions_denied
          hosts_allowed
          hosts_denied
        ].freeze,
        'display' => %w[
          per_page_options
          gantt_items_limit
          activity_days_default
          display_subprojects_issues
          issues_export_limit
          issue_list_default_columns
          time_zone
          date_format
          time_format
          user_format
          thumbnails_enabled
          thumbnails_size
          gravatar_enabled
          gravatar_default
          new_item_menu_tab
        ].freeze
      }.freeze

      def self.prepended(base)
        base.accept_api_auth :index, :edit
        base.helper_method :extended_api_metadata if base.respond_to?(:helper_method)
      end

      # Redmine routes GET /settings → settings#index, so we handle both.
      def index
        edit
      end

      def edit
        unless extended_api_request?
          return super if defined?(super)

          return render_404
        end

        @settings_tab = params[:tab].presence || 'general'
        @settings_keys = SETTINGS_BY_TAB[@settings_tab]

        unless @settings_keys
          return render_api_error_message(
            "Unknown settings tab '#{@settings_tab}'. Valid tabs: #{SETTINGS_BY_TAB.keys.join(', ')}",
            status: :unprocessable_entity
          )
        end

        if request.put? || request.patch?
          raw_params = params[:settings]

          settings_params = if raw_params.respond_to?(:to_unsafe_hash)
                              raw_params.to_unsafe_hash
                            elsif raw_params.respond_to?(:to_h)
                              raw_params.to_h
                            else
                              {}
                            end

          # Restrict to whitelisted keys for the requested tab only
          filtered_params = settings_params.select { |k, _| @settings_keys.include?(k.to_s) }

          Setting.set_all_from_params(filtered_params) unless filtered_params.empty?
        end

        render_extended_api('settings/show')
      end
    end
  end
end
