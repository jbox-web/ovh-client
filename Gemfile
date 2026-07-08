# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# ovh-api is jbox-web's Faraday transport gem (Ovh::Api), not the unrelated
# RubyGems gem of the same name. Sourced from GitHub.
gem 'ovh-api', git: 'https://github.com/jbox-web/ovh-api.git'

group :development, :test do
  gem 'guard-rspec', require: false
  gem 'rake'
  gem 'rspec', '~> 3.6'
  gem 'simplecov', require: false
  gem 'webmock'

  gem 'rubocop',             require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rake',        require: false
  gem 'rubocop-rspec',       require: false
  gem 'yard',                require: false
end
