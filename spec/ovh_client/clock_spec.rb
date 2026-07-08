# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ovh::Client::Clock do
  it 'adds its delta to the current epoch' do
    reference = Time.now.to_i
    expect(described_class.new(delta: 10).now).to be_within(1).of(reference + 10)
  end

  it 'is not synced by default' do
    expect(described_class.new).not_to be_synced
  end

  it 'records the delta and becomes synced after synchronize!' do
    clock = described_class.new
    expect(clock.synchronize!(42)).to eq(42)
    expect(clock.delta).to eq(42)
    expect(clock).to be_synced
  end

  it 'runs the syncer exactly once across repeated ensure_synced calls' do
    calls = 0
    clock = described_class.new(syncer: -> { calls += 1 })
    clock.ensure_synced
    clock.ensure_synced
    expect(calls).to eq(1)
    expect(clock).to be_synced
  end

  it 'does nothing when no syncer is configured' do
    clock = described_class.new
    clock.ensure_synced
    expect(clock).not_to be_synced
  end

  it 'lets the syncer call synchronize! from inside ensure_synced (reentrant lock)' do
    clock = described_class.new(syncer: -> { clock.synchronize!(7) })
    expect { clock.ensure_synced }.not_to raise_error # a plain Mutex would deadlock here
    expect(clock).to be_synced
    expect(clock.delta).to eq(7)
  end
end
