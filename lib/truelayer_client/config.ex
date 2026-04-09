defmodule TruelayerClient.Config do
  @moduledoc """
  Validated configuration struct for a TruelayerClient instance.

  Created internally by `TruelayerClient.new/1`. Do not build directly.

  ## Fields

    * `:client_id` - OAuth2 client ID (required)
    * `:client_secret` - OAuth2 client secret (required)
    * `:environment` - `:sandbox` or `:live` (default: `:sandbox`)
    * `:api_url` - resolved API base URL
    * `:auth_url` - resolved Auth server base URL
    * `:redirect_uri` - OAuth2 redirect URI for user-facing flows
    * `:signing_key_pem` - PEM-encoded EC private key for request signing
    * `:signing_key_id` - key ID registered in the TrueLayer Console
    * `:webhook_signing_secret` - HMAC-SHA256 secret for webhook verification
    * `:webhook_replay_tolerance_sec` - max accepted webhook age in seconds (default: 300)
    * `:request_timeout_ms` - HTTP timeout in milliseconds (default: 30_000)
    * `:max_retries` - maximum retry attempts (default: 3)
    * `:base_retry_delay_ms` - base exponential-backoff delay in ms (default: 300)
    * `:token_store` - module implementing `TruelayerClient.Auth.TokenStore`
    * `:telemetry_prefix` - prefix for telemetry events (default: `[:truelayer_client]`)
  """

  alias TruelayerClient.Error

  @type environment :: :sandbox | :live

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_secret: String.t(),
          environment: environment(),
          api_url: String.t(),
          auth_url: String.t(),
          redirect_uri: String.t() | nil,
          signing_key_pem: binary() | nil,
          signing_key_id: String.t() | nil,
          webhook_signing_secret: binary() | nil,
          webhook_replay_tolerance_sec: non_neg_integer(),
          request_timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          base_retry_delay_ms: non_neg_integer(),
          token_store: module(),
          telemetry_prefix: [atom()]
        }

  @enforce_keys [:client_id, :client_secret, :environment, :api_url, :auth_url, :token_store]
  defstruct [
    :client_id,
    :client_secret,
    :environment,
    :api_url,
    :auth_url,
    :redirect_uri,
    :signing_key_pem,
    :signing_key_id,
    :webhook_signing_secret,
    webhook_replay_tolerance_sec: 300,
    request_timeout_ms: 30_000,
    max_retries: 3,
    base_retry_delay_ms: 300,
    token_store: TruelayerClient.Auth.MemoryStore,
    telemetry_prefix: [:truelayer_client]
  ]

  @env_urls %{
    sandbox: %{
      api: "https://api.truelayer-sandbox.com",
      auth: "https://auth.truelayer-sandbox.com"
    },
    live: %{
      api: "https://api.truelayer.com",
      auth: "https://auth.truelayer.com"
    }
  }

  @doc """
  Build and validate a `Config` from keyword options.

  Returns `{:ok, config}` or `{:error, %TruelayerClient.Error{type: :validation_error}}`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with {:ok, client_id} <- required_string(opts, :client_id),
         {:ok, client_secret} <- required_string(opts, :client_secret),
         {:ok, env} <- validate_environment(Keyword.get(opts, :environment, :sandbox)),
         {:ok, urls} <- resolve_urls(env) do
      config = %__MODULE__{
        client_id: client_id,
        client_secret: client_secret,
        environment: env,
        api_url: urls.api,
        auth_url: urls.auth,
        redirect_uri: Keyword.get(opts, :redirect_uri),
        signing_key_pem: Keyword.get(opts, :signing_key_pem),
        signing_key_id: Keyword.get(opts, :signing_key_id),
        webhook_signing_secret: Keyword.get(opts, :webhook_signing_secret),
        webhook_replay_tolerance_sec: Keyword.get(opts, :webhook_replay_tolerance_sec, 300),
        request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 30_000),
        max_retries: Keyword.get(opts, :max_retries, 3),
        base_retry_delay_ms: Keyword.get(opts, :base_retry_delay_ms, 300),
        token_store: Keyword.get(opts, :token_store, TruelayerClient.Auth.MemoryStore),
        telemetry_prefix: Keyword.get(opts, :telemetry_prefix, [:truelayer_client])
      }

      {:ok, config}
    end
  end

  # ── Validators ────────────────────────────────────────────────────────────────

  defp required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_binary(val) and byte_size(val) > 0 ->
        {:ok, val}

      {:ok, _} ->
        {:error, validation("#{key} must be a non-empty string")}

      :error ->
        {:error, validation("#{key} is required")}
    end
  end

  defp validate_environment(env) when env in [:sandbox, :live], do: {:ok, env}

  defp validate_environment(other) do
    {:error, validation("environment must be :sandbox or :live, got: #{inspect(other)}")}
  end

  defp resolve_urls(env) do
    case Map.fetch(@env_urls, env) do
      {:ok, urls} -> {:ok, urls}
      :error -> {:error, validation("no URLs configured for environment #{inspect(env)}")}
    end
  end

  defp validation(message) do
    %Error{type: :validation_error, reason: message, should_retry: false}
  end
end
