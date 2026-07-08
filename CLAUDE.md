# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Role

You are an expert Ruby developer: meticulous, precise, and exhaustive. Favor idiomatic, well-tested code, handle edge cases, and never cut corners.

You always work in TDD: write a failing test first, watch it fail, then write the minimal code to make it pass, then refactor. No production code without a failing test first.

## Overview

`ovh-client` is a hand-written signing wrapper over [`ovh-api`](https://github.com/jbox-web/ovh-api), the generated Faraday transport gem for the OVH REST API. `ovh-api` deliberately ships no authentication; `ovh-client` supplies OVH request signing (as a Faraday middleware), clock-skew handling, the consumer-key bootstrap flow, and retries with per-attempt re-signing.

The public surface is `Ovh::Client` (`lib/ovh-client/client.rb`), plus `Ovh::Client::Signature` (the middleware) and `Ovh::Client::Clock`.

## The ovh-api dependency

`ovh-api` here is **jbox-web's** gem (namespace `Ovh::Api`, Faraday-based), NOT the unrelated RubyGems gem of the same name (`OVHApi`, Net::HTTP). The name is already taken on RubyGems, so jbox's gem is never published there — it is sourced from GitHub in the `Gemfile` (`gem 'ovh-api', git: 'https://github.com/jbox-web/ovh-api.git'`). A bare `gem install ovh-client` would resolve the wrong dependency; both gems are git-installed.

## Commands

```bash
bin/rspec                                # run the full test suite
bin/rspec spec/ovh_client/clock_spec.rb  # run one file
bin/rubocop                              # lint (must pass in CI)
bin/rubocop -a                           # auto-correct safe offenses
bin/guard                                # auto-run specs on file change
bin/console                              # IRB with the gem loaded
```

The `mise.toml` tasks wrap the same binstubs: `mise run dev:spec`, `mise run lint`, `mise run guard`, `mise run dev:docs` (YARD). `required_ruby_version` is `>= 3.2.0`.

## Architecture

- **Autoloading via Zeitwerk** (`lib/ovh-client.rb`). The bootstrap defines `module Ovh` and pushes `lib/ovh-client` with `namespace: Ovh`; `Ovh::Client` (in `client.rb`) is an explicit namespace whose children (`Signature`, `Clock`) autoload from `client/`. `Ovh::VERSION` lives in `lib/ovh-client/version.rb` on the top-level `Ovh` namespace (not under `Ovh::Client`, so it never interferes with Zeitwerk's autoload of `Ovh::Client`); the file is `loader.ignore`d (it must not map to an `Ovh::Version` constant) and required directly — by the bootstrap and by the gemspec (`require_relative`, no Faraday load). Add new classes under `lib/ovh-client/client/` and they autoload by convention.
- **Signing is a Faraday middleware** (`Ovh::Client::Signature`), wired onto `ovh-api`'s `Configuration#use` seam. `Configuration#use` passes its options as a single positional Hash (Ruby 3 does not convert a positional Hash to keywords), so `Signature#initialize(app, options)` takes a positional Hash, not keyword params.
- **Middleware order is load-bearing**: the factory registers `Faraday::Retry::Middleware` BEFORE `Signature`, so retry wraps signing and each retry attempt re-signs with a fresh timestamp. To change request behavior, edit the `config.use` block in `Ovh::Client#initialize`.
- **OVH signature** (`Signature#signature`): `$1$` + SHA1 of `application_secret + consumer_key + METHOD + full_url + body + timestamp`. It signs `env.url` (the final URL Faraday sends, query included) and `env.body` (serialized by `:json`, which runs before this middleware), so the signed URL matches the sent URL byte-for-byte — no manual path normalization. SHA1 and the `$1$` prefix are OVH-mandated; do not "upgrade" them.
- **Public endpoints are skipped by path AND method** (`Signature#on_request`): `POST /auth/credential` (consumer-key bootstrap) sends only `X-Ovh-Application`; `/auth/time` (clock sync) is unsigned and must never trigger lazy sync (that would recurse through this middleware); every other path — including a signed `GET /auth/credential` (list credential IDs) — is fully signed. The regexes are anchored to the version-prefixed path (`\A/[^/]+/auth/...`).
- **Clock skew** (`Ovh::Client::Clock`): holds the offset between OVH's clock and the local one and supplies the signature timestamp. `synchronize_time!` measures it via an unsigned `GET /auth/time`; `auto_sync_time` syncs lazily before the first signed request. All state (`@delta`/`@synced`) is guarded by a reentrant `Monitor`, not a `Mutex`: `ensure_synced` holds the lock while the syncer calls `synchronize!`, which re-acquires it — a plain Mutex would deadlock on that re-entry. Locking every read also gives cross-thread visibility on runtimes without a global VM lock (JRuby, TruffleRuby).
- **Consumer-key bootstrap** (`Ovh::Client.request_consumer_key`): a class method (runs before a consumer key exists). It builds an internal wrapper with nil secret/consumer key and POSTs `/auth/credential`; the middleware's credential branch keeps that request unsigned (application header only).
- **The generated surface is reached only through `#api`** (`ovh.api.me.get_me`, or the stable `ovh.api.connection.call(:GET, '/me')`). The wrapper never enumerates ovh-api resource names, so ovh-api's automatic regeneration can never desync it.
- **Errors** surface as `ovh-api`'s `Ovh::Api::ApiError`; `ovh-client` does not define or re-wrap errors.
- **Log redaction**: `Ovh::Client.log_filters` returns regex/replacement pairs scrubbing the `X-Ovh-*` credential headers, for a caller-supplied logger placed downstream of signing (ovh-api's built-in logger runs before signing, so credentials never reach it). `application_secret` is never transmitted — it only feeds the SHA1.

## Testing

`Ovh::Client::Signature` and `Ovh::Client::Clock` are unit-tested on hand-built Faraday stacks with the test adapter (`Faraday::Adapter::Test::Stubs`) — no `ovh-api` involved, which keeps signing and clock logic isolated. `ovh-api` exposes no adapter-injection seam, so the factory and end-to-end behavior (signed round-trip, per-attempt re-signing, clock sync, bootstrap) are tested through the **real** `ovh-api` stack with [WebMock](https://github.com/bblimke/webmock) stubbing HTTP. Deterministic signatures inject a fixed-value `Clock`; the re-signing test uses an incrementing block-form `Time.now` stub so successive attempts differ. RSpec runs with random order and zero-monkey-patching.
