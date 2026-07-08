# frozen_string_literal: true

# Gem version, kept in its own file so the gemspec can read it via
# `require_relative` without loading Faraday and the rest of the client.
#
# It lives on the top-level Ovh namespace (not Ovh::Client): reopening the
# already-defined module Ovh only adds a constant and never interferes with
# Zeitwerk's autoload of Ovh::Client. This file is Zeitwerk-ignored (see
# lib/ovh-client.rb) — it does not map to an Ovh::Version constant — and is
# required directly by the bootstrap and by the gemspec.
module Ovh
  VERSION = '0.1.0'
end
