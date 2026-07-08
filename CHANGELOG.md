# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project skeleton: gemspec, Zeitwerk bootstrap, `Ovh::Client` factory over the
  `ovh-api` transport (env/datacenter-driven `base_url`, `#api` accessor), RSpec
  suite, RuboCop, CI.
- `Ovh::Client::Signature`: OVH request signing as a Faraday middleware —
  `$1$` + SHA1 of `application_secret + consumer_key + METHOD + url + body + timestamp`,
  signing the final URL and serialized body byte-for-byte.
- Public-endpoint skipping by path **and** method (`Signature#on_request`):
  `POST /auth/credential` (consumer-key bootstrap) sends only `X-Ovh-Application`;
  `/auth/time` stays unsigned and never triggers lazy sync; every other path is
  fully signed. Regexes anchored to the version-prefixed path.
- Middleware order wires `Faraday::Retry::Middleware` before `Signature`, so each
  retry attempt re-signs with a fresh timestamp.
- `Ovh::Client::Clock`: clock-skew handling. `synchronize_time!` measures the offset
  via an unsigned `GET /auth/time`; `auto_sync_time` syncs lazily before the first
  signed request. State guarded by a reentrant `Monitor` for cross-thread visibility.
- `Ovh::Client.request_consumer_key`: the consumer-key bootstrap flow (class method,
  runs before a consumer key exists), plus `current_credential`.
- `Ovh::Client.log_filters`: regex/replacement pairs scrubbing the `X-Ovh-*`
  credential headers from a caller-supplied logger placed downstream of signing.
- Errors surface as `ovh-api`'s `Ovh::Api::ApiError`; the wrapper defines no errors
  of its own.
