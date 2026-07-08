# frozen_string_literal: true

require 'digest'
require 'faraday'
require 'faraday/retry'
require 'zeitwerk'

require 'ovh-api'

module Ovh; end

loader = Zeitwerk::Loader.new
loader.push_dir("#{__dir__}/ovh-client", namespace: Ovh)
# version.rb defines Ovh::VERSION on the top-level namespace; it is not a
# Zeitwerk-managed constant (it must not map to an Ovh::Version file). It is
# required directly, both here and by the gemspec (require_relative), so keep
# the loader off it.
loader.ignore("#{__dir__}/ovh-client/version.rb")
loader.setup

# Make Ovh::VERSION available at require time. Reopening the top-level module Ovh
# only adds the constant; it never touches Zeitwerk's autoload of Ovh::Client.
require_relative 'ovh-client/version'
