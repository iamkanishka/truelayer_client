defmodule TruelayerClient.Payments do
  @moduledoc """
  TrueLayer Payments API v3.

  All mutating calls (POST) are:
    * **Request-signed** via ES512 JWS (`Tl-Signature` header)
    * **Idempotent** — stable `Idempotency-Key` per `:operation_id`
    * **Retried** on `Tl-Should-Retry: true` responses

  ## Example

      {:ok, payment} = TruelayerClient.Payments.create_payment(client,
        %{
          amount_in_minor: 1000,
          currency: "GBP",
          payment_method: %{
            type: "bank_transfer",
            provider_selection: %{type: "user_selected"},
            beneficiary: %{type: "merchant_account", merchant_account_id: ma_id}
          },
          user: %{name: "Jane Doe", email: "jane@example.com"}
        },
        operation_id: "order-001"
      )
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Error, HTTP, Idempotency, Retry, Signing}

  @terminal_statuses ~w(executed settled failed cancelled)

  # ── Payments ──────────────────────────────────────────────────────────────────

  @doc """
  Create a payment intent (POST /v3/payments).

  ## Required option

    * `:operation_id` — stable caller-supplied ID used to derive the
      `Idempotency-Key`. Safe to retry with the same ID.
  """
  @spec create_payment(TruelayerClient.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_payment(client, params, opts) when is_map(params) do
    operation_id = Keyword.fetch!(opts, :operation_id)

    with :ok <- require_signer(client),
         {:ok, token} <- payments_token(client) do
      path = "/v3/payments"
      idem_key = Idempotency.key_for(client.idem_table, operation_id)
      headers = build_headers(token, idem_key)

      with {:ok, signed_headers} <- sign(client, "POST", path, headers, params),
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

  @doc "Get a payment by ID (GET /v3/payments/{id})."
  @spec get_payment(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_payment(client, payment_id) when is_binary(payment_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/payments/#{payment_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  @doc "Cancel a payment (POST /v3/payments/{id}/cancel)."
  @spec cancel_payment(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def cancel_payment(client, payment_id, opts \\ []) when is_binary(payment_id) do
    operation_id = Keyword.get(opts, :operation_id, Idempotency.new_key())

    with :ok <- require_signer(client),
         {:ok, token} <- payments_token(client) do
      path = "/v3/payments/#{payment_id}/cancel"
      idem_key = Idempotency.key_for(client.idem_table, operation_id)
      headers = build_headers(token, idem_key)

      with {:ok, signed_headers} <- sign(client, "POST", path, headers, nil) do
        HTTP.json_request(client.http, client.config,
          method: :post,
          url: url(client, path),
          headers: signed_headers
        )
      end
    end
  end

  # ── Authorization flow ────────────────────────────────────────────────────────

  @doc "Start the authorization flow (POST /v3/payments/{id}/authorization-flow)."
  @spec start_authorization_flow(TruelayerClient.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def start_authorization_flow(client, payment_id, params) when is_binary(payment_id) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/payments/#{payment_id}/authorization-flow"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc "Submit provider selection."
  @spec submit_provider_selection(TruelayerClient.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def submit_provider_selection(client, payment_id, provider_id) do
    post_flow_action(client, payment_id, "authorization-flow/actions/provider-selection", %{
      "provider_id" => provider_id
    })
  end

  @doc "Submit scheme selection."
  @spec submit_scheme_selection(TruelayerClient.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def submit_scheme_selection(client, payment_id, scheme_id) do
    post_flow_action(client, payment_id, "authorization-flow/actions/scheme-selection", %{
      "scheme_id" => scheme_id
    })
  end

  @doc "Submit form inputs."
  @spec submit_form(TruelayerClient.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def submit_form(client, payment_id, inputs) when is_map(inputs) do
    post_flow_action(client, payment_id, "authorization-flow/actions/form", %{"inputs" => inputs})
  end

  @doc "Submit PSU consent."
  @spec submit_consent(TruelayerClient.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def submit_consent(client, payment_id) do
    post_flow_action(client, payment_id, "authorization-flow/actions/consent", %{
      "consent" => true
    })
  end

  @doc "Submit bank-redirect return parameters (POST /v3/payments-providers/return)."
  @spec submit_return_parameters(TruelayerClient.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def submit_return_parameters(client, params) when is_map(params) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/payments-providers/return"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  # ── Refunds ───────────────────────────────────────────────────────────────────

  @doc """
  Create a refund (POST /v3/payments/{id}/refunds).

  Pass `amount_in_minor: 0` or omit for a full refund.

  ## Required option

    * `:operation_id` — stable ID for idempotency
  """
  @spec create_refund(TruelayerClient.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_refund(client, payment_id, params, opts) when is_binary(payment_id) do
    operation_id = Keyword.fetch!(opts, :operation_id)

    with :ok <- require_signer(client),
         {:ok, token} <- payments_token(client) do
      path = "/v3/payments/#{payment_id}/refunds"
      idem_key = Idempotency.key_for(client.idem_table, operation_id)
      headers = build_headers(token, idem_key)

      with {:ok, signed_headers} <- sign(client, "POST", path, headers, params),
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

  @doc "Get a refund by ID (GET /v3/payments/{id}/refunds/{refund_id})."
  @spec get_refund(TruelayerClient.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_refund(client, payment_id, refund_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/payments/#{payment_id}/refunds/#{refund_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  @doc "List all refunds for a payment (GET /v3/payments/{id}/refunds)."
  @spec list_refunds(TruelayerClient.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_refunds(client, payment_id) do
    with {:ok, token} <- payments_token(client),
         {:ok, resp} <-
           Retry.run(Retry.from_config(client.config), fn ->
             HTTP.json_request(client.http, client.config,
               method: :get,
               url: url(client, "/v3/payments/#{payment_id}/refunds"),
               headers: bearer_map(token)
             )
           end) do
      {:ok, Map.get(resp, "items", [])}
    end
  end

  # ── Payment links ─────────────────────────────────────────────────────────────

  @doc """
  Create a payment link (POST /v3/payment-links).

  ## Required option

    * `:operation_id` — stable ID for idempotency
  """
  @spec create_payment_link(TruelayerClient.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_payment_link(client, params, opts) when is_map(params) do
    operation_id = Keyword.fetch!(opts, :operation_id)

    with :ok <- require_signer(client),
         {:ok, token} <- payments_token(client) do
      path = "/v3/payment-links"
      idem_key = Idempotency.key_for(client.idem_table, operation_id)
      headers = build_headers(token, idem_key)

      with {:ok, signed_headers} <- sign(client, "POST", path, headers, params),
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

  @doc "Get a payment link by ID (GET /v3/payment-links/{id})."
  @spec get_payment_link(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_payment_link(client, link_id) when is_binary(link_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/payment-links/#{link_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  @doc "List payments for a payment link (GET /v3/payment-links/{id}/payments)."
  @spec list_payment_link_payments(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def list_payment_link_payments(client, link_id, opts \\ []) do
    with {:ok, token} <- payments_token(client) do
      query_parts =
        [cursor: opts[:cursor], limit: opts[:limit]]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> URI.encode_query()

      suffix = if query_parts == "", do: "", else: "?#{query_parts}"

      HTTP.json_request(client.http, client.config,
        method: :get,
        url: url(client, "/v3/payment-links/#{link_id}/payments#{suffix}"),
        headers: bearer_map(token)
      )
    end
  end

  # ── Providers ─────────────────────────────────────────────────────────────────

  @doc "Search payment providers (POST /v3/payments-providers/search)."
  @spec search_providers(TruelayerClient.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def search_providers(client, params \\ %{}) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/payments-providers/search"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  @doc "Get a payment provider by ID (GET /v3/payments-providers/{id})."
  @spec get_provider(TruelayerClient.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_provider(client, provider_id) when is_binary(provider_id) do
    with {:ok, token} <- payments_token(client) do
      Retry.run(Retry.from_config(client.config), fn ->
        HTTP.json_request(client.http, client.config,
          method: :get,
          url: url(client, "/v3/payments-providers/#{provider_id}"),
          headers: bearer_map(token)
        )
      end)
    end
  end

  # ── Polling ───────────────────────────────────────────────────────────────────

  @doc """
  Poll `get_payment/2` until a terminal status is reached or the timeout expires.

  Terminal statuses: `executed`, `settled`, `failed`, `cancelled`.

  > Prefer webhook-driven status updates in production systems.

  ## Options

    * `:timeout_ms` - maximum wait time in milliseconds (default: 60_000)
    * `:interval_ms` - polling interval in milliseconds (default: 2_000)
  """
  @spec wait_for_final_status(TruelayerClient.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def wait_for_final_status(client, payment_id, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    interval_ms = Keyword.get(opts, :interval_ms, 2_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(client, payment_id, deadline, interval_ms)
  end

  # ── Internal ──────────────────────────────────────────────────────────────────

  defp post_flow_action(client, payment_id, action, params) do
    with {:ok, token} <- payments_token(client) do
      HTTP.json_request(client.http, client.config,
        method: :post,
        url: url(client, "/v3/payments/#{payment_id}/#{action}"),
        headers: bearer_map(token),
        body: params
      )
    end
  end

  defp poll(client, payment_id, deadline, interval_ms) do
    with {:ok, payment} <- get_payment(client, payment_id) do
      status = Map.get(payment, "status", "")
      remaining = deadline - System.monotonic_time(:millisecond)

      cond do
        status in @terminal_statuses ->
          {:ok, payment}

        remaining <= 0 ->
          {:error,
           %Error{
             type: :timeout,
             reason: "Timeout waiting for final payment status; last status: #{status}",
             should_retry: false
           }}

        true ->
          Process.sleep(min(interval_ms, remaining))
          poll(client, payment_id, deadline, interval_ms)
      end
    end
  end

  defp payments_token(client) do
    Auth.client_credentials(client, Auth.payments_scopes(), :payments)
  end

  defp require_signer(%{signer: nil}), do: {:error, Error.signing_required()}
  defp require_signer(_client), do: :ok

  defp build_headers(%Token{} = token, idem_key) do
    {auth_key, auth_val} = Token.bearer_header(token)

    %{
      auth_key => auth_val,
      "idempotency-key" => idem_key,
      "content-type" => "application/json"
    }
  end

  defp bearer_map(%Token{} = token) do
    {k, v} = Token.bearer_header(token)
    %{k => v}
  end

  defp url(%{config: %{api_url: base}}, path), do: base <> path

  defp sign(%{signer: signer}, method, path, headers, nil) do
    case Signing.sign(signer, method, path, headers, "") do
      {:ok, sig} -> {:ok, Map.put(headers, "tl-signature", sig)}
      err -> err
    end
  end

  defp sign(%{signer: signer}, method, path, headers, body) do
    body_bytes = Jason.encode!(body)

    case Signing.sign(signer, method, path, headers, body_bytes) do
      {:ok, sig} -> {:ok, Map.put(headers, "tl-signature", sig)}
      err -> err
    end
  end
end
