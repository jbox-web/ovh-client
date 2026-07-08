# frozen_string_literal: true

require 'digest'

module Ovh
  class Client
    # Faraday middleware that signs each request with OVH's scheme. It runs after
    # ovh-api's built-in request middleware (so it sees the serialized body and the
    # final URL) and just before the adapter, so the signed URL matches what is sent
    # byte-for-byte.
    #
    # Registered via Configuration#use, which passes options as a single positional
    # Hash (Ruby 3 does not convert a positional Hash to keywords), so #initialize
    # takes an options Hash rather than keyword parameters.
    class Signature < Faraday::Middleware
      def initialize(app, options)
        super(app)
        @application_key    = options.fetch(:application_key)
        @application_secret = options.fetch(:application_secret)
        @consumer_key       = options.fetch(:consumer_key)
        @clock              = options.fetch(:clock)
      end

      def on_request(env)
        case env.url.path
        when %r{\A/[^/]+/auth/time/?\z}
          # Public endpoint used to measure clock skew: never signed, and it must
          # not trigger lazy sync (that would recurse through this middleware).
          nil
        when %r{\A/[^/]+/auth/credential/?\z}
          # Consumer-key bootstrap is POST /auth/credential: unsigned, application
          # header only (there may be no consumer key yet). Other verbs on this path
          # (e.g. GET to list credential IDs) are ordinary signed calls.
          env.method == :post ? (env.request_headers['X-Ovh-Application'] = @application_key) : sign(env)
        else
          sign(env)
        end
      end

      private

      def sign(env)
        @clock.ensure_synced
        timestamp = @clock.now.to_s
        env.request_headers['X-Ovh-Application'] = @application_key
        env.request_headers['X-Ovh-Consumer']    = @consumer_key
        env.request_headers['X-Ovh-Timestamp']   = timestamp
        env.request_headers['X-Ovh-Signature']   = signature(env, timestamp)
      end

      # SHA1 and the "$1$" prefix are mandated by the OVH signing protocol; this is
      # not a security choice and must not be "upgraded".
      def signature(env, timestamp)
        method  = env.method.to_s.upcase
        payload = "#{@application_secret}+#{@consumer_key}+#{method}+#{env.url}+#{env.body}+#{timestamp}"
        "$1$#{Digest::SHA1.hexdigest(payload)}"
      end
    end
  end
end
