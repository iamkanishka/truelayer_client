defmodule TruelayerClient.Data do
  @moduledoc """
  TrueLayer Data API v1.

  Requires a user-delegated **Data-scoped** token obtained via
  `TruelayerClient.Auth.exchange_code/3` with Data scopes.

  Data tokens and Payments tokens are strictly isolated — a Data token
  cannot authorise a Payments API call and vice versa.

  ## Lazy streaming

  `transaction_stream/3` returns a lazy `Stream.t()` backed by `Stream.resource/3`.
  This allows functional composition without loading all transactions into memory:

      client
      |> TruelayerClient.Data.transaction_stream(account_id,
           from: ~U[2024-01-01 00:00:00Z], to: ~U[2024-03-31 23:59:59Z])
      |> Stream.filter(&(&1["transaction_type"] == "CREDIT"))
      |> Stream.map(& &1["amount"])
      |> Enum.sum()
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Error, HTTP, Retry}

  # ── Connection metadata ───────────────────────────────────────────────────────

  @doc "Get connection metadata for the current token (GET /data/v1/me)."
  @spec get_connection_meta(TruelayerClient.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_connection_meta(client) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/me") do
      single_result(resp, "connection meta")
    end
  end

  @doc "Get identity info for the authenticated user (GET /data/v1/info)."
  @spec get_user_info(TruelayerClient.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_user_info(client) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/info") do
      single_result(resp, "user info")
    end
  end

  # ── Accounts ──────────────────────────────────────────────────────────────────

  @doc "List all bank accounts (GET /data/v1/accounts)."
  @spec list_accounts(TruelayerClient.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_accounts(client) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/accounts") do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  @doc "Get a single account (GET /data/v1/accounts/{id})."
  @spec get_account(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_account(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/accounts/#{account_id}") do
      single_result(resp, "account")
    end
  end

  @doc "Get the balance for an account (GET /data/v1/accounts/{id}/balance)."
  @spec get_account_balance(TruelayerClient.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_account_balance(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/accounts/#{account_id}/balance") do
      single_result(resp, "account balance")
    end
  end

  @doc """
  Get settled transactions for an account (GET /data/v1/accounts/{id}/transactions).

  ## Options

    * `:from` - `DateTime` lower bound
    * `:to` - `DateTime` upper bound
  """
  @spec get_transactions(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_transactions(client, account_id, opts \\ []) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <-
           get(client, token, txn_path("/data/v1/accounts/#{account_id}/transactions", opts)) do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  @doc "Get pending transactions for an account."
  @spec get_pending_transactions(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_pending_transactions(client, account_id, opts \\ []) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <-
           get(
             client,
             token,
             txn_path("/data/v1/accounts/#{account_id}/transactions/pending", opts)
           ) do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  @doc """
  Return a lazy `Stream.t()` of settled transactions for an account.

  The stream fetches transactions on first consumption and yields them one at a time.
  Compose with `Stream.filter/2`, `Stream.map/2`, `Enum.take/2`, etc.

  ## Example

      client
      |> TruelayerClient.Data.transaction_stream("acc-001", from: ~U[2024-01-01 00:00:00Z])
      |> Stream.filter(&(&1["amount"] < 0))
      |> Enum.to_list()
  """
  @spec transaction_stream(TruelayerClient.t(), String.t(), keyword()) :: Enumerable.t()
  def transaction_stream(client, account_id, opts \\ []) do
    Stream.resource(
      fn -> :start end,
      fn
        :start ->
          case get_transactions(client, account_id, opts) do
            {:ok, txns} -> {txns, :done}
            {:error, _err} -> {:halt, :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _acc -> :ok end
    )
  end

  @doc "Get standing orders for an account."
  @spec get_standing_orders(TruelayerClient.t(), String.t()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_standing_orders(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/accounts/#{account_id}/standing_orders") do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  @doc "Get direct debits for an account."
  @spec get_direct_debits(TruelayerClient.t(), String.t()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_direct_debits(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/accounts/#{account_id}/direct_debits") do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  # ── Cards ─────────────────────────────────────────────────────────────────────

  @doc "List all cards (GET /data/v1/cards)."
  @spec list_cards(TruelayerClient.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_cards(client) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/cards") do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  @doc "Get a single card (GET /data/v1/cards/{id})."
  @spec get_card(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_card(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/cards/#{account_id}") do
      single_result(resp, "card")
    end
  end

  @doc "Get the balance for a card (GET /data/v1/cards/{id}/balance)."
  @spec get_card_balance(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_card_balance(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/cards/#{account_id}/balance") do
      single_result(resp, "card balance")
    end
  end

  @doc "Get settled transactions for a card."
  @spec get_card_transactions(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_card_transactions(client, account_id, opts \\ []) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <-
           get(client, token, txn_path("/data/v1/cards/#{account_id}/transactions", opts)) do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  @doc "Get pending transactions for a card."
  @spec get_card_pending_transactions(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_card_pending_transactions(client, account_id, opts \\ []) when is_binary(account_id) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <-
           get(client, token, txn_path("/data/v1/cards/#{account_id}/transactions/pending", opts)) do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  # ── Providers ─────────────────────────────────────────────────────────────────

  @doc "List available data providers (GET /data/v1/providers)."
  @spec list_providers(TruelayerClient.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_providers(client) do
    with {:ok, token} <- data_token(client),
         {:ok, resp} <- get(client, token, "/data/v1/providers") do
      {:ok, Map.get(resp, "results", [])}
    end
  end

  # ── Auth links & connection management ────────────────────────────────────────

  @doc "Generate a direct bank authentication link."
  @spec generate_direct_auth_link(TruelayerClient.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def generate_direct_auth_link(client, params \\ %{}) when is_map(params) do
    with {:ok, token} <- data_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: auth_url(client, "/connect/direct_auth_link"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc "Generate a re-authentication link for an existing connection."
  @spec generate_reauth_link(TruelayerClient.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def generate_reauth_link(client, params \\ %{}) when is_map(params) do
    with {:ok, token} <- data_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: auth_url(client, "/connect/reauth_link"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc "Extend an existing connection's consent period."
  @spec extend_connection(TruelayerClient.t(), map()) :: :ok | {:error, Error.t()}
  def extend_connection(client, params \\ %{}) when is_map(params) do
    with {:ok, token} <- data_token(client),
         {:ok, _} <-
           HTTP.json_request(client.http, client.config,
             method: :post,
             url: auth_url(client, "/connect/extend"),
             headers: bearer_map(token),
             body: params
           ) do
      :ok
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp data_token(client), do: Auth.valid_token(client, :data)

  defp get(client, token, path) do
    Retry.run(Retry.from_config(client.config), fn ->
      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, path),
        headers: bearer_map(token)
      )
    end)
  end

  defp single_result(%{"results" => [item | _]}, _name), do: {:ok, item}

  defp single_result(%{"results" => []}, name) do
    {:error, %Error{type: :not_found, status: 404, reason: "#{name} not found"}}
  end

  defp single_result(resp, _name) when is_map(resp), do: {:ok, resp}

  defp txn_path(base, opts) do
    params =
      []
      |> add_dt_param(:from, opts[:from])
      |> add_dt_param(:to, opts[:to])
      |> URI.encode_query()

    if params == "", do: base, else: "#{base}?#{params}"
  end

  defp add_dt_param(list, _key, nil), do: list
  defp add_dt_param(list, key, %DateTime{} = dt), do: [{key, DateTime.to_iso8601(dt)} | list]
  defp add_dt_param(list, key, val) when is_binary(val), do: [{key, val} | list]

  defp bearer_map(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
  defp auth_url(%{config: %{auth_url: base}}, path), do: base <> path
end
