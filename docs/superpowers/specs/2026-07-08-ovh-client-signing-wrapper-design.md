# ovh-client — signing wrapper over ovh-api

**Date:** 2026-07-08
**Status:** Design approved, pending implementation plan

## Purpose

`ovh-api` is a machine-generated transport gem covering the entire OVH REST API.
By design it does **not** bake in OVH's request-signing authentication — it exposes
a middleware seam (`Configuration#use`) and leaves signing, clock-skew handling,
consumer-key bootstrap, and retries to a hand-written wrapper on top.

`ovh-client` is that wrapper. It supplies exactly what `ovh-api` leaves empty:

- **Request signing** as a Faraday middleware, wired onto `ovh-api` through its seam.
- **Clock-skew handling** (OVH rejects signatures whose timestamp drifts from its clock).
- **Consumer-key bootstrap** (the unsigned `/auth/credential` flow).
- **Retries** with per-attempt re-signing.

It replaces the naive inline middleware shown in the `ovh-api` README (which uses raw
`Time.now`, no clock-skew, no public-endpoint handling) with hardened, tested code
ported from the retired `ovh-rest` gem.

Out of scope for this project (handled separately, later): deprecating and archiving
`ovh-rest`.

## Context: the ovh-api seam

`ovh-api` exposes two injection points; understanding why signing lives in the middleware
(not `apply_auth`) is central to this design.

- `Configuration#apply_auth(headers, query, auth_names)` — called by `Connection#call`,
  it **knows** which security schemes an operation declares (`auth_names` empty for
  `security: []` public endpoints). Conceptually the right place — **but** it runs
  *before* body serialization and never receives the body, and the OVH signature
  includes the body. Unusable for signing.
- `Configuration#use(middleware, *args, &block)` — registers a Faraday middleware that
  runs *after* the built-in request middleware (so it sees the serialized body and the
  final URL) and *just before* the adapter. This is where signing goes. Its only gap:
  it runs on **every** request without knowing which are public. The middleware
  therefore discriminates by `env.url.path` (see §Signature).

Relevant `ovh-api` facts:

- `Ovh::Api::Client.new(base_url:, **options, &block)` → `Configuration` → `Connection`.
- `Configuration#configure_faraday` registers, in order: `:multipart`, `:url_encoded`,
  `:json` (request), `:json` (response), `:logger` (only when `logger && debugging`),
  then each `@middlewares` entry via `conn.use`, then the adapter.
- The default `base_url` is `https://api.ovh.com/1.0`.
- Non-2xx responses already raise `Ovh::Api::ApiError` (`ApiError.from(response)`).

## Namespace and layout

Gem `ovh-client`, namespace `Ovh::Client` (sibling of `Ovh::Api`). Hand-written, no
code generation. Ruby `>= 3.2`. Runtime dependencies: `ovh-api`, `faraday`,
`faraday-retry`, `zeitwerk`.

```
lib/ovh-client.rb                   # bootstrap: module Ovh; Zeitwerk push_dir(namespace: Ovh); require version
lib/ovh-client/client.rb            # Ovh::Client — wrapper + factory + class-method bootstrap; ENDPOINTS
lib/ovh-client/client/signature.rb  # Ovh::Client::Signature < Faraday::Middleware
lib/ovh-client/client/clock.rb      # Ovh::Client::Clock — mutable time_delta, one-shot lazy sync
lib/ovh-client/client/version.rb    # Ovh::Client::VERSION (ignored by loader, required directly)
```

With `namespace: Ovh`, Zeitwerk maps `client.rb → Ovh::Client`,
`client/signature.rb → Ovh::Client::Signature`, `client/clock.rb → Ovh::Client::Clock`.
`version.rb` defines a constant (not a class), so it is `ignore`d by the loader and
`require`d directly (same pattern as `ovh-api`). This mirrors `ovh-api`'s explicit
`Zeitwerk::Loader` setup.

Tooling baseline follows `ovh-rest`: `bin/rspec`, `bin/rubocop`, `bin/guard`, RSpec with
Faraday test stubs, RuboCop.

## Components

Each component is an isolated unit with one purpose, testable on its own.

### Ovh::Client::Clock

Holds the offset between the OVH server clock and the local clock.

- `#now` → `Time.now.to_i + delta` (integer epoch used for the signature timestamp).
- `#delta`, `#delta=`, `#synced?`.
- `#ensure_synced` — runs an injected *syncer* callable **exactly once**, using a
  double-checked lock under a `Mutex` (ported from `ovh-rest#sync_time_once`) so
  concurrent first requests sync only once. The Clock itself performs no network I/O;
  the syncer is supplied by the wrapper.

### Ovh::Client::Signature (Faraday middleware)

In `on_request(env)`, decides by `env.url.path`:

| Path suffix        | Headers added                                                                 |
| ------------------ | ----------------------------------------------------------------------------- |
| `…/auth/time`      | none (public; this is the endpoint used to synchronize the clock)             |
| `…/auth/credential`| `X-Ovh-Application` only (bootstrap: no consumer key, no signature)           |
| everything else    | full signing (see below)                                                      |

Full signing adds:

- `X-Ovh-Application` = application key
- `X-Ovh-Consumer` = consumer key
- `X-Ovh-Timestamp` = `clock.now.to_s`
- `X-Ovh-Signature` = `"$1$" + SHA1(app_secret + "+" + consumer_key + "+" + METHOD + "+" + env.url + "+" + env.body + "+" + timestamp)`

Notes:

- `clock.ensure_synced` is invoked **only on the full-signing branch**, so it never
  fires on the public paths → the syncer's own `GET /auth/time` cannot recurse.
- The signature covers `env.url.to_s` — the URL Faraday actually sends, query string
  included — so it matches byte-for-byte with no manual path normalization (unlike
  `ovh-rest`, which reconstructed the URL by hand).
- SHA1 and the `$1$` prefix are mandated by the OVH protocol; they are not a security
  choice and must not be "upgraded".

### Ovh::Client (wrapper + factory)

- `ENDPOINTS = { eu: "https://eu.api.ovh.com", ca: "https://ca.api.ovh.com", us: "https://api.us.ovhcloud.com" }`,
  each combined with `/1.0` (the `api_version`) to form `base_url`.
- `.new(application_key:, application_secret:, consumer_key:, endpoint: :eu, api_version: "1.0", time_delta: 0, auto_sync_time: false, retries: 0, logger: nil, **opts)`
  builds an `Ovh::Api::Client` whose configuration registers, via the `use` seam,
  **`faraday-retry` first, then `Signature`** (registration order = request order =
  retry wraps signing). Holds the shared `Clock` (same reference the middleware uses).
- `#api` → the underlying `Ovh::Api::Client`. Single accessor to the generated surface:
  `ovh.api.me.get_me`. The wrapper never enumerates resource names, so `ovh-api`'s
  automatic regeneration can never desync it.
- `#synchronize_time!` — `GET /auth/time` via `#api` (left unsigned by the skip-list),
  sets `delta = server_epoch - Time.now.to_i` on the Clock, returns the delta.
- `#current_credential` — `GET /auth/currentCredential` via `#api`.
- `.request_consumer_key(application_key:, endpoint: :eu, access_rules:, redirection: nil)`
  — class method (runs *before* a consumer key exists). Needs only the application key: the
  call is unsigned, so `application_secret` is irrelevant here. Builds an internal client with
  `consumer_key: nil` and `application_secret: nil`, `POST /auth/credential` with the access
  rules; the middleware sends only `X-Ovh-Application`. Returns the parsed
  `{ consumerKey, validationUrl, state }`.

## Data flow: a signed request

```
ovh.api.me.get_me
  → Ovh::Api::Api::Me#... → Ovh::Api::Connection#call
      (serializes body, apply_auth is a no-op)
  → Faraday request chain:
      :json (serialize) → faraday-retry → Signature (ensure_synced; add X-Ovh-*) → adapter
```

On `429/500/502/503/504`, `faraday-retry` replays **Signature + adapter** (it is inner to
retry), so each attempt gets a **fresh timestamp and signature**. `:json` is upstream of
retry and is not replayed: the body is serialized once and stays serialized.

## Clock-skew flow

- Explicit: `ovh.synchronize_time!` → unsigned `GET /auth/time` (skip-listed) → delta → Clock.
- Lazy (`auto_sync_time: true`): the Clock's `ensure_synced` runs the syncer (which calls
  `synchronize_time!`) once, triggered by the Signature middleware on the first full-signing
  request. Public paths never trigger it, so the syncer's `/auth/time` call does not recurse.

## Bootstrap flow

`Ovh::Client.request_consumer_key(...)` builds a `consumer_key: nil` wrapper and POSTs to
`/auth/credential`. The Signature middleware's path rule sends `X-Ovh-Application` only —
no consumer key, no signature — matching OVH's unsigned credential request.

## Errors

`ovh-client` does **not** define its own error hierarchy. `ovh-api` already raises
`Ovh::Api::ApiError` (via `ApiError.from(response)`) on every non-2xx response; the wrapper
lets it propagate. Re-wrapping would fight `ovh-api`. (This is a deliberate divergence from
`ovh-rest`, whose `ApiError`/`ClientError`/`ServerError` hierarchy would duplicate what
`ovh-api` already provides.)

## Log redaction

`ovh-api` registers its `:logger` **before** the `@middlewares` entries. On the request
descent the logger therefore runs **before** `Signature` adds the `X-Ovh-*` headers, so with
`ovh-api`'s built-in logger the credential headers never reach the log. Explicit redaction is
only needed if the caller wires **their own** logger downstream of signing.

Accordingly, `ovh-client` provides a documented helper `Ovh::Client.log_filters`
(regex/replacement pairs scrubbing `X-Ovh-Application` / `X-Ovh-Consumer` /
`X-Ovh-Signature`, ported from `ovh-rest`) for that case, rather than forcing redaction code
that is inert on the default path. Note: `application_secret` is never transmitted (it only
feeds the SHA1), so it cannot leak through headers.

## Testing (TDD, RSpec + Faraday stubs)

Unit, per component:

- **Clock**: delta arithmetic; `ensure_synced` invokes the syncer exactly once across
  repeated / concurrent calls.
- **Signature**: deterministic signature with a fixed-value `Clock` (inject a Clock whose
  `now` is constant); the three path branches (`/auth/time` → no headers,
  `/auth/credential` → `X-Ovh-Application` only, other → full signing); exact `$1$`+SHA1 value
  against a hand-computed fixture.
- **Factory**: `base_url` per region; retry registered before signature; `#api` returns the
  `Ovh::Api::Client`.

Integration (stubbed Faraday adapter): assert the outgoing headers on a real signed call;
assert **per-attempt re-signing** — two attempts with a Clock returning increasing values
produce two distinct `X-Ovh-Timestamp` / `X-Ovh-Signature` pairs.

## Implementation risk to verify (not a choice — a check)

`env.url` must already carry the query string at `on_request` time, or the signature would
not cover the query params. This is the case in Faraday, but the first iteration will assert
it with a test (a signed `GET` with query params, verifying the signed URL includes them).
