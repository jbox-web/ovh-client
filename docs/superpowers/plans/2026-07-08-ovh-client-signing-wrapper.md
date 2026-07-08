# ovh-client Signing Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `ovh-client` gem: a hand-written wrapper over `ovh-api` that supplies OVH request signing (as a Faraday middleware), clock-skew handling, consumer-key bootstrap, and per-attempt-re-signing retries.

**Architecture:** A wrapper class `Ovh::Client` builds an `Ovh::Api::Client` and wires two middlewares onto its `Configuration#use` seam — `faraday-retry` (outer) then `Ovh::Client::Signature` (inner), so each retry re-signs with a fresh timestamp. A shared `Ovh::Client::Clock` (mutable time offset, one-shot lazy sync) is referenced by both the wrapper and the middleware. The signature is computed over the final URL and serialized body Faraday actually sends. Public OVH endpoints (`/auth/time`, `/auth/credential`) are detected by path and left unsigned.

**Tech Stack:** Ruby ≥ 3.2, Faraday, faraday-retry, Zeitwerk, `ovh-api`. Tests: RSpec, WebMock, SimpleCov. Lint: RuboCop (+ performance/rake/rspec plugins).

## Global Constraints

- Ruby `>= 3.2.0` (`required_ruby_version`).
- Runtime deps ONLY: `ovh-api`, `faraday`, `faraday-retry`, `zeitwerk`. No others.
- Namespace `Ovh::Client`; sibling of `Ovh::Api`. Never enumerate `ovh-api` resource names (regeneration-proof): reach the generated surface only through `#api` and the stable `#api.connection.call` / `#api.configuration`.
- SHA1 and the `$1$` prefix are mandated by the OVH protocol — do not "upgrade" them.
- All deliverable text (code, comments, README) in English. Every file ends with a trailing newline.
- **Git:** commit steps are written per TDD cadence, but per the repo owner's workflow, actually running `git init` / `git commit` happens ONLY on the owner's explicit go-ahead. Treat each "Commit" step as a checkpoint gated on that.

## File Structure

```
ovh-client.gemspec                    # gem metadata; reads VERSION from client.rb via regex
Gemfile                               # gemspec + dev/test group
Rakefile                              # default task => spec
.rspec                                # --require spec_helper
.rubocop.yml                          # lint config, TargetRubyVersion 3.2
Guardfile                             # auto-run specs on change
bin/rspec, bin/rubocop, bin/console, bin/guard   # binstubs
lib/ovh-client.rb                     # bootstrap: requires + module Ovh + Zeitwerk loader
lib/ovh-client/client.rb              # Ovh::Client — VERSION, ENDPOINTS, wrapper + factory + bootstrap (explicit namespace)
lib/ovh-client/client/clock.rb        # Ovh::Client::Clock
lib/ovh-client/client/signature.rb    # Ovh::Client::Signature < Faraday::Middleware
spec/spec_helper.rb                   # RSpec + SimpleCov + WebMock config
spec/ovh_client/clock_spec.rb
spec/ovh_client/signature_spec.rb
spec/ovh_client/client_spec.rb        # factory + integration (WebMock)
README.md
```

Zeitwerk note: `lib/ovh-client.rb` defines `module Ovh` and pushes `lib/ovh-client` with `namespace: Ovh`. Then `client.rb → Ovh::Client` (an **explicit namespace**, because the sibling dir `client/` exists), `client/clock.rb → Ovh::Client::Clock`, `client/signature.rb → Ovh::Client::Signature`. `VERSION` lives at the top of `client.rb` (not a separate `version.rb`, which would clash with Zeitwerk's inflection and the explicit-namespace autoload); the gemspec reads it by regex without loading the file — same trick `ovh-api` uses.

Keyword-args note (confirmed from `ovh-api` source): `Configuration#use(mw, *args)` collapses trailing keywords into a single positional Hash, and Faraday later calls `mw.new(app, *args)` → `mw.new(app, {..})`. In Ruby 3 a positional Hash is NOT auto-converted to keywords, so `Ovh::Client::Signature#initialize` MUST take a positional options Hash, not keyword parameters.

---

### Task 1: Scaffold the gem (bootstrap, Zeitwerk, green empty suite)

**Files:**
- Create: `ovh-client.gemspec`, `Gemfile`, `Rakefile`, `.rspec`, `.rubocop.yml`, `Guardfile`
- Create: `lib/ovh-client.rb`, `lib/ovh-client/client.rb`
- Create: `spec/spec_helper.rb`, `spec/ovh_client/loads_spec.rb`
- Create: `bin/rspec`, `bin/rubocop`, `bin/console`, `bin/guard` (via `bundle binstubs`)

**Interfaces:**
- Produces: `Ovh::Client` (class, empty body for now) with `Ovh::Client::VERSION` constant; `require 'ovh-client'` loads the gem via Zeitwerk.

- [ ] **Step 1: Write the gemspec**

Create `ovh-client.gemspec`:

```ruby
# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name     = 'ovh-client'
  # VERSION lives at the top of client.rb; reading the literal via regex avoids
  # loading the file (and its deps) during gemspec evaluation.
  s.version  = File.read(File.expand_path('lib/ovh-client/client.rb', __dir__))[/VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
  s.platform = Gem::Platform::RUBY
  s.authors  = ['Nicolas Rodriguez']
  s.email    = ['nico@nicoladmin.fr']
  s.homepage = 'https://github.com/jbox-web/ovh-client'
  s.summary  = 'Signing wrapper over ovh-api: OVH request auth, clock-skew, consumer-key bootstrap, retries'
  s.description = 'Hand-written wrapper over the generated ovh-api transport gem. Adds OVH request signing as a Faraday middleware, clock-skew handling, the consumer-key bootstrap flow, and per-attempt-re-signing retries.'
  s.license  = 'MIT'

  s.required_ruby_version = '>= 3.2.0'

  s.files = Dir['LICENSE', 'README.md', 'lib/**/*.rb']

  s.add_dependency 'faraday'
  s.add_dependency 'faraday-retry'
  s.add_dependency 'ovh-api'
  s.add_dependency 'zeitwerk'
end
```

- [ ] **Step 2: Write the Gemfile, Rakefile, .rspec, .rubocop.yml, Guardfile**

`Gemfile`:

```ruby
# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

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
end
```

`Rakefile`:

```ruby
# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec
```

`.rspec`:

```
--require spec_helper
--color
```

`.rubocop.yml`:

```yaml
require:
  - rubocop-performance
  - rubocop-rake
  - rubocop-rspec

AllCops:
  TargetRubyVersion: 3.2
  NewCops: enable

# The dash-named entry file is a Zeitwerk bootstrap, not a namespace file.
Style/Documentation:
  Enabled: false

Metrics/BlockLength:
  Exclude:
    - 'spec/**/*'
    - '*.gemspec'
```

`Guardfile`:

```ruby
# frozen_string_literal: true

guard :rspec, cmd: 'bin/rspec' do
  watch(%r{^spec/.+_spec\.rb$})
  watch(%r{^lib/(.+)\.rb$}) { 'spec' }
  watch('spec/spec_helper.rb') { 'spec' }
end
```

- [ ] **Step 3: Write the Zeitwerk bootstrap and the empty Client class**

`lib/ovh-client.rb`:

```ruby
# frozen_string_literal: true

require 'digest'
require 'faraday'
require 'faraday/retry'
require 'zeitwerk'

require 'ovh-api'

module Ovh; end

loader = Zeitwerk::Loader.new
loader.push_dir("#{__dir__}/ovh-client", namespace: Ovh)
loader.setup
```

`lib/ovh-client/client.rb`:

```ruby
# frozen_string_literal: true

module Ovh
  # Signing wrapper over the generated {Ovh::Api} transport gem.
  class Client
    VERSION = '0.1.0'
  end
end
```

- [ ] **Step 4: Write spec_helper and a loading spec**

`spec/spec_helper.rb`:

```ruby
# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
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
```

`spec/ovh_client/loads_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Ovh::Client do
  it 'has a version number' do
    expect(Ovh::Client::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
```

- [ ] **Step 5: Install and generate binstubs**

Run:
```bash
cd /Users/nicolas/PROJECTS/CONCERTO/gems/RUBY/ovh-client
bundle install
bundle binstubs rspec-core rubocop guard bundler
```
Create `bin/console`:
```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'irb'
require 'ovh-client'
IRB.start(__FILE__)
```
Then `chmod +x bin/console`.

- [ ] **Step 6: Run the suite — expect green**

Run: `bin/rspec`
Expected: `1 example, 0 failures`.

- [ ] **Step 7: Run RuboCop — expect clean**

Run: `bin/rubocop`
Expected: `no offenses detected` (fix any with `bin/rubocop -a` if trivial formatting).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Scaffold ovh-client gem with Zeitwerk bootstrap"
```

---

### Task 2: Ovh::Client::Clock

**Files:**
- Create: `lib/ovh-client/client/clock.rb`
- Test: `spec/ovh_client/clock_spec.rb`

**Interfaces:**
- Produces: `Ovh::Client::Clock.new(delta: 0, syncer: nil)` with `#now → Integer`, `#delta → Integer`, `#synced? → Boolean`, `#synchronize!(delta) → Integer` (sets delta, marks synced), `#ensure_synced → void` (runs `syncer` exactly once under a mutex).
- Consumed by: Task 3 (Signature calls `clock.ensure_synced` then `clock.now`), Task 5/6 (wrapper calls `clock.synchronize!`).

- [ ] **Step 1: Write the failing test**

`spec/ovh_client/clock_spec.rb`:

```ruby
# frozen_string_literal: true

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
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rspec spec/ovh_client/clock_spec.rb`
Expected: FAIL — `uninitialized constant Ovh::Client::Clock`.

- [ ] **Step 3: Write the implementation**

`lib/ovh-client/client/clock.rb`:

```ruby
# frozen_string_literal: true

module Ovh
  class Client
    # Holds the offset between the OVH server clock and the local clock and
    # supplies the signature timestamp. OVH rejects signatures whose timestamp
    # drifts too far, so on a skewed host the offset is measured once (against
    # OVH's /auth/time endpoint) and reused for every signed request.
    class Clock
      # @return [Integer] offset in seconds added to the local clock
      attr_reader :delta

      # @param delta [Integer] initial offset in seconds
      # @param syncer [#call, nil] callable that measures and applies the offset;
      #   invoked at most once by {#ensure_synced}
      def initialize(delta: 0, syncer: nil)
        @delta  = delta
        @syncer = syncer
        @synced = false
        @mutex  = Mutex.new
      end

      # @return [Integer] the OVH-aligned epoch used as the signature timestamp
      def now
        Time.now.to_i + @delta
      end

      def synced?
        @synced
      end

      # Record a freshly measured offset and mark the clock synced so lazy
      # synchronization won't run again.
      # @return [Integer] the applied delta
      def synchronize!(delta)
        @delta  = delta
        @synced = true
        delta
      end

      # Run the syncer exactly once. Double-checked under a mutex so concurrent
      # first requests trigger a single synchronization.
      def ensure_synced
        return if @synced || @syncer.nil?

        @mutex.synchronize do
          break if @synced

          @syncer.call
          @synced = true
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rspec spec/ovh_client/clock_spec.rb`
Expected: `5 examples, 0 failures`.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop lib/ovh-client/client/clock.rb spec/ovh_client/clock_spec.rb
git add lib/ovh-client/client/clock.rb spec/ovh_client/clock_spec.rb
git commit -m "Add Ovh::Client::Clock with one-shot lazy sync"
```

---

### Task 3: Ovh::Client::Signature — full signing branch

**Files:**
- Create: `lib/ovh-client/client/signature.rb`
- Test: `spec/ovh_client/signature_spec.rb`

**Interfaces:**
- Produces: `Ovh::Client::Signature < Faraday::Middleware`, `#initialize(app, options)` where `options` is a Hash with keys `:application_key`, `:application_secret`, `:consumer_key`, `:clock`. On a non-public request it adds `X-Ovh-Application`, `X-Ovh-Consumer`, `X-Ovh-Timestamp`, `X-Ovh-Signature` (= `"$1$" + SHA1(secret+"+"+consumer+"+"+METHOD+"+"+url+"+"+body+"+"+timestamp)`), calling `clock.ensure_synced` first and `clock.now` for the timestamp.
- Consumes: `Ovh::Client::Clock` (Task 2).

- [ ] **Step 1: Write the failing test (full signing + query coverage)**

`spec/ovh_client/signature_spec.rb`:

```ruby
# frozen_string_literal: true

require 'digest'

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
      stubs.post('/1.0/sms') { |env| cap[:env] = env; [200, {}, '{}'] }
    end
    conn.post('https://eu.api.ovh.com/1.0/sms', { 'message' => 'hi' })
    env  = captured[:env]
    body = env.body
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
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rspec spec/ovh_client/signature_spec.rb`
Expected: FAIL — `uninitialized constant Ovh::Client::Signature`.

- [ ] **Step 3: Write the implementation (full-signing branch only)**

`lib/ovh-client/client/signature.rb`:

```ruby
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
        sign(env)
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rspec spec/ovh_client/signature_spec.rb`
Expected: `4 examples, 0 failures`. (This confirms the implementation-risk check: `env.url` carries the query string at `on_request` time.)

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop lib/ovh-client/client/signature.rb spec/ovh_client/signature_spec.rb
git add lib/ovh-client/client/signature.rb spec/ovh_client/signature_spec.rb
git commit -m "Add Ovh::Client::Signature full-signing branch"
```

---

### Task 4: Ovh::Client::Signature — public-endpoint branches

**Files:**
- Modify: `lib/ovh-client/client/signature.rb`
- Test: `spec/ovh_client/signature_spec.rb` (append)

**Interfaces:**
- Produces: on `…/auth/time` the middleware adds NO headers; on `…/auth/credential` it adds ONLY `X-Ovh-Application`; `clock.ensure_synced` is called only on the full-signing branch (never on public paths).

- [ ] **Step 1: Write the failing tests (append to signature_spec.rb)**

Add inside the `describe` block:

```ruby
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
  end
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bin/rspec spec/ovh_client/signature_spec.rb`
Expected: FAIL — `/auth/time` currently gets signed (`X-Ovh-Application` present; `ensure_synced` called).

- [ ] **Step 3: Update `on_request` to branch by path**

In `lib/ovh-client/client/signature.rb`, replace the `on_request` method with:

```ruby
      def on_request(env)
        case env.url.path
        when %r{/auth/time/?\z}
          # Public endpoint used to measure clock skew: never signed, and it must
          # not trigger lazy sync (that would recurse through this middleware).
          nil
        when %r{/auth/credential/?\z}
          # Consumer-key bootstrap: unsigned, application header only (there may be
          # no consumer key yet).
          env.request_headers['X-Ovh-Application'] = @application_key
        else
          sign(env)
        end
      end
```

- [ ] **Step 4: Run to verify all signature specs pass**

Run: `bin/rspec spec/ovh_client/signature_spec.rb`
Expected: `7 examples, 0 failures`.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop lib/ovh-client/client/signature.rb spec/ovh_client/signature_spec.rb
git add lib/ovh-client/client/signature.rb spec/ovh_client/signature_spec.rb
git commit -m "Skip signing on OVH public endpoints (auth/time, auth/credential)"
```

---

### Task 5: Ovh::Client factory — endpoints, base_url, `#api`, middleware wiring

**Files:**
- Modify: `lib/ovh-client/client.rb`
- Test: `spec/ovh_client/client_spec.rb`

**Interfaces:**
- Produces:
  - `Ovh::Client::ENDPOINTS` = `{ eu:, ca:, us: }`.
  - `Ovh::Client.new(application_key:, application_secret:, consumer_key:, endpoint: :eu, api_version: '1.0', time_delta: 0, auto_sync_time: false, retries: 0, **options)`.
  - `#api → Ovh::Api::Client` (its `Configuration#base_url` equals `"<endpoint-url>/<api_version>"`).
  - Registers `Faraday::Retry::Middleware` (only when `retries > 0`) BEFORE `Ovh::Client::Signature` via `config.use`.
- Consumes: `Signature` (Task 3-4), `Clock` (Task 2).

- [ ] **Step 1: Write the failing test**

`spec/ovh_client/client_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Ovh::Client do
  def build(**overrides)
    described_class.new(
      application_key: 'ak', application_secret: 'as', consumer_key: 'ck', **overrides
    )
  end

  describe '.new' do
    it 'exposes the underlying ovh-api client' do
      expect(build.api).to be_a(Ovh::Api::Client)
    end

    it 'resolves the EU endpoint and api_version into the base URL' do
      expect(build(endpoint: :eu).api.configuration.base_url).to eq('https://eu.api.ovh.com/1.0')
    end

    it 'resolves the CA and US endpoints' do
      expect(build(endpoint: :ca).api.configuration.base_url).to eq('https://ca.api.ovh.com/1.0')
      expect(build(endpoint: :us).api.configuration.base_url).to eq('https://api.us.ovhcloud.com/1.0')
    end

    it 'accepts a full URL as endpoint' do
      expect(build(endpoint: 'https://api.ovh.com').api.configuration.base_url).to eq('https://api.ovh.com/1.0')
    end

    it 'raises on an unknown endpoint symbol' do
      expect { build(endpoint: :moon) }.to raise_error(ArgumentError, /unknown endpoint/)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: FAIL — `wrong number of arguments` / `NoMethodError` (Client has no `.new` with these kwargs, no `#api`).

- [ ] **Step 3: Implement the factory**

Replace `lib/ovh-client/client.rb` with:

```ruby
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
    VERSION = '0.1.0'

    # OVH API endpoints per datacenter. Combined with the api_version to form base_url.
    ENDPOINTS = {
      eu: 'https://eu.api.ovh.com',
      ca: 'https://ca.api.ovh.com',
      us: 'https://api.us.ovhcloud.com',
    }.freeze

    # HTTP statuses worth retrying: OVH rate limiting and transient gateway/server
    # errors. Retries apply to idempotent verbs only (never POST/PATCH).
    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
    RETRY_METHODS  = %i[get head delete put].freeze

    # @return [Ovh::Api::Client] the generated transport client
    attr_reader :api

    # @param endpoint [Symbol, String] an {ENDPOINTS} key or a full base URL
    # @param api_version [String] OVH API version (path prefix)
    # @param time_delta [Integer] initial signing clock offset, in seconds
    # @param auto_sync_time [Boolean] sync the clock against OVH before the first signed request
    # @param retries [Integer] retry idempotent requests on 429/5xx this many times (0 disables)
    # @param options [Hash] extra options forwarded to Ovh::Api::Client (e.g. logger:, timeout:)
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

    private

    def resolve_endpoint(endpoint)
      return endpoint if endpoint.is_a?(String)

      ENDPOINTS.fetch(endpoint) do
        raise ArgumentError, "unknown endpoint #{endpoint.inspect}; expected one of #{ENDPOINTS.keys.inspect} or a full URL string"
      end
    end

    def retry_options
      {
        max:            @retries,
        interval:       0.5,
        backoff_factor: 2,
        retry_statuses: RETRY_STATUSES,
        methods:        RETRY_METHODS,
      }
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: `5 examples, 0 failures`.

- [ ] **Step 5: Run the full suite and lint**

Run: `bin/rspec` — Expected: all green.
Run: `bin/rubocop` — Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/ovh-client/client.rb spec/ovh_client/client_spec.rb
git commit -m "Add Ovh::Client factory: endpoints, base_url, api accessor, middleware wiring"
```

---

### Task 6: `#synchronize_time!` and lazy auto-sync (WebMock integration)

**Files:**
- Modify: `lib/ovh-client/client.rb`
- Test: `spec/ovh_client/client_spec.rb` (append)

**Interfaces:**
- Produces: `#synchronize_time! → Integer` (unsigned `GET /auth/time` via `#api.connection.call`, sets `delta = server_epoch - Time.now.to_i` on the shared clock, returns delta). With `auto_sync_time: true`, the first signed request triggers one sync before signing.

- [ ] **Step 1: Write the failing tests (append to client_spec.rb)**

Add inside the top-level `describe`:

```ruby
  describe '#synchronize_time!' do
    it 'measures the offset from the unsigned /auth/time endpoint' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/time').to_return(status: 200, body: '1700000005')
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))
      client = build
      expect(client.synchronize_time!).to eq(5)
    end

    it 'does not sign the /auth/time request' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/time').to_return(status: 200, body: '1700000000')
      build.synchronize_time!
      expect(
        a_request(:get, 'https://eu.api.ovh.com/1.0/auth/time')
          .with { |req| !req.headers.key?('X-Ovh-Signature') }
      ).to have_been_made
    end
  end

  describe 'auto_sync_time' do
    it 'syncs once before the first signed request and applies the offset' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/time').to_return(status: 200, body: '1700000005')
      stub_request(:get, 'https://eu.api.ovh.com/1.0/me').to_return(status: 200, body: '{}')
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))
      client = build(auto_sync_time: true)
      client.api.connection.call(:GET, '/me')
      expect(a_request(:get, 'https://eu.api.ovh.com/1.0/auth/time')).to have_been_made.once
      expect(
        a_request(:get, 'https://eu.api.ovh.com/1.0/me')
          .with { |req| req.headers['X-Ovh-Timestamp'] == '1700000005' }
      ).to have_been_made
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'synchronize_time!'`.

- [ ] **Step 3: Implement `synchronize_time!`**

In `lib/ovh-client/client.rb`, add a public method right after `attr_reader :api` block — i.e. after the `initialize` method, before `private`:

```ruby
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: all green (5 + 3 examples).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop lib/ovh-client/client.rb spec/ovh_client/client_spec.rb
git add lib/ovh-client/client.rb spec/ovh_client/client_spec.rb
git commit -m "Add clock synchronization (explicit and lazy auto-sync)"
```

---

### Task 7: `#current_credential` and `.request_consumer_key`

**Files:**
- Modify: `lib/ovh-client/client.rb`
- Test: `spec/ovh_client/client_spec.rb` (append)

**Interfaces:**
- Produces:
  - `#current_credential → Object` (`GET /auth/currentCredential` via `#api.connection.call`).
  - `Ovh::Client.request_consumer_key(application_key:, endpoint: :eu, api_version: '1.0', access_rules:, redirection: nil) → Object` (unsigned `POST /auth/credential`; application header only).

- [ ] **Step 1: Write the failing tests (append to client_spec.rb)**

```ruby
  describe '#current_credential' do
    it 'fetches the current credential' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/auth/currentCredential')
        .to_return(status: 200, body: '{"status":"validated"}', headers: { 'Content-Type' => 'application/json' })
      expect(build.current_credential).to eq({ 'status' => 'validated' })
    end
  end

  describe '.request_consumer_key' do
    it 'posts the access rules and returns the credential envelope' do
      stub_request(:post, 'https://eu.api.ovh.com/1.0/auth/credential')
        .to_return(status: 200,
                   body: '{"consumerKey":"newck","validationUrl":"https://v","state":"pendingValidation"}',
                   headers: { 'Content-Type' => 'application/json' })
      result = described_class.request_consumer_key(
        application_key: 'ak', access_rules: [{ 'method' => 'GET', 'path' => '/*' }]
      )
      expect(result['consumerKey']).to eq('newck')
    end

    it 'sends only the application header (no consumer key, no signature)' do
      stub_request(:post, 'https://eu.api.ovh.com/1.0/auth/credential')
        .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
      described_class.request_consumer_key(
        application_key: 'ak', access_rules: [{ 'method' => 'GET', 'path' => '/*' }]
      )
      expect(
        a_request(:post, 'https://eu.api.ovh.com/1.0/auth/credential')
          .with { |req| req.headers['X-Ovh-Application'] == 'ak' && !req.headers.key?('X-Ovh-Consumer') && !req.headers.key?('X-Ovh-Signature') }
      ).to have_been_made
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: FAIL — `undefined method 'current_credential'` / `request_consumer_key`.

- [ ] **Step 3: Implement both methods**

In `lib/ovh-client/client.rb`, add after `synchronize_time!` (still above `private`):

```ruby
    # Fetch the credential currently in use (scope, status, expiration).
    # @return [Object] parsed JSON response
    def current_credential
      @api.connection.call(:GET, '/auth/currentCredential').data
    end
```

And add a class method (place it above `def initialize`):

```ruby
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: all green.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop lib/ovh-client/client.rb spec/ovh_client/client_spec.rb
git add lib/ovh-client/client.rb spec/ovh_client/client_spec.rb
git commit -m "Add current_credential and consumer-key bootstrap"
```

---

### Task 8: Integration — signed round-trip and per-attempt re-signing (WebMock)

**Files:**
- Test: `spec/ovh_client/client_spec.rb` (append)

**Interfaces:**
- Consumes everything above. No production code changes expected; if the re-signing test fails it reveals a middleware-ordering bug in Task 5 to fix there.

- [ ] **Step 1: Write the failing/again-green integration tests (append to client_spec.rb)**

```ruby
  describe 'signed requests through ovh-api' do
    it 'signs a normal request with all four OVH headers' do
      stub_request(:get, 'https://eu.api.ovh.com/1.0/me').to_return(status: 200, body: '{}')
      build.api.connection.call(:GET, '/me')
      expect(
        a_request(:get, 'https://eu.api.ovh.com/1.0/me').with do |req|
          req.headers['X-Ovh-Application'] == 'ak' &&
            req.headers['X-Ovh-Consumer'] == 'ck' &&
            req.headers['X-Ovh-Signature'].to_s.start_with?('$1$') &&
            !req.headers['X-Ovh-Timestamp'].to_s.empty?
        end
      ).to have_been_made
    end

    it 're-signs each retry attempt with a fresh timestamp' do
      # Incrementing Time.now so successive signatures differ; the block form never
      # exhausts (unlike a fixed list), which is safe for faraday-retry's own timing.
      counter = 1_700_000_000
      allow(Time).to receive(:now) { counter += 1; Time.at(counter) }

      timestamps = []
      stub_request(:get, 'https://eu.api.ovh.com/1.0/me').to_return do |req|
        timestamps << req.headers['X-Ovh-Timestamp']
        { status: timestamps.length == 1 ? 429 : 200, body: '{}' }
      end

      build(retries: 1).api.connection.call(:GET, '/me')

      expect(timestamps.length).to eq(2)                # two attempts reached the server
      expect(timestamps.uniq.length).to eq(2)           # each freshly signed
    end
  end
```

- [ ] **Step 2: Run to verify**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: PASS. If `re-signs each retry attempt` fails with only one timestamp, the retry middleware is not wrapping signing — verify in Task 5 that `config.use(Faraday::Retry::Middleware, ...)` is registered BEFORE `config.use(Signature, ...)`.

- [ ] **Step 3: Run the full suite and lint**

Run: `bin/rspec` — Expected: all green.
Run: `bin/rubocop` — Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add spec/ovh_client/client_spec.rb
git commit -m "Add integration specs: signed round-trip and per-attempt re-signing"
```

---

### Task 9: `Ovh::Client.log_filters` helper, LICENSE, and README

**Files:**
- Modify: `lib/ovh-client/client.rb`
- Create: `LICENSE`, `README.md`
- Test: `spec/ovh_client/client_spec.rb` (append)

**Interfaces:**
- Produces: `Ovh::Client.log_filters → Array<[Regexp, String]>` — regex/replacement pairs that scrub the three `X-Ovh-*` credential headers from a Faraday logger's output, for callers who wire their own logger downstream of signing.

- [ ] **Step 1: Write the failing test (append to client_spec.rb)**

```ruby
  describe '.log_filters' do
    it 'scrubs each sensitive OVH header' do
      filters = described_class.log_filters
      %w[X-Ovh-Application X-Ovh-Consumer X-Ovh-Signature].each do |header|
        line = "#{header}: super-secret-value"
        scrubbed = filters.reduce(line) { |acc, (regex, replacement)| acc.gsub(regex, replacement) }
        expect(scrubbed).to eq("#{header}: [REDACTED]")
      end
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: FAIL — `undefined method 'log_filters'`.

- [ ] **Step 3: Implement the helper**

In `lib/ovh-client/client.rb`, add near `RETRY_METHODS`:

```ruby
    REDACTED = '[REDACTED]'
    # Credential headers to scrub from any downstream logger. ovh-api's built-in
    # logger runs before signing so it never sees these; these filters are for a
    # caller-supplied logger placed after the signature middleware.
    SENSITIVE_HEADERS = %w[X-Ovh-Application X-Ovh-Consumer X-Ovh-Signature].freeze
```

And add a class method (near `request_consumer_key`):

```ruby
    # Regex/replacement pairs that scrub the OVH credential headers from a Faraday
    # logger's output. Use when wiring your own logger downstream of signing.
    # @return [Array<(Regexp, String)>]
    def self.log_filters
      SENSITIVE_HEADERS.map do |header|
        [/(#{Regexp.escape(header)}:\s*)[^\r\n]+/i, "\\1#{REDACTED}"]
      end
    end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rspec spec/ovh_client/client_spec.rb`
Expected: all green.

- [ ] **Step 5: Write LICENSE and README**

Create `LICENSE` (MIT, copyright holder `Nicolas Rodriguez`, year 2026).

Create `README.md` covering: what ovh-client is (signing wrapper over ovh-api); installation; quick start (`Ovh::Client.new(...)` then `ovh.api.me.get_me` — note the exact generated method name comes from ovh-api and may vary, so also show `ovh.api.connection.call(:GET, '/me')`); configuration table (`endpoint`, `api_version`, `time_delta`, `auto_sync_time`, `retries`, plus forwarded ovh-api options); clock skew (`synchronize_time!` / `auto_sync_time`); consumer-key bootstrap (`Ovh::Client.request_consumer_key`); retries (idempotent verbs, per-attempt re-signing); logging & redaction (note ovh-api's logger runs before signing; show `Ovh::Client.log_filters` for a downstream logger); error handling (errors surface as `Ovh::Api::ApiError` — ovh-client does not re-wrap); development commands (`bin/rspec`, `bin/rubocop`, `bin/guard`).

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rspec` — Expected: all green.
Run: `bin/rubocop` — Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/ovh-client/client.rb spec/ovh_client/client_spec.rb LICENSE README.md
git commit -m "Add log_filters helper, LICENSE and README"
```

---

## Self-Review

**Spec coverage** (design §→task):
- §Namespace/layout → Task 1 (Zeitwerk explicit namespace, VERSION in client.rb).
- §Clock → Task 2.
- §Signature (full signing, byte-for-byte URL, SHA1/$1$) → Task 3; §three path branches → Task 4.
- §Ovh::Client factory (ENDPOINTS, base_url, `#api`, retry-before-signature) → Task 5.
- §Clock-skew (`synchronize_time!`, lazy `auto_sync_time`) → Task 6.
- §Bootstrap (`request_consumer_key`), `current_credential` → Task 7.
- §Data flow / per-attempt re-signing / `env.url` query-coverage risk → Task 3 (query test) + Task 8 (re-signing).
- §Errors (no re-wrap; ovh-api's ApiError) → documented in Task 9 README; no code needed.
- §Log redaction (`log_filters`, documented, not forced) → Task 9.
- §Retries (faraday-retry, idempotent, ordering) → Task 5 wiring + Task 8 verification.

**Placeholder scan:** none — every step carries concrete code/commands, except the README prose (Task 9 Step 5) and LICENSE, which are content descriptions, not code placeholders.

**Type/name consistency:** `Clock#synchronize!`, `#ensure_synced`, `#now`, `#synced?`, `#delta` consistent across Tasks 2/5/6. `Signature#initialize(app, options)` (positional Hash) consistent with `config.use(Signature, application_key:, ...)` in Task 5 (kwargs → Hash). `#api`, `#api.connection.call`, `#api.configuration.base_url` used consistently. `ENDPOINTS`, `RETRY_STATUSES`, `RETRY_METHODS`, `SENSITIVE_HEADERS`, `REDACTED` all defined in `client.rb`.
