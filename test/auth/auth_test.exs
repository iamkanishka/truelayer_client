defmodule TruelayerClient.AuthTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.{MemoryStore, Token}
  alias TruelayerClient.Error

  setup do
    bypass = Bypass.open()
    client = client(bypass)
    {:ok, bypass: bypass, client: client}
  end

  describe "auth_link/2" do
    test "builds a URL with all required params", %{client: client} do
      {:ok, url} = Auth.auth_link(client, scopes: ["payments"], state: "csrf-123")

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert params["response_type"] == "code"
      assert params["client_id"] == "test-client-id"
      assert params["scope"] == "payments"
      assert params["state"] == "csrf-123"
      assert params["redirect_uri"] == "https://example.com/callback"
    end

    test "includes nonce when provided", %{client: client} do
      {:ok, url} = Auth.auth_link(client, scopes: ["payments"], state: "s", nonce: "nonce-xyz")
      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["nonce"] == "nonce-xyz"
    end

    test "includes providers when specified", %{client: client} do
      {:ok, url} =
        Auth.auth_link(client,
          scopes: ["payments"],
          state: "s",
          providers: ["ob-monzo", "ob-revolut"]
        )

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["providers"] == "ob-monzo ob-revolut"
    end

    test "includes enable_mock when true", %{client: client} do
      {:ok, url} =
        Auth.auth_link(client, scopes: ["payments"], state: "s", enable_mock: true)

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["enable_mock"] == "true"
    end

    test "returns error when scopes not provided", %{client: client} do
      assert {:error, %Error{type: :validation_error}} =
               Auth.auth_link(client, state: "s")
    end

    test "returns error when state not provided", %{client: client} do
      assert {:error, %Error{type: :validation_error}} =
               Auth.auth_link(client, scopes: ["payments"])
    end

    test "returns error when redirect_uri not configured" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s")

      assert {:error, %Error{type: :validation_error}} =
               Auth.auth_link(c, scopes: ["payments"], state: "s")
    end
  end

  describe "exchange_code/3" do
    test "fetches and caches a payments token", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "at-pay",
            refresh_token: "rt-pay",
            expires_in: 3600,
            token_type: "Bearer",
            scope: "payments"
          })
        )
      end)

      assert {:ok, token} = Auth.exchange_code(client, "auth-code", :payments)
      assert token.access_token == "at-pay"
      assert token.token_type == :payments
      refute Token.expired?(token)

      # Verify it was cached
      assert {:ok, cached} = MemoryStore.get(client.store_id, :payments)
      assert cached.access_token == "at-pay"
    end

    test "returns error on token endpoint failure", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/problem+json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{title: "Bad Request", detail: "invalid_grant"})
        )
      end)

      assert {:error, %Error{status: 400}} = Auth.exchange_code(client, "bad-code", :payments)
    end
  end

  describe "client_credentials/3" do
    test "fetches and caches a payments token", %{bypass: bypass, client: client} do
      stub_token(bypass, "payments")

      assert {:ok, token} = Auth.client_credentials(client, ["payments"], :payments)
      assert token.access_token == "tok-payments"
      assert token.token_type == :payments
    end

    test "returns cached token on second call (no extra HTTP request)", %{
      bypass: bypass,
      client: client
    } do
      stub_token(bypass, "payments")
      {:ok, _} = Auth.client_credentials(client, ["payments"], :payments)

      # Bypass is down — second call must use the cache
      Bypass.down(bypass)
      assert {:ok, _} = Auth.client_credentials(client, ["payments"], :payments)
      Bypass.up(bypass)
    end

    test "fetches a fresh token when cached token is expired", %{bypass: bypass, client: client} do
      expired_token = %Token{
        access_token: "old-token",
        token_type: :payments,
        expires_at: DateTime.add(DateTime.utc_now(), -10, :second)
      }

      MemoryStore.put(client.store_id, :payments, expired_token)
      stub_token(bypass, "payments")

      {:ok, token} = Auth.client_credentials(client, ["payments"], :payments)
      assert token.access_token == "tok-payments"
    end

    test "payments and data tokens are isolated", %{bypass: bypass, client: client} do
      Bypass.stub(bypass, "POST", "/connect/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        scope = body |> URI.decode_query() |> Map.get("scope", "unknown")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "tok-#{scope}",
            expires_in: 3600,
            token_type: "Bearer",
            scope: scope
          })
        )
      end)

      {:ok, pt} = Auth.client_credentials(client, ["payments"], :payments)
      {:ok, dt} = Auth.client_credentials(client, ["accounts"], :data)

      assert pt.token_type == :payments
      assert dt.token_type == :data
      refute pt.access_token == dt.access_token
    end
  end

  describe "valid_token/2" do
    test "returns error when no token is stored", %{client: client} do
      assert {:error, %Error{type: :auth_error}} = Auth.valid_token(client, :data)
    end

    test "returns stored non-expired token", %{client: client} do
      client = with_data_token(client)
      assert {:ok, token} = Auth.valid_token(client, :data)
      assert token.token_type == :data
    end

    test "auto-refreshes expired token when refresh_token present", %{
      bypass: bypass,
      client: client
    } do
      expired = %Token{
        access_token: "old",
        refresh_token: "rt-key",
        token_type: :data,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      MemoryStore.put(client.store_id, :data, expired)

      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "refreshed-token",
            expires_in: 3600,
            token_type: "Bearer",
            scope: "accounts"
          })
        )
      end)

      assert {:ok, token} = Auth.valid_token(client, :data)
      assert token.access_token == "refreshed-token"
    end

    test "returns error for expired token without refresh_token", %{client: client} do
      expired = %Token{
        access_token: "old",
        refresh_token: nil,
        token_type: :data,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      MemoryStore.put(client.store_id, :data, expired)
      assert {:error, %Error{type: :auth_error}} = Auth.valid_token(client, :data)
    end
  end

  describe "Token" do
    test "from_response/2 applies 30s buffer to expires_at" do
      resp = %{"access_token" => "tok", "expires_in" => 3600, "scope" => "payments"}
      token = Token.from_response(resp, :payments)
      diff = DateTime.diff(token.expires_at, DateTime.utc_now(), :second)
      assert diff >= 3560 and diff <= 3580
    end

    test "expired?/1 returns false for fresh token" do
      token = %Token{
        access_token: "t",
        token_type: :payments,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      refute Token.expired?(token)
    end

    test "expired?/1 returns true for expired token" do
      token = %Token{
        access_token: "t",
        token_type: :payments,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }

      assert Token.expired?(token)
    end

    test "bearer_header/1 returns correctly formatted tuple" do
      token = %Token{
        access_token: "mytoken",
        token_type: :payments,
        expires_at: DateTime.utc_now()
      }

      assert {"authorization", "Bearer mytoken"} = Token.bearer_header(token)
    end
  end
end
