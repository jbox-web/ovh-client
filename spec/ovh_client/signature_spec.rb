# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ovh::Client::Signature do
  # Build a Faraday stack that mirrors ovh-api's ordering (:json before the
  # signature) with the test adapter, so we can inspect the outgoing request.
  def build(clock:, consumer_key: 'ck', application_secret: 'as')
    stubs = Faraday::Adapter::Test::Stubs.new
    captured = {}
    yield stubs, captured if block_given?
    conn = Faraday.new do |f|
      f.request :json
      f.use described_class,
            application_key: 'ak', application_secret: application_secret,
            consumer_key: consumer_key, clock: clock
      f.adapter :test, stubs
    end
    [conn, captured]
  end

  let(:clock) { instance_double(Ovh::Client::Clock, now: 1_700_000_000, ensure_synced: nil) }

  it 'adds the four OVH auth headers on a normal request' do
    conn, captured = build(clock: clock) do |stubs, cap|
      stubs.get('/1.0/me') { |env| cap[:env] = env; [200, {}, '{}'] }
    end
    conn.get('https://eu.api.ovh.com/1.0/me')
    headers = captured[:env].request_headers
    expect(headers['X-Ovh-Application']).to eq('ak')
    expect(headers['X-Ovh-Consumer']).to eq('ck')
    expect(headers['X-Ovh-Timestamp']).to eq('1700000000')
    expect(headers['X-Ovh-Signature']).to start_with('$1$')
  end

  it 'signs over method, full URL (with query), empty body and timestamp' do
    conn, captured = build(clock: clock) do |stubs, cap|
      stubs.get('/1.0/me') { |env| cap[:env] = env; [200, {}, '{}'] }
    end
    conn.get('https://eu.api.ovh.com/1.0/me', { 'a' => '1' })
    url = captured[:env].url.to_s
    expect(url).to include('a=1') # the query MUST be part of the signed URL
    expected = "$1$#{Digest::SHA1.hexdigest("as+ck+GET+#{url}++1700000000")}"
    expect(captured[:env].request_headers['X-Ovh-Signature']).to eq(expected)
  end

  it 'signs over the serialized JSON body on a POST' do
    conn, captured = build(clock: clock) do |stubs, cap|
      stubs.post('/1.0/sms') do |env|
        cap[:env] = env
        cap[:req_body] = env.body
        [200, {}, '{}']
      end
    end
    conn.post('https://eu.api.ovh.com/1.0/sms', { 'message' => 'hi' })
    env  = captured[:env]
    body = captured[:req_body]
    expect(body).to eq('{"message":"hi"}')
    expected = "$1$#{Digest::SHA1.hexdigest("as+ck+POST+#{env.url}+#{body}+1700000000")}"
    expect(env.request_headers['X-Ovh-Signature']).to eq(expected)
  end

  it 'synchronizes the clock before signing' do
    expect(clock).to receive(:ensure_synced).ordered
    expect(clock).to receive(:now).ordered.and_return(1_700_000_000)
    conn, = build(clock: clock) do |stubs, _cap|
      stubs.get('/1.0/me') { [200, {}, '{}'] }
    end
    conn.get('https://eu.api.ovh.com/1.0/me')
  end

  context 'with public OVH endpoints' do
    it 'does not sign GET /auth/time' do
      conn, captured = build(clock: clock) do |stubs, cap|
        stubs.get('/1.0/auth/time') { |env| cap[:env] = env; [200, {}, '1700000000'] }
      end
      conn.get('https://eu.api.ovh.com/1.0/auth/time')
      headers = captured[:env].request_headers
      expect(headers).not_to have_key('X-Ovh-Application')
      expect(headers).not_to have_key('X-Ovh-Signature')
    end

    it 'does not call the clock for /auth/time' do
      expect(clock).not_to receive(:ensure_synced)
      conn, = build(clock: clock) do |stubs, _cap|
        stubs.get('/1.0/auth/time') { [200, {}, '1700000000'] }
      end
      conn.get('https://eu.api.ovh.com/1.0/auth/time')
    end

    it 'sends only the application header on POST /auth/credential' do
      conn, captured = build(clock: clock, consumer_key: nil, application_secret: nil) do |stubs, cap|
        stubs.post('/1.0/auth/credential') { |env| cap[:env] = env; [200, {}, '{}'] }
      end
      conn.post('https://eu.api.ovh.com/1.0/auth/credential', { 'accessRules' => [] })
      headers = captured[:env].request_headers
      expect(headers['X-Ovh-Application']).to eq('ak')
      expect(headers).not_to have_key('X-Ovh-Consumer')
      expect(headers).not_to have_key('X-Ovh-Signature')
    end

    it 'fully signs a non-POST request to /auth/credential (e.g. GET list)' do
      conn, captured = build(clock: clock) do |stubs, cap|
        stubs.get('/1.0/auth/credential') { |env| cap[:env] = env; [200, {}, '[]'] }
      end
      conn.get('https://eu.api.ovh.com/1.0/auth/credential')
      headers = captured[:env].request_headers
      expect(headers['X-Ovh-Consumer']).to eq('ck')
      expect(headers['X-Ovh-Signature']).to start_with('$1$')
    end
  end
end
