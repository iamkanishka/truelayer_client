# TruelayerClient

[![Hex.pm](https://img.shields.io/hexpm/v/truelayer_client.svg)](https://hex.pm/packages/truelayer_client)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/truelayer_client)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Production-grade Elixir client for the [TrueLayer](https://truelayer.com) open banking platform.

Zero external crypto dependencies — ES512 request signing and HMAC-SHA256 webhook verification
use Erlang's built-in `:crypto` and `:public_key` OTP modules.

---

## Installation

```elixir
def deps do
  [{:truelayer_client, "~> 1.0"}]
end
```

---

## Quick Start

```elixir
{:ok, client} = TruelayerClient.new(
  environment:              :sandbox,
  client_id:                System.fetch_env!("TRUELAYER_CLIENT_ID"),
  client_secret:            System.fetch_env!("TRUELAYER_CLIENT_SECRET"),
  redirect_uri:             "https://yourapp.com/callback",
  signing_key_pem:          File.read!("keys/signing_private.pem"),
  signing_key_id:           System.fetch_env!("TRUELAYER_KEY_ID"),
  webhook_signing_secret:   System.fetch_env!("TRUELAYER_WEBHOOK_SECRET")
)
```

---

## API Coverage

| Module | Endpoints |
|--------|-----------|
| `TruelayerClient.Auth` | Auth link, exchange code, client credentials, refresh, delete credential |
| `TruelayerClient.Payments` | Create/get/cancel; full auth flow; refunds; payment links; provider search; polling |
| `TruelayerClient.Payouts` | Create payout, get payout |
| `TruelayerClient.Merchant` | List/get accounts, transactions, sweeping, payment sources |
| `TruelayerClient.Mandates` | Create, list, get; auth flow; revoke; confirm funds; constraints |
| `TruelayerClient.Data` | Accounts, balances, transactions (lazy `Stream`), cards, providers, auth links |
| `TruelayerClient.Verification` | Account holder name verification; AHV resource |
| `TruelayerClient.SignupPlus` | User data by payment/mandate/connected account; auth URI |
| `TruelayerClient.Tracking` | Auth-flow event tracking |
| `TruelayerClient.Webhooks` | HMAC-SHA256 verification, replay protection, typed dispatch |

---

## Authentication

```elixir
# Generate bank login URL
{:ok, url} = TruelayerClient.Auth.auth_link(client,
  scopes: TruelayerClient.Auth.payments_scopes(),
  state:  csrf_token   # validate on redirect!
)

# Exchange code for token in your callback handler
{:ok, token} = TruelayerClient.Auth.exchange_code(client, code, :payments)

# Server-to-server (auto-cached and refreshed)
{:ok, token} = TruelayerClient.Auth.client_credentials(
  client, TruelayerClient.Auth.payments_scopes(), :payments
)
```

### Custom token store (Redis, DynamoDB…)

```elixir
defmodule MyApp.RedisTokenStore do
  @behaviour TruelayerClient.Auth.TokenStore

  @impl true
  def get(store_id, token_type) do
    case Redix.command(:redix, ["GET", key(store_id, token_type)]) do
      {:ok, nil}    -> {:ok, nil}
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _}   -> {:ok, nil}
    end
  end

  @impl true
  def put(store_id, token_type, token) do
    ttl = max(DateTime.diff(token.expires_at, DateTime.utc_now()), 1)
    Redix.command!(:redix, ["SETEX", key(store_id, token_type), ttl,
                             :erlang.term_to_binary(token)])
    :ok
  end

  @impl true
  def delete(store_id, token_type) do
    Redix.command(:redix, ["DEL", key(store_id, token_type)])
    :ok
  end

  defp key(id, type), do: "truelayer:token:#{id}:#{type}"
end

{:ok, client} = TruelayerClient.new(
  client_id: "...", client_secret: "...",
  token_store: MyApp.RedisTokenStore
)
```

---

## Payments

```elixir
# Create a payment
{:ok, payment} = TruelayerClient.Payments.create_payment(client, %{
  amount_in_minor: 1000,
  currency: "GBP",
  payment_method: %{
    type: "bank_transfer",
    provider_selection: %{type: "user_selected"},
    beneficiary: %{
      type: "merchant_account",
      merchant_account_id: ma_id,
      reference: "Order #12345"
    }
  },
  user: %{name: "Jane Doe", email: "jane@example.com"}
}, operation_id: "order-12345")  # stable ID = safe retries

# Authorization flow
{:ok, flow} = TruelayerClient.Payments.start_authorization_flow(client, payment["id"], %{
  redirect: %{return_uri: "https://yourapp.com/callback"}
})

{:ok, _} = TruelayerClient.Payments.submit_provider_selection(client, payment["id"], "ob-monzo")
{:ok, _} = TruelayerClient.Payments.submit_consent(client, payment["id"])

# Poll for final status (prefer webhooks in production)
{:ok, final} = TruelayerClient.Payments.wait_for_final_status(client, payment["id"],
  timeout_ms: 60_000, interval_ms: 2_000
)
```

---

## Data API

```elixir
# List accounts
{:ok, accounts} = TruelayerClient.Data.list_accounts(client)

# Get balance
{:ok, balance} = TruelayerClient.Data.get_account_balance(client, account_id)

# Lazy transaction stream — compose with Stream functions
client
|> TruelayerClient.Data.transaction_stream(account_id,
     from: ~U[2024-01-01 00:00:00Z], to: ~U[2024-03-31 23:59:59Z])
|> Stream.filter(&(&1["transaction_type"] == "CREDIT"))
|> Stream.map(& &1["amount"])
|> Enum.sum()
```

---

## Webhooks

```elixir
# Register typed handlers
TruelayerClient.Webhooks.on(client, TruelayerClient.Webhooks.payment_executed(), fn event ->
  id = get_in(event, ["payload", "payment_id"])
  MyApp.Payments.handle_executed(id)
  :ok
end)

TruelayerClient.Webhooks.on(client, TruelayerClient.Webhooks.payment_failed(), fn event ->
  %{"payload" => %{"payment_id" => id, "failure_reason" => reason}} = event
  MyApp.Payments.handle_failed(id, reason)
  :ok
end)

TruelayerClient.Webhooks.on_fallback(client, fn event ->
  Logger.warning("Unhandled webhook: #{event["event_type"]}")
  :ok
end)

# In your Phoenix controller (raw body required — configure CacheBodyReader plug)
def webhook(conn, _params) do
  raw   = conn.assigns[:raw_body]
  sig   = get_req_header(conn, "tl-signature") |> List.first()
  ts    = get_req_header(conn, "tl-timestamp")  |> List.first()

  case TruelayerClient.Webhooks.process(client, raw, sig, ts) do
    :ok                -> send_resp(conn, 200, "")
    {:error, :bad_sig} -> send_resp(conn, 401, "invalid signature")
    {:error, :replay}  -> send_resp(conn, 401, "event too old")
    {:error, reason}   -> send_resp(conn, 500, inspect(reason))
  end
end
```

---

## Error Handling

```elixir
case TruelayerClient.Payments.get_payment(client, payment_id) do
  {:ok, payment} ->
    payment

  {:error, %TruelayerClient.Error{type: :not_found}} ->
    nil

  {:error, %TruelayerClient.Error{type: :rate_limited}} ->
    # SDK already retried max_retries times
    :rate_limited

  {:error, %TruelayerClient.Error{trace_id: trace_id} = err} ->
    Logger.error("TrueLayer error trace=#{trace_id}: #{Exception.message(err)}")
    {:error, err}
end
```

---

## Telemetry

Attach to telemetry events for metrics and tracing:

```elixir
:telemetry.attach("my-app.truelayer", [:truelayer_client, :request, :stop],
  fn _name, %{duration: duration}, %{method: method, url: url, status: status}, _cfg ->
    MyApp.Metrics.histogram("truelayer.request.ms",
      System.convert_time_unit(duration, :native, :millisecond),
      tags: ["method:#{method}", "status:#{status}"]
    )
  end, nil
)
```

Events emitted: `[:truelayer_client, :request, :start | :stop | :exception]`

Customise the prefix with `:telemetry_prefix` in `TruelayerClient.new/1`.

---

## Configuration Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:client_id` | `String.t()` | **required** | OAuth2 client ID |
| `:client_secret` | `String.t()` | **required** | OAuth2 client secret |
| `:environment` | `:sandbox \| :live` | `:sandbox` | API environment |
| `:redirect_uri` | `String.t()` | `nil` | Required for auth-code flows |
| `:signing_key_pem` | `binary()` | `nil` | PEM EC key — required for Payments/Payouts/Mandates |
| `:signing_key_id` | `String.t()` | `nil` | Key ID from TrueLayer Console |
| `:webhook_signing_secret` | `binary()` | `nil` | HMAC-SHA256 webhook secret |
| `:webhook_replay_tolerance_sec` | `integer()` | `300` | Max accepted webhook age |
| `:request_timeout_ms` | `integer()` | `30_000` | HTTP request timeout |
| `:max_retries` | `integer()` | `3` | Retry attempts |
| `:base_retry_delay_ms` | `integer()` | `300` | Base backoff delay |
| `:token_store` | `module()` | `MemoryStore` | `TokenStore` behaviour impl |
| `:telemetry_prefix` | `[atom()]` | `[:truelayer_client]` | Telemetry prefix |

---

## License

MIT — see [LICENSE](LICENSE).
