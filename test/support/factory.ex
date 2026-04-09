defmodule TruelayerClient.Factory do
  @moduledoc "Shared test helpers — client construction and Bypass stubs."

  alias TruelayerClient.Auth.{MemoryStore, Token}

  @doc """
  Build a client whose API and Auth URLs point at a Bypass server.

  Extra options are merged into `TruelayerClient.new/1`.
  """
  @spec client(Bypass.t(), keyword()) :: TruelayerClient.t()
  def client(bypass, opts \\ []) do
    base_url = "http://localhost:#{bypass.port}"

    base_opts = [
      environment: :sandbox,
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      redirect_uri: "https://example.com/callback"
    ]

    {:ok, client} =
      base_opts
      |> Keyword.merge(opts)
      |> TruelayerClient.new()

    # Override resolved URLs to point at Bypass
    config = %{client.config | api_url: base_url, auth_url: base_url}
    %{client | config: config}
  end

  @doc "Pre-insert a live Payments token so calls skip the token endpoint."
  @spec with_payments_token(TruelayerClient.t()) :: TruelayerClient.t()
  def with_payments_token(client) do
    token = %Token{
      access_token: "test-payments-token",
      token_type: :payments,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      scopes: ["payments"]
    }

    :ok = MemoryStore.put(client.store_id, :payments, token)
    client
  end

  @doc "Pre-insert a live Data token so calls skip the token endpoint."
  @spec with_data_token(TruelayerClient.t()) :: TruelayerClient.t()
  def with_data_token(client) do
    token = %Token{
      access_token: "test-data-token",
      token_type: :data,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      scopes: ["accounts", "balance", "transactions"]
    }

    :ok = MemoryStore.put(client.store_id, :data, token)
    client
  end

  @doc "Stub the Bypass token endpoint (POST /connect/token) with a valid response."
  @spec stub_token(Bypass.t(), String.t()) :: :ok
  def stub_token(bypass, scope \\ "payments") do
    Bypass.stub(bypass, "POST", "/connect/token", fn conn ->
      body =
        Jason.encode!(%{
          access_token: "tok-#{scope}",
          refresh_token: "refresh-#{scope}",
          expires_in: 3600,
          token_type: "Bearer",
          scope: scope
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  @doc "Stub a single Bypass request to return JSON."
  @spec stub_json(Bypass.t(), String.t(), String.t(), non_neg_integer(), map()) :: :ok
  def stub_json(bypass, method, path, status, body) do
    Bypass.expect_once(bypass, method, path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)

    :ok
  end

  @doc "Stub a Bypass request to return an RFC 7807 problem+json error."
  @spec stub_error(Bypass.t(), String.t(), String.t(), non_neg_integer(), String.t(), String.t()) ::
          :ok
  def stub_error(bypass, method, path, status, title, detail) do
    Bypass.expect_once(bypass, method, path, fn conn ->
      body = Jason.encode!(%{title: title, detail: detail})

      conn
      |> Plug.Conn.put_resp_header("tl-trace-id", "trace-test-id")
      |> Plug.Conn.put_resp_content_type("application/problem+json")
      |> Plug.Conn.send_resp(status, body)
    end)

    :ok
  end

  @doc "HMAC-SHA256 sign a webhook body for use in tests."
  @spec sign_webhook(binary(), String.t(), binary()) :: String.t()
  def sign_webhook(body, timestamp, secret) do
    payload = "#{timestamp}.#{body}"
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
  end

  @doc "Build a webhook event JSON body."
  @spec webhook_body(String.t(), map()) :: binary()
  def webhook_body(event_type, payload \\ %{}) do
    Jason.encode!(%{
      event_id: "evt-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}",
      event_type: event_type,
      event_version: 1,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: payload
    })
  end
end
