# ovh-client

[![CI](https://github.com/jbox-web/ovh-client/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/ovh-client/actions/workflows/ci.yml)
[![docs](https://github.com/jbox-web/ovh-client/actions/workflows/docs.yml/badge.svg)](https://jbox-web.github.io/ovh-client/)
[![License](https://img.shields.io/github/license/jbox-web/ovh-client)](LICENSE)

A signing wrapper over [`ovh-api`](https://github.com/jbox-web/ovh-api) — the
generated Faraday transport gem for the entire OVH REST API. `ovh-api` is a thin,
machine-generated HTTP layer and deliberately does **not** bake in OVH's
request-signing authentication. `ovh-client` supplies exactly what it leaves out:

- **Request signing** as a Faraday middleware, wired onto `ovh-api`'s middleware seam.
- **Clock-skew handling** — OVH rejects signatures whose timestamp drifts from its clock.
- **Consumer-key bootstrap** — the unsigned `/auth/credential` flow.
- **Retries** with per-attempt re-signing (each retry gets a fresh signature).

## Requirements

- Ruby >= 3.2

## Installation

`ovh-client` depends on jbox-web's `ovh-api` gem. That gem is **not** published on
RubyGems (the RubyGems gem of the same name is an unrelated project), so both are
sourced from GitHub. In your `Gemfile`:

```ruby
gem 'ovh-api',    git: 'https://github.com/jbox-web/ovh-api.git'
gem 'ovh-client', git: 'https://github.com/jbox-web/ovh-client.git'
```

then `bundle install`.

You need an `application_key`, an `application_secret` and a `consumer_key`. Create
an application at the OVH API console for your region
([EU](https://eu.api.ovh.com/createApp/), [CA](https://ca.api.ovh.com/createApp/),
[US](https://api.us.ovhcloud.com/createApp/)); see
[Consumer key bootstrap](#consumer-key-bootstrap) to mint the consumer key.

## Quick start

```ruby
require 'ovh-client'

ovh = Ovh::Client.new(
  application_key:    '<application_key>',
  application_secret: '<application_secret>',
  consumer_key:       '<consumer_key>',
  endpoint:           :eu,
)

# The generated ovh-api surface is reached through #api:
ovh.api.me.get_me
# => the parsed response

# The exact generated method names come from ovh-api and may change as it is
# regenerated. For a stable, name-independent call, use the connection directly:
ovh.api.connection.call(:GET, '/me').data
```

Every signed request automatically carries the OVH auth headers
(`X-Ovh-Application`, `X-Ovh-Consumer`, `X-Ovh-Timestamp`, `X-Ovh-Signature`).

## Configuration

```ruby
ovh = Ovh::Client.new(
  application_key:    '<application_key>',
  application_secret: '<application_secret>',
  consumer_key:       '<consumer_key>',
  endpoint:           :eu,     # :eu | :ca | :us, or a full base URL string
  api_version:        '1.0',
  time_delta:         0,
  auto_sync_time:     false,
  retries:            0,
)
```

| Option               | Default | Description                                                              |
| -------------------- | ------- | ------------------------------------------------------------------------ |
| `application_key`    | —       | OVH application key.                                                      |
| `application_secret` | —       | OVH application secret (feeds the signature; never transmitted).         |
| `consumer_key`       | —       | OVH consumer key (may be `nil` when only bootstrapping).                  |
| `endpoint`           | `:eu`   | `:eu`, `:ca`, `:us`, or a full base URL string.                          |
| `api_version`        | `'1.0'` | OVH API version (path prefix).                                           |
| `time_delta`         | `0`     | Initial signing clock offset, in seconds (see [Clock skew](#clock-skew)). |
| `auto_sync_time`     | `false` | Sync the clock against OVH before the first signed request.             |
| `retries`            | `0`     | Retry idempotent requests on `429`/`5xx` this many times (see [Retries](#retries)). |

Any other keyword (e.g. `logger:`, `timeout:`) is forwarded to `Ovh::Api::Client`.
The underlying generated client is available as `ovh.api`.

## Clock skew

OVH rejects requests whose signature timestamp drifts too far from its own clock.
On a host with an unreliable clock, sync once against OVH's time endpoint; the
offset is reused for every subsequent signed request:

```ruby
ovh.synchronize_time!   # unsigned GET /auth/time, returns the measured offset
```

Or let the client sync lazily before the first signed request with
`auto_sync_time: true`.

## Consumer-key bootstrap

If you don't have a consumer key yet, start the OVH credential flow. This call is
unsigned and needs only the application key; the response carries a `consumerKey`
and a `validationUrl` the end user must visit to activate it:

```ruby
Ovh::Client.request_consumer_key(
  application_key: '<application_key>',
  endpoint:        :eu,
  access_rules:    [{ 'method' => 'GET', 'path' => '/*' }],
  redirection:     'https://example.com/callback', # optional
)
# => { "consumerKey" => "...", "validationUrl" => "https://...", "state" => "pendingValidation" }
```

Inspect the credential currently in use (scope, status, expiration) with:

```ruby
ovh.current_credential
```

## Retries

When `retries` is greater than zero, **idempotent** requests (`GET`, `HEAD`,
`DELETE`, `PUT` — never `POST`/`PATCH`) are retried on rate limiting (`429`) and
transient server errors (`500`, `502`, `503`, `504`) with exponential backoff. The
retry middleware wraps signing, so **each attempt is re-signed with a fresh
timestamp** (a replayed signature would be rejected by OVH):

```ruby
ovh = Ovh::Client.new(
  application_key: '...', application_secret: '...', consumer_key: '...', retries: 3,
)
```

## Logging and redaction

`ovh-api`'s built-in logger runs **before** the signing middleware, so the OVH
credential headers never reach it — no redaction is needed there. The
`application_secret` is never transmitted; it only feeds the SHA1 signature.

If you wire **your own** logger downstream of signing, scrub the credential
headers with the provided filters:

```ruby
Ovh::Client.log_filters
# => [[/(X-Ovh-Application:\s*)[^\r\n]+/i, '\1[REDACTED]'], ...]
```

## Error handling

`ovh-client` does not define its own error hierarchy. Non-2xx responses surface as
`Ovh::Api::ApiError`, raised by `ovh-api`; transport failures surface as
`ovh-api`'s errors as well. Rescue those directly — `ovh-client` never re-wraps them.

## Development

After checking out the repo, install dependencies with `bundle install` (or
`mise run dev:deps`), then use the binstubs directly:

```bash
bin/rspec      # run the test suite
bin/rubocop    # lint
bin/guard      # auto-run specs on file change
bin/console    # IRB session with the gem loaded
```

The [mise](https://mise.jdx.dev/) tasks in `mise.toml` wrap the same binstubs:

```bash
mise run dev:spec   # bin/rspec (documentation format on a TTY)
mise run lint       # bin/rubocop
mise run guard      # bin/guard
mise run dev:docs   # generate YARD docs into ./doc
```

## License

Released under the [MIT License](LICENSE).
