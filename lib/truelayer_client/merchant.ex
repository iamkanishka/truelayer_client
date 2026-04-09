defmodule TruelayerClient.Merchant do
  @moduledoc """
  TrueLayer Merchant Accounts API.

  Provides access to merchant accounts, ledger transactions, sweeping
  configuration, and payment sources.
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Error, HTTP, Retry}

  @doc "List all merchant accounts (GET /v3/merchant-accounts)."
  @spec list_accounts(TruelayerClient.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_accounts(client) do
    with {:ok, token} <- payments_token(client),
         {:ok, resp} <- get(client, token, "/v3/merchant-accounts") do
      {:ok, Map.get(resp, "items", [])}
    end
  end

  @doc "Get a merchant account by ID (GET /v3/merchant-accounts/{id})."
  @spec get_account(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_account(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- payments_token(client) do
      get(client, token, "/v3/merchant-accounts/#{account_id}")
    end
  end

  @doc """
  Get paginated ledger transactions for a merchant account
  (GET /v3/merchant-accounts/{id}/transactions).

  ## Options

    * `:from` - ISO 8601 start datetime string
    * `:to` - ISO 8601 end datetime string
    * `:type` - filter by transaction type (e.g. `"payout"`, `"refund"`)
    * `:cursor` - pagination cursor from previous response
  """
  @spec get_transactions(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_transactions(client, account_id, opts \\ []) when is_binary(account_id) do
    with {:ok, token} <- payments_token(client) do
      query =
        opts
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
        |> URI.encode_query()

      suffix = if query == "", do: "", else: "?#{query}"
      get(client, token, "/v3/merchant-accounts/#{account_id}/transactions#{suffix}")
    end
  end

  @doc "Configure sweeping for a merchant account (POST /v3/merchant-accounts/{id}/sweeping)."
  @spec setup_sweeping(TruelayerClient.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def setup_sweeping(client, account_id, params) when is_binary(account_id) and is_map(params) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/merchant-accounts/#{account_id}/sweeping"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc "Disable sweeping (DELETE /v3/merchant-accounts/{id}/sweeping)."
  @spec disable_sweeping(TruelayerClient.t(), String.t()) :: :ok | {:error, Error.t()}
  def disable_sweeping(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- payments_token(client),
         {:ok, _} <-
           HTTP.json_request(client.http, client.config,
             method: :delete,
             url: url(client, "/v3/merchant-accounts/#{account_id}/sweeping"),
             headers: bearer_map(token)
           ) do
      :ok
    end
  end

  @doc "Get sweeping configuration (GET /v3/merchant-accounts/{id}/sweeping)."
  @spec get_sweeping(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_sweeping(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- payments_token(client) do
      get(client, token, "/v3/merchant-accounts/#{account_id}/sweeping")
    end
  end

  @doc "Get payment sources for a merchant account."
  @spec get_payment_sources(TruelayerClient.t(), String.t()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_payment_sources(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- payments_token(client),
         {:ok, resp} <- get(client, token, "/v3/merchant-accounts/#{account_id}/payment-sources") do
      {:ok, Map.get(resp, "items", [])}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp get(client, token, path) do
    Retry.run(Retry.from_config(client.config), fn ->
      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, path),
        headers: bearer_map(token)
      )
    end)
  end

  defp payments_token(client),
    do: Auth.client_credentials(client, Auth.payments_scopes(), :payments)

  defp bearer_map(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
end
