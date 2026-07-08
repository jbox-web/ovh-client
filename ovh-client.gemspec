# frozen_string_literal: true

# VERSION lives in its own file that reopens Ovh::Client with no transport
# dependencies, so require_relative here doesn't load Faraday or the rest of the client.
require_relative 'lib/ovh-client/version'

Gem::Specification.new do |s|
  s.name     = 'ovh-client'
  s.version  = Ovh::VERSION
  s.platform = Gem::Platform::RUBY
  s.authors  = ['Nicolas Rodriguez']
  s.email    = ['nico@nicoladmin.fr']
  s.homepage = 'https://github.com/jbox-web/ovh-client'
  s.summary  = 'Signing wrapper over ovh-api: OVH request auth, clock-skew, consumer-key bootstrap, retries'
  s.description = 'Hand-written wrapper over the generated ovh-api transport gem. Adds OVH request signing as a Faraday middleware, clock-skew handling, the consumer-key bootstrap flow, and per-attempt-re-signing retries.'
  s.license = 'MIT'

  s.required_ruby_version = '>= 3.2.0'

  s.files = Dir['LICENSE', 'README.md', 'CHANGELOG.md', 'lib/**/*.rb']

  # The signing seam depends on Faraday 2's middleware/env API; pin the major.
  s.add_dependency 'faraday', '~> 2'
  s.add_dependency 'faraday-retry'
  # This is jbox-web's ovh-api (Ovh::Api, Faraday), NOT the unrelated RubyGems gem
  # of the same name. Source it from GitHub in your Gemfile:
  #   gem 'ovh-api', git: 'https://github.com/jbox-web/ovh-api.git'
  s.add_dependency 'ovh-api'
  s.add_dependency 'zeitwerk'
end
