defmodule TruelayerClient.Verification do
  @moduledoc """
  TrueLayer Verification API — account holder name verification and KYC checks.
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Error, HTTP, Retry}

  @doc """
  Verify an account holder's name against their bank records
  (POST /verification/account-holder-name).

  The `params` map must include `"account_holder_name"` and
  `"account_identifier"` fields.

  ## Example

      {:ok, result} = TruelayerClient.Verification.verify_account_holder_name(client, %{
        "account_holder_name" => "Jane Doe",
        "account_identifier" => %{
          "type" => "sort_code_account_number",
          "sort_code" => "040004",
          "account_number" => "12345678"
        }
      })
      # result["result"] == "match" | "no_match"
  """
  @spec verify_account_holder_name(TruelayerClient.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def verify_account_holder_name(client, params) when is_map(params) do
    with :ok <- require_name(params),
         {:ok, token} <- data_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/verification/account-holder-name"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc """
  Create an account holder verification resource
  (POST /verification/account-holder).

  Returns a verification with initial `status: "pending"`. Poll via
  `get_account_holder_verification/2` or listen for the webhook event.
  """
  @spec create_account_holder_verification(TruelayerClient.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_account_holder_verification(client, params) when is_map(params) do
    with {:ok, token} <- data_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/verification/account-holder"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc """
  Get an account holder verification by ID
  (GET /verification/account-holder/{id}).
  """
  @spec get_account_holder_verification(TruelayerClient.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_account_holder_verification(client, verification_id) when is_binary(verification_id) do
    with {:ok, token} <- data_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/verification/account-holder/#{verification_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp require_name(%{"account_holder_name" => name})
       when is_binary(name) and byte_size(name) > 0 do
    :ok
  end

  defp require_name(_) do
    {:error,
     %Error{
       type: :validation_error,
       reason: "\"account_holder_name\" is required and must not be empty",
       should_retry: false
     }}
  end

  defp data_token(client), do: Auth.client_credentials(client, Auth.data_scopes(), :data)
  defp bearer_map(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
end
