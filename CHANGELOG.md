# Changelog

## [1.0.0] - 2026-04-09

### Added

- `TruelayerClient.new/1` and `TruelayerClient.new!/1` — client construction with full validation
- `TruelayerClient.Config` — typed, validated configuration struct
- `TruelayerClient.Error` — `defexception` with predicates (`retryable?/1`, `not_found?/1`, etc.)
- `TruelayerClient.HTTP` — `Req`-based client with TLS 1.2+, RFC 7807 parsing, telemetry
- `TruelayerClient.Signing` — ES512 JWS via Erlang `:crypto`/`:public_key` (zero external deps)
- `TruelayerClient.Retry` — exponential backoff with `:crypto.strong_rand_bytes/1` jitter
- `TruelayerClient.Idempotency` — ETS-backed stable key manager for safe POST retries
- `TruelayerClient.Auth` — auth links, code exchange, client credentials, refresh, valid_token
- `TruelayerClient.Auth.Token` — token struct with `expired?/1` and `bearer_header/1`
- `TruelayerClient.Auth.TokenStore` — `@behaviour` for pluggable Redis/DynamoDB backends
- `TruelayerClient.Auth.MemoryStore` — GenServer + ETS default token store
- `TruelayerClient.Payments` — full Payments API v3: create/get/cancel, auth flow (5 steps),
  refunds, payment links, provider search, return parameters, `wait_for_final_status/3`
- `TruelayerClient.Payouts` — `create_payout/3`, `get_payout/2`
- `TruelayerClient.Merchant` — list/get accounts, get transactions, setup/disable/get sweeping,
  get payment sources
- `TruelayerClient.Mandates` — create, list, get mandate; start auth flow; submit
  provider/consent; revoke; confirm funds; get constraints
- `TruelayerClient.Data` — full Data API v1: connection meta, user info, accounts, balances,
  transactions (lazy `Stream.t()`), pending, standing orders, direct debits, cards, providers,
  auth links, extend connection
- `TruelayerClient.Verification` — verify account holder name; create/get AHV resource
- `TruelayerClient.SignupPlus` — get user data by payment/mandate/connected account; generate auth URI
- `TruelayerClient.Tracking` — `get_tracked_events/2`
- `TruelayerClient.Webhooks` — 19 typed event constants, HMAC-SHA256 constant-time verification,
  replay-attack protection, `on/3`, `on_fallback/2`, `process/4`
- `TruelayerClient.Application` — OTP supervisor starting `MemoryStore`
- Full test suite using `Bypass` (zero live API calls)
