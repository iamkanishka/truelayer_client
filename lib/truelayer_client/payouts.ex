defmodule TruelayerClient.Payouts do
  @moduledoc """
  TrueLayer Payouts API — move funds from a merchant account to an external bank account.

  All calls are ES512 request-signed and idempotent.
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Error, HTTP, Idempotency, Retry, Signing}

  @doc """
  Create a payout (POST /v3/payouts).

  ## Required option

    * `:operation_id` — stable ID for idempotency
  """
  @spec create_payout(TruelayerClient.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_payout(client, params, opts) when is_map(params) do
    operation_id = Keyword.fetch!(opts, :operation_id)

    with :ok <- require_signer(client),
         {:ok, token} <- payments_token(client) do
      path = "/v3/payouts"
      idem_key = Idempotency.key_for(client.idem_table, operation_id)

      headers = %{
        authorization(token)
        | "idempotency-key" => idem_key
      }

      body_bytes = Jason.encode!(params)

      with {:ok, sig} <- Signing.sign(client.signer, "POST", path, headers, body_bytes),
           signed_headers = Map.put(headers, "tl-signature", sig),
           {:ok, body} <-
             Retry.run(Retry.from_config(client.config), fn ->
               HTTP.json_request(client.http, client.config,
                 method: :post,
                 url: url(client, path),
                 headers: signed_headers,
                 body: params
               )
             end) do
        Idempotency.release(client.idem_table, operation_id)
        {:ok, body}
      end
    end
  end

  @doc "Get a payout by ID (GET /v3/payouts/{id})."
  @spec get_payout(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_payout(client, payout_id) when is_binary(payout_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/payouts/#{payout_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  defp payments_token(client),
    do: Auth.client_credentials(client, Auth.payments_scopes(), :payments)

  defp require_signer(%{signer: nil}), do: {:error, Error.signing_required()}
  defp require_signer(_), do: :ok
  defp authorization(token), do: Map.new([Token.bearer_header(token)])
  defp bearer_map(token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
end
