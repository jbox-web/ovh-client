# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ovh do
  it 'has a version number' do
    expect(Ovh::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
