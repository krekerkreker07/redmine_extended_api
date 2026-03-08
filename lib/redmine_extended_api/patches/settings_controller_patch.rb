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
          per_page_options
          search_results_per_page
          activity_days_default
          host_name
          protocol
          text_formatting
          cache_formatted_text
          wiki_compression
          feeds_limit
        ].freeze,
        'display' => %w[
          ui_theme
          default_language
          force_default_language_for_anonymous
          force_default_language_for_loggedin
          start_of_week
          date_format
          time_format
          timespan_format
          user_format
          gravatar_enabled
          gravatar_default
          thumbnails_enabled
          thumbnails_size
          new_item_menu_tab
        ].freeze
      }.freeze

      def self.prepended(base)
        base.accept_api_auth :index, :edit
        base.helper_method :extended_api_metadata if base.respond_to?(:helper_method)
      end

      # Redmine routes GET /settings → settings#index for all requests.
      # Delegate to our edit logic only for extended API requests; otherwise let
      # the original SettingsController#index render the HTML admin page.
      def index
        return edit if extended_api_request?

        super
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

          # Restrict to whitelisted keys for the requested tab only, then save
          # using the same per-setter approach Redmine's own SettingsController uses.
          settings_params.each do |key, value|
            next unless @settings_keys.include?(key.to_s)
            next unless Setting.respond_to?(:"#{key}=")

            Setting.send(:"#{key}=", value)
          end
        end

        render_extended_api('settings/show')
      end
    end
  end
end
