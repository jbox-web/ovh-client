# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ovh::Client do
  def build(**overrides)
    described_class.new(
      application_key: 'ak', application_secret: 'as', consumer_key: 'ck', **overrides
    )
  end

  describe '.new' do
    it 'exposes the underlying ovh-api client' do
      expect(build.api).to be_a(Ovh::Api::Client)
    end

    it 'resolves the EU endpoint and api_version into the base URL' do
      expect(build(endpoint: :eu).api.configuration.base_url).to eq('https://eu.api.ovh.com/1.0')
    end

    it 'resolves the CA and US endpoints' do
      expect(build(endpoint: :ca).api.configuration.base_url).to eq('https://ca.api.ovh.com/1.0')
      expect(build(endpoint: :us).api.configuration.base_url).to eq('https://api.us.ovhcloud.com/1.0')
    end

    it 'accepts a full URL as endpoint' do
      expect(build(endpoint: 'https://api.ovh.com').api.configuration.base_url).to eq('https://api.ovh.com/1.0')
    end

    it 'raises on an unknown endpoint symbol' do
      expect { build(endpoint: :moon) }.to raise_error(ArgumentError, /unknown endpoint/)
    end
  end

  describe '#synchronize_time!' do
    it 'measures the offset from the unsigned /auth/time endpoint' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/time').to_return(status: 200, body: '1700000005')
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))
      client = build
      expect(client.synchronize_time!).to eq(5)
    end

    it 'does not sign the /auth/time request' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/time').to_return(status: 200, body: '1700000000')
      build.synchronize_time!
      expect(
        a_request(:get, 'https://eu.api.ovh.com/1.0/auth/time')
          .with { |req| !req.headers.key?('X-Ovh-Signature') }
      ).to have_been_made
    end
  end

  describe 'auto_sync_time' do
    it 'syncs once before the first signed request and applies the offset' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/time').to_return(status: 200, body: '1700000005')
      stub_request(:get, 'https://eu.api.ovh.com/1.0/me').to_return(status: 200, body: '{}')
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))
      client = build(auto_sync_time: true)
      client.api.connection.call(:GET, '/me')
      expect(a_request(:get, 'https://eu.api.ovh.com/1.0/auth/time')).to have_been_made.once
      expect(
        a_request(:get, 'https://eu.api.ovh.com/1.0/me')
          .with { |req| req.headers['X-Ovh-Timestamp'] == '1700000005' }
      ).to have_been_made
    end
  end

  describe '#current_credential' do
    it 'fetches the current credential' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/currentCredential')
        .to_return(status: 200, body: '{"status":"validated"}', headers: { 'Content-Type' => 'application/json' })
      expect(build.current_credential).to eq({ 'status' => 'validated' })
    end
  end

  describe '.request_consumer_key' do
    it 'posts the access rules and returns the credential envelope' do
      stub_request(:post, 'https://eu.api.ovh.com/1.0/auth/credential')
        .to_return(status: 200,
                   body: '{"consumerKey":"newck","validationUrl":"https://v","state":"pendingValidation"}',
                   headers: { 'Content-Type' => 'application/json' })
      result = described_class.request_consumer_key(
        application_key: 'ak', access_rules: [{ 'method' => 'GET', 'path' => '/*' }]
      )
      expect(result['consumerKey']).to eq('newck')
    end

    it 'sends only the application header (no consumer key, no signature)' do
      stub_request(:post, 'https://eu.api.ovh.com/1.0/auth/credential')
        .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
      described_class.request_consumer_key(
        application_key: 'ak', access_rules: [{ 'method' => 'GET', 'path' => '/*' }]
      )
      expect(
        a_request(:post, 'https://eu.api.ovh.com/1.0/auth/credential')
          .with do |req|
            req.headers['X-Ovh-Application'] == 'ak' &&
              !req.headers.key?('X-Ovh-Consumer') &&
              !req.headers.key?('X-Ovh-Signature')
          end
      ).to have_been_made
    end
  end

  describe 'signed requests through ovh-api' do
    it 'signs a normal request with all four OVH headers' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/me').to_return(status: 200, body: '{}')
      build.api.connection.call(:GET, '/me')
      expect(
        a_request(:get, 'https://eu.api.ovh.com/1.0/me').with do |req|
          req.headers['X-Ovh-Application'] == 'ak' &&
            req.headers['X-Ovh-Consumer'] == 'ck' &&
            req.headers['X-Ovh-Signature'].to_s.start_with?('$1$') &&
            !req.headers['X-Ovh-Timestamp'].to_s.empty?
        end
      ).to have_been_made
    end

    it 're-signs each retry attempt with a fresh timestamp' do
      # Incrementing Time.now so successive signatures differ; the block form never
      # exhausts (unlike a fixed list), which is safe for faraday-retry's own timing.
      counter = 1_700_000_000
      allow(Time).to receive(:now) { counter += 1; Time.at(counter) }

      timestamps = []
      stub_request(:get, 'https://eu.api.ovh.com/1.0/me').to_return do |req|
        timestamps << req.headers['X-Ovh-Timestamp']
        { status: timestamps.length == 1 ? 429 : 200, body: '{}' }
      end

      build(retries: 1).api.connection.call(:GET, '/me')

      expect(timestamps.length).to eq(2)                # two attempts reached the server
      expect(timestamps.uniq.length).to eq(2)           # each freshly signed
    end
  end

  describe '.log_filters' do
    it 'scrubs each sensitive OVH header' do
      filters = described_class.log_filters
      %w[X-Ovh-Application X-Ovh-Consumer X-Ovh-Signature].each do |header|
        line = "#{header}: super-secret-value"
        scrubbed = filters.reduce(line) { |acc, (regex, replacement)| acc.gsub(regex, replacement) }
        expect(scrubbed).to eq("#{header}: [REDACTED]")
      end
    end
  end
end
