# frozen_string_literal: true

require 'ostruct'
require 'active_support/core_ext/object/blank'
require_relative 'spec_helper'
require_relative '../lib/redmine_extended_api/patches/api_helpers'
require_relative '../lib/redmine_extended_api/patches/settings_controller_patch'

RSpec.describe RedmineExtendedApi::Patches::SettingsControllerPatch do
  ResponseStub = Class.new do
    attr_accessor :headers

    def initialize
      @headers = {}
    end

    def set_header(name, value)
      headers[name] = value
    end
  end unless defined?(ResponseStub)

  let(:controller_class) do
    Class.new do
      class << self
        attr_reader :accepted_actions

        def accept_api_auth(*actions)
          @accepted_actions ||= []
          @accepted_actions.concat(actions)
        end

        def helper_methods
          @helper_methods ||= []
        end

        def helper_method(*methods)
          helper_methods.concat(methods)
        end
      end

      attr_accessor :params, :request

      def initialize
        @super_calls = Hash.new(0)
        @response = ResponseStub.new
      end

      def super_calls
        @super_calls
      end

      def api_request?
        false
      end

      def edit
        @super_calls[:edit] += 1
        :base_edit
      end

      def render(*)
      end

      def render_404(*)
        :render_404
      end

      def head(*)
      end

      def response
        @response
      end

      def respond_to
        yield OpenStruct.new(api: ->(&block) { block.call })
      end
    end.tap do |klass|
      klass.prepend described_class
    end
  end

  let(:controller) { controller_class.new }

  describe '.prepended' do
    it 'registers API auth for edit action' do
      expect(controller_class.accepted_actions).to include(:edit)
    end

    it 'exposes extended_api_metadata as a helper' do
      expect(controller_class.helper_methods).to include(:extended_api_metadata)
    end
  end

  describe 'SETTINGS_BY_TAB' do
    it 'defines a general tab with expected keys' do
      general_keys = described_class::SETTINGS_BY_TAB['general']
      expect(general_keys).to include('app_title', 'default_language', 'login_required', 'rest_api_enabled')
    end

    it 'defines a display tab with expected keys' do
      display_keys = described_class::SETTINGS_BY_TAB['display']
      expect(display_keys).to include('per_page_options', 'date_format', 'time_zone', 'gravatar_enabled')
    end
  end

  describe '#edit' do
    before do
      allow(controller).to receive(:extended_api_request?) { controller.api_request? }
    end

    context 'when the request is not an extended API request' do
      before { allow(controller).to receive(:api_request?).and_return(false) }

      it 'falls back to the original implementation' do
        controller.params = {}
        expect(controller.edit).to eq(:base_edit)
        expect(controller.super_calls[:edit]).to eq(1)
      end
    end

    context 'when the request is an extended API GET request' do
      let(:request) { double('Request', get?: true, put?: false, patch?: false) }

      before do
        allow(controller).to receive(:api_request?).and_return(true)
        allow(controller).to receive(:render_extended_api)
        allow(controller).to receive(:render_api_error_message)
        controller.request = request
        controller.params = {}

        stub_const('Setting', Module.new do
          def self.respond_to?(method, include_private = false)
            %w[app_title default_language login_required].include?(method.to_s) || super
          end

          def self.app_title = 'My Redmine'
          def self.default_language = 'en'
          def self.login_required = '0'
        end)
      end

      it 'renders settings/show for the default general tab' do
        expect(controller).to receive(:render_extended_api).with('settings/show')
        controller.edit
      end

      it 'sets @settings_tab to general by default' do
        controller.edit
        expect(controller.instance_variable_get(:@settings_tab)).to eq('general')
      end

      it 'sets @settings_tab from params' do
        controller.params = { tab: 'display' }
        controller.edit
        expect(controller.instance_variable_get(:@settings_tab)).to eq('display')
      end

      it 'sets @settings_keys for the general tab' do
        controller.edit
        expect(controller.instance_variable_get(:@settings_keys)).to eq(
          described_class::SETTINGS_BY_TAB['general']
        )
      end

      it 'renders an error for an unknown tab' do
        controller.params = { tab: 'unknown_tab' }
        expect(controller).to receive(:render_api_error_message).with(
          a_string_including('unknown_tab'),
          status: :unprocessable_entity
        )
        controller.edit
      end

      it 'does not call Setting.set_all_from_params on GET' do
        expect(Setting).not_to receive(:set_all_from_params)
        controller.edit
      end
    end

    context 'when the request is an extended API PUT request' do
      let(:settings_params) do
        double('ActionController::Parameters',
               to_unsafe_hash: { 'app_title' => 'New Title', 'default_language' => 'fr' },
               respond_to?: true)
      end
      let(:request) { double('Request', get?: false, put?: true, patch?: false) }

      before do
        allow(controller).to receive(:api_request?).and_return(true)
        allow(controller).to receive(:render_extended_api)
        controller.request = request
        controller.params = { tab: 'general', settings: settings_params }

        stub_const('Setting', Module.new do
          def self.set_all_from_params(_); end
          def self.respond_to?(*) = true
        end)
      end

      it 'calls set_all_from_params with filtered whitelisted keys' do
        expect(Setting).to receive(:set_all_from_params).with(
          hash_including('app_title' => 'New Title', 'default_language' => 'fr')
        )
        controller.edit
      end

      it 'renders settings/show after updating' do
        allow(Setting).to receive(:set_all_from_params)
        expect(controller).to receive(:render_extended_api).with('settings/show')
        controller.edit
      end

      it 'strips keys not in the whitelisted tab settings' do
        allow(settings_params).to receive(:to_unsafe_hash).and_return(
          'app_title' => 'New Title',
          'not_a_valid_key' => 'evil_value'
        )

        expect(Setting).to receive(:set_all_from_params) do |params|
          expect(params).to have_key('app_title')
          expect(params).not_to have_key('not_a_valid_key')
        end

        controller.edit
      end

      it 'strips keys belonging to a different tab' do
        allow(settings_params).to receive(:to_unsafe_hash).and_return(
          'app_title' => 'New Title',
          'per_page_options' => '25,50'   # display tab key
        )

        expect(Setting).to receive(:set_all_from_params) do |params|
          expect(params).to have_key('app_title')
          expect(params).not_to have_key('per_page_options')
        end

        controller.edit
      end
    end

    context 'when the request is an extended API PATCH request' do
      let(:settings_params) do
        double('ActionController::Parameters',
               to_unsafe_hash: { 'time_zone' => 'UTC' },
               respond_to?: true)
      end
      let(:request) { double('Request', get?: false, put?: false, patch?: true) }

      before do
        allow(controller).to receive(:api_request?).and_return(true)
        allow(controller).to receive(:render_extended_api)
        controller.request = request
        controller.params = { tab: 'display', settings: settings_params }

        stub_const('Setting', Module.new do
          def self.set_all_from_params(_); end
          def self.respond_to?(*) = true
        end)
      end

      it 'updates settings on PATCH requests' do
        expect(Setting).to receive(:set_all_from_params).with(hash_including('time_zone' => 'UTC'))
        controller.edit
      end
    end
  end
end
