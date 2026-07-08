# frozen_string_literal: true

require 'simplecov'
require 'simplecov_json_formatter'

SimpleCov.start do
  # HTML for humans, JSON (coverage/coverage.json) for the CI coverage upload.
  formatter SimpleCov::Formatter::MultiFormatter.new([
                                                       SimpleCov::Formatter::HTMLFormatter,
                                                       SimpleCov::Formatter::JSONFormatter
                                                     ])
  add_filter '/spec/'
end

require 'webmock/rspec'

RSpec.configure do |config|
  config.color = true
  config.order = :random
  Kernel.srand config.seed

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.disable_monkey_patching!
  config.raise_errors_for_deprecations!
end

require 'ovh-client'
