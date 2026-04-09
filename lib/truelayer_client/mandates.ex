defmodule TruelayerClient.Mandates do
  @moduledoc """
  TrueLayer Mandates API — Variable Recurring Payments (VRP) and sweeping mandates.

  A mandate authorises the SDK to initiate repeated payments on behalf of a PSU
  without requiring re-authorisation for each individual payment.

  All mutating calls are ES512 request-signed and carry idempotency keys.
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Error, HTTP, Idempotency, Retry, Signing}

  @doc """
  Create a mandate (POST /v3/mandates).

  ## Required option

    * `:operation_id` — stable ID for idempotency
  """
  @spec create_mandate(TruelayerClient.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_mandate(client, params, opts) when is_map(params) do
    operation_id = Keyword.fetch!(opts, :operation_id)

    with :ok <- require_signer(client),
         {:ok, token} <- payments_token(client) do
      path = "/v3/mandates"
      idem_key = Idempotency.key_for(client.idem_table, operation_id)

      headers = %{
        authorization(token)
        | "idempotency-key" => idem_key,
          "content-type" => "application/json"
      }

      body_bytes = Jason.encode!(params)

      with {:ok, sig} <- Signing.sign(client.signer, "POST", path, headers, body_bytes),
           signed_headers = Map.put(headers, "tl-signature", sig),
           {:ok, body} <-
             HTTP.json_request(client.http, client.config,
               method: :post,
               url: url(client, path),
               headers: signed_headers,
               body: params
             ) do
        Idempotency.release(client.idem_table, operation_id)
        {:ok, body}
      end
    end
  end

  @doc "List mandates with optional cursor pagination (GET /v3/mandates)."
  @spec list_mandates(TruelayerClient.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_mandates(client, opts \\ []) do
    with {:ok, token} <- payments_token(client) do
      suffix = if cursor = opts[:cursor], do: "?cursor=#{cursor}", else: ""

      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/mandates#{suffix}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  @doc "Get a mandate by ID (GET /v3/mandates/{id})."
  @spec get_mandate(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_mandate(client, mandate_id) when is_binary(mandate_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/mandates/#{mandate_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  @doc "Start the authorization flow for a mandate."
  @spec start_authorization_flow(TruelayerClient.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def start_authorization_flow(client, mandate_id, params) when is_map(params) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/mandates/#{mandate_id}/authorization-flow"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc "Submit provider selection for a mandate."
  @spec submit_provider_selection(TruelayerClient.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def submit_provider_selection(client, mandate_id, provider_id) when is_binary(provider_id) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url:
          url(client, "/v3/mandates/#{mandate_id}/authorization-flow/actions/provider-selection"),
        headers: bearer_map(token),
        body: %{"provider_id" => provider_id}
      )
    end
  end

  @doc "Submit PSU consent for a mandate."
  @spec submit_consent(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def submit_consent(client, mandate_id) when is_binary(mandate_id) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/mandates/#{mandate_id}/authorization-flow/actions/consent"),
        headers: bearer_map(token),
        body: %{"consent" => true}
      )
    end
  end

  @doc "Revoke an active mandate (POST /v3/mandates/{id}/revoke)."
  @spec revoke_mandate(TruelayerClient.t(), String.t()) :: :ok | {:error, Error.t()}
  def revoke_mandate(client, mandate_id) when is_binary(mandate_id) do
    with {:ok, token} <- payments_token(client),
         {:ok, _} <-
           HTTP.json_request(client.http, client.config,
             method: :post,
             url: url(client, "/v3/mandates/#{mandate_id}/revoke"),
             headers: bearer_map(token)
           ) do
      :ok
    end
  end

  @doc "Check whether sufficient funds are available under a mandate."
  @spec confirm_funds(TruelayerClient.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def confirm_funds(client, mandate_id, amount_in_minor)
      when is_binary(mandate_id) and is_integer(amount_in_minor) and amount_in_minor > 0 do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, "/v3/mandates/#{mandate_id}/funds?amount_in_minor=#{amount_in_minor}"),
        headers: bearer_map(token)
      )
    end
  end

  @doc "Get constraints for a mandate (GET /v3/mandates/{id}/constraints)."
  @spec get_constraints(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_constraints(client, mandate_id) when is_binary(mandate_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/mandates/#{mandate_id}/constraints"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp payments_token(client),
    do: Auth.client_credentials(client, Auth.payments_scopes(), :payments)

  defp require_signer(%{signer: nil}), do: {:error, Error.signing_required()}
  defp require_signer(_), do: :ok
  defp authorization(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp bearer_map(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
end
