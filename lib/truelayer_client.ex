defmodule TruelayerClient do
  @moduledoc """
  Production-grade Elixir client for the [TrueLayer](https://truelayer.com) open banking API.

  ## Quick start

      {:ok, client} = TruelayerClient.new(
        environment:              :sandbox,
        client_id:                System.fetch_env!("TRUELAYER_CLIENT_ID"),
        client_secret:            System.fetch_env!("TRUELAYER_CLIENT_SECRET"),
        redirect_uri:             "https://yourapp.com/callback",
        signing_key_pem:          File.read!("keys/signing_private.pem"),
        signing_key_id:           System.fetch_env!("TRUELAYER_KEY_ID"),
        webhook_signing_secret:   System.fetch_env!("TRUELAYER_WEBHOOK_SECRET")
      )

  ## API modules

  | Module | Responsibility |
  |--------|----------------|
  | `TruelayerClient.Auth` | OAuth2 tokens, auth links |
  | `TruelayerClient.Payments` | Pay-ins, auth flow, refunds, payment links |
  | `TruelayerClient.Payouts` | Merchant-account payouts |
  | `TruelayerClient.Merchant` | Merchant accounts, sweeping |
  | `TruelayerClient.Mandates` | VRP / sweeping mandates |
  | `TruelayerClient.Data` | Accounts, balances, transactions, cards |
  | `TruelayerClient.Verification` | Account holder name verification |
  | `TruelayerClient.SignupPlus` | Embedded user-data collection |
  | `TruelayerClient.Tracking` | Authorization-flow event tracking |
  | `TruelayerClient.Webhooks` | HMAC verification + typed dispatch |

  ## Options

  | Option | Type | Default | Notes |
  |--------|------|---------|-------|
  | `:client_id` | `String.t()` | required | |
  | `:client_secret` | `String.t()` | required | |
  | `:environment` | `:sandbox \\| :live` | `:sandbox` | |
  | `:redirect_uri` | `String.t()` | `nil` | Required for auth-code flows |
  | `:signing_key_pem` | `binary()` | `nil` | Required for Payments/Payouts/Mandates |
  | `:signing_key_id` | `String.t()` | `nil` | Key ID from TrueLayer Console |
  | `:webhook_signing_secret` | `binary()` | `nil` | HMAC-SHA256 webhook secret |
  | `:webhook_replay_tolerance_sec` | `integer()` | `300` | |
  | `:request_timeout_ms` | `integer()` | `30_000` | |
  | `:max_retries` | `integer()` | `3` | |
  | `:base_retry_delay_ms` | `integer()` | `300` | |
  | `:token_store` | `module()` | `MemoryStore` | Implement `TokenStore` behaviour |
  | `:telemetry_prefix` | `[atom()]` | `[:truelayer_client]` | |
  """

  alias TruelayerClient.{Config, Error, HTTP, Idempotency, Signing, Webhooks}

  @typedoc """
  A fully initialised TruelayerClient instance.

  Pass this struct to every domain module function, e.g.:

      TruelayerClient.Payments.get_payment(client, payment_id)
  """
  @type t :: %__MODULE__{
          config: Config.t(),
          http: Req.Request.t(),
          signer: Signing.signer() | nil,
          store_id: reference(),
          idem_table: Idempotency.table(),
          webhook_registry: Webhooks.registry()
        }

  @enforce_keys [:config, :http, :store_id, :idem_table, :webhook_registry]
  defstruct [:config, :http, :signer, :store_id, :idem_table, :webhook_registry]

  @doc """
  Create a new TruelayerClient instance.

  Returns `{:ok, %TruelayerClient{}}` or `{:error, %TruelayerClient.Error{}}`.

  ## Example

      {:ok, client} = TruelayerClient.new(
        environment: :sandbox,
        client_id: "your-client-id",
        client_secret: "your-secret",
        signing_key_pem: File.read!("signing_private.pem"),
        signing_key_id: "your-key-id"
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with {:ok, config} <- Config.new(opts),
         {:ok, signer} <- build_signer(config) do
      client = %__MODULE__{
        config: config,
        http: HTTP.build_client(config),
        signer: signer,
        store_id: make_ref(),
        idem_table: Idempotency.new_table(),
        webhook_registry: Webhooks.new_registry()
      }

      {:ok, client}
    end
  end

  @doc """
  Create a new TruelayerClient instance, raising on failure.

  ## Example

      client = TruelayerClient.new!(environment: :sandbox, client_id: "id", client_secret: "s")
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, client} -> client
      {:error, error} -> raise error
    end
  end

  @doc "Returns the configured environment (`:sandbox` or `:live`)."
  @spec environment(t()) :: Config.environment()
  def environment(%__MODULE__{config: %Config{environment: env}}), do: env

  @doc "Returns `true` when the client is configured for the Sandbox environment."
  @spec sandbox?(t()) :: boolean()
  def sandbox?(%__MODULE__{config: %Config{environment: :sandbox}}), do: true
  def sandbox?(%__MODULE__{}), do: false

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_signer(%Config{signing_key_pem: nil}), do: {:ok, nil}

  defp build_signer(%Config{signing_key_pem: pem, signing_key_id: kid}) do
    Signing.new_signer(pem, kid || "")
  end
end
