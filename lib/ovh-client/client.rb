# frozen_string_literal: true

module Ovh
  # Signing wrapper over the generated {Ovh::Api} transport gem. It builds an
  # Ovh::Api::Client and wires request signing (and optional retries) onto its
  # middleware seam, then exposes the generated surface through {#api}.
  #
  # @example
  #   ovh = Ovh::Client.new(application_key: 'ak', application_secret: 'as', consumer_key: 'ck')
  #   ovh.api.me.get_me
  class Client
    # Ovh::VERSION lives in version.rb (required by the bootstrap and the gemspec).

    # OVH API endpoints per datacenter. Combined with the api_version to form base_url.
    ENDPOINTS = {
      eu: 'https://eu.api.ovh.com',
      ca: 'https://ca.api.ovh.com',
      us: 'https://api.us.ovhcloud.com'
    }.freeze

    # HTTP statuses worth retrying: OVH rate limiting and transient gateway/server
    # errors. Retries apply to idempotent verbs only (never POST/PATCH).
    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
    RETRY_METHODS  = %i[get head delete put].freeze

    REDACTED = '[REDACTED]'
    # Credential headers to scrub from any downstream logger. ovh-api's built-in
    # logger runs before signing so it never sees these; these filters are for a
    # caller-supplied logger placed after the signature middleware.
    SENSITIVE_HEADERS = %w[X-Ovh-Application X-Ovh-Consumer X-Ovh-Signature].freeze

    # @return [Ovh::Api::Client] the generated transport client
    attr_reader :api

    # Regex/replacement pairs that scrub the OVH credential headers from a Faraday
    # logger's output. Use when wiring your own logger downstream of signing.
    # @return [Array<(Regexp, String)>]
    def self.log_filters
      SENSITIVE_HEADERS.map do |header|
        [/(#{Regexp.escape(header)}:\s*)[^\r\n]+/i, "\\1#{REDACTED}"]
      end
    end

    # @param endpoint [Symbol, String] an {ENDPOINTS} key or a full base URL
    # @param api_version [String] OVH API version (path prefix)
    # @param time_delta [Integer] initial signing clock offset, in seconds
    # @param auto_sync_time [Boolean] sync the clock against OVH before the first signed request
    # @param retries [Integer] retry idempotent requests on 429/5xx this many times (0 disables)
    # @param options [Hash] extra options forwarded to Ovh::Api::Client (e.g. logger:, timeout:)

    # Start the OVH credential flow: request a consumer key scoped to the given
    # access rules. Runs before a consumer key exists; needs only the application
    # key (the call is unsigned, so application_secret is irrelevant here). The
    # response carries a consumerKey and a validationUrl the end user must visit.
    #
    # @param access_rules [Array<Hash>] e.g. [{ 'method' => 'GET', 'path' => '/*' }]
    # @param redirection [String, nil] URL to redirect to after validation
    # @return [Object] parsed JSON response (consumerKey, validationUrl, state)
    def self.request_consumer_key(application_key:, access_rules:, endpoint: :eu, api_version: '1.0', redirection: nil)
      client = new(application_key: application_key, application_secret: nil, consumer_key: nil,
                   endpoint: endpoint, api_version: api_version)
      body = { 'accessRules' => access_rules }
      body['redirection'] = redirection if redirection
      client.api.connection.call(:POST, '/auth/credential', body: body).data
    end

    # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
    def initialize(application_key:, application_secret:, consumer_key:,
                   endpoint: :eu, api_version: '1.0',
                   time_delta: 0, auto_sync_time: false, retries: 0, **options)
      @retries = retries
      base_url = "#{resolve_endpoint(endpoint)}/#{api_version}"
      # method(:synchronize_time!) is bound now but only invoked on the first signed
      # request, by which point @api is set.
      @clock = Clock.new(delta: time_delta, syncer: (auto_sync_time ? method(:synchronize_time!) : nil))
      @api = Ovh::Api::Client.new(base_url: base_url, **options) do |config|
        # Retry is registered before Signature so it wraps it: each retry attempt
        # re-enters Signature and re-signs with a fresh timestamp.
        config.use(Faraday::Retry::Middleware, retry_options) if retries.positive?
        config.use(Signature,
                   application_key: application_key,
                   application_secret: application_secret,
                   consumer_key: consumer_key,
                   clock: @clock)
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

    # Measure the offset between OVH's clock and the local one and remember it for
    # every subsequent signed request. The call is unsigned (the /auth/time endpoint
    # is public and skip-listed by {Signature}).
    #
    # @return [Integer] the computed offset, in seconds
    def synchronize_time!
      server = @api.connection.call(:GET, '/auth/time').data
      delta  = server.to_i - Time.now.to_i
      @clock.synchronize!(delta)
      delta
    end

    # Fetch the credential currently in use (scope, status, expiration).
    # @return [Object] parsed JSON response
    def current_credential
      @api.connection.call(:GET, '/auth/currentCredential').data
    end

    private

    def resolve_endpoint(endpoint)
      return endpoint if endpoint.is_a?(String)

      ENDPOINTS.fetch(endpoint) do
        raise ArgumentError,
              "unknown endpoint #{endpoint.inspect}; expected one of #{ENDPOINTS.keys.inspect} or a full URL string"
      end
    end

    def retry_options
      {
        max: @retries,
        interval: 0.5,
        backoff_factor: 2,
        retry_statuses: RETRY_STATUSES,
        methods: RETRY_METHODS
      }
    end
  end
end
