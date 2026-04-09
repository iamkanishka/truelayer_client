defmodule TruelayerClient.SignupPlus do
  @moduledoc """
  TrueLayer Signup+ API — collect verified user data embedded in a payment or auth flow.

  Signup+ lets you request verified identity data (name, email, address, DOB)
  as part of an existing payment or mandate authorization, without a separate
  identity verification step.
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.HTTP

  @doc "Get verified user data associated with a payment (GET /signup-plus/data/v1/payments/{id})."
  @spec get_user_data_by_payment(TruelayerClient.t(), String.t()) ::
          {:ok, map()} | {:error, TruelayerClient.Error.t()}
  def get_user_data_by_payment(client, payment_id) when is_binary(payment_id) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, "/signup-plus/data/v1/payments/#{payment_id}"),
        headers: bearer_map(token)
      )
    end
  end

  @doc "Get user data via a Data API connected account (GET /signup-plus/data/v1/connected-accounts/{id})."
  @spec get_user_data_by_connected_account(TruelayerClient.t(), String.t()) ::
          {:ok, map()} | {:error, TruelayerClient.Error.t()}
  def get_user_data_by_connected_account(client, account_id) when is_binary(account_id) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, "/signup-plus/data/v1/connected-accounts/#{account_id}"),
        headers: bearer_map(token)
      )
    end
  end

  @doc "Get user data associated with a mandate (GET /signup-plus/data/v1/mandates/{id})."
  @spec get_user_data_by_mandate(TruelayerClient.t(), String.t()) ::
          {:ok, map()} | {:error, TruelayerClient.Error.t()}
  def get_user_data_by_mandate(client, mandate_id) when is_binary(mandate_id) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, "/signup-plus/data/v1/mandates/#{mandate_id}"),
        headers: bearer_map(token)
      )
    end
  end

  @doc "Generate a Signup+ authorization URI (POST /signup-plus/auth-uri)."
  @spec generate_auth_uri(TruelayerClient.t(), map()) ::
          {:ok, map()} | {:error, TruelayerClient.Error.t()}
  def generate_auth_uri(client, params) when is_map(params) do
    with {:ok, token} <- payments_token(client) do
      body = Map.put_new(params, "client_id", client.config.client_id)

      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/signup-plus/auth-uri"),
        headers: bearer_map(token),
        body: body
      )
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp payments_token(client),
    do: Auth.client_credentials(client, Auth.payments_scopes(), :payments)

  defp bearer_map(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
end
