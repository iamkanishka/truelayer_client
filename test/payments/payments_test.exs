defmodule TruelayerClient.PaymentsTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Error, Payments}

  setup do
    bypass = Bypass.open()
    client = bypass |> client() |> with_payments_token()
    {:ok, bypass: bypass, client: client}
  end

  describe "create_payment/3" do
    test "returns created payment on 201 response", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/payments", 201, %{
        id: "pay_001",
        status: "authorization_required",
        resource_token: "rt-abc"
      })

      assert {:ok, payment} =
               Payments.create_payment(client, %{amount_in_minor: 1000, currency: "GBP"},
                 operation_id: "order-001"
               )

      assert payment["id"] == "pay_001"
      assert payment["status"] == "authorization_required"
    end

    test "sends Idempotency-Key header", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v3/payments", fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, Jason.encode!(%{id: "p1", status: "authorization_required"}))
      end)

      {:ok, _} = Payments.create_payment(client, %{}, operation_id: "op-idem")
    end

    test "sends Tl-Signature header", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v3/payments", fn conn ->
        assert Plug.Conn.get_req_header(conn, "tl-signature") != []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, Jason.encode!(%{id: "p2", status: "authorization_required"}))
      end)

      {:ok, _} = Payments.create_payment(client, %{}, operation_id: "op-sig")
    end

    test "same operation_id produces same idempotency key across retries", %{
      bypass: bypass,
      client: client
    } do
      keys = :ets.new(:capture, [:bag, :public])

      Bypass.expect(bypass, "POST", "/v3/payments", fn conn ->
        [key] = Plug.Conn.get_req_header(conn, "idempotency-key")
        :ets.insert(keys, {:key, key})

        conn
        |> Plug.Conn.put_resp_header("tl-should-retry", "true")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{title: "Error"}))
      end)

      {:error, _} = Payments.create_payment(client, %{}, operation_id: "retry-op")

      captured = :ets.lookup(keys, :key) |> Enum.map(fn {_, k} -> k end)
      assert length(captured) > 1
      assert Enum.uniq(captured) |> length() == 1
    end

    test "returns signing_required when signer not configured" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s")
      with_payments_token(c)

      assert {:error, %Error{type: :signing_required}} =
               Payments.create_payment(c, %{}, operation_id: "op")
    end

    test "returns error on API failure", %{bypass: bypass, client: client} do
      stub_error(bypass, "POST", "/v3/payments", 422, "Unprocessable Entity", "invalid amount")

      assert {:error, %Error{status: 422}} =
               Payments.create_payment(client, %{amount_in_minor: -1}, operation_id: "op-fail")
    end
  end

  describe "get_payment/2" do
    test "returns payment on success", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/payments/pay_999", 200, %{
        id: "pay_999",
        status: "executed",
        amount_in_minor: 5000,
        currency: "GBP"
      })

      assert {:ok, payment} = Payments.get_payment(client, "pay_999")
      assert payment["id"] == "pay_999"
      assert payment["status"] == "executed"
    end

    test "returns not_found error on 404", %{bypass: bypass, client: client} do
      stub_error(bypass, "GET", "/v3/payments/nope", 404, "Not Found", "Payment not found")
      assert {:error, %Error{type: :not_found, status: 404}} = Payments.get_payment(client, "nope")
    end

    test "surfaces Tl-Trace-Id from error response", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/v3/payments/bad", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("tl-trace-id", "trace-abc-123")
        |> Plug.Conn.put_resp_content_type("application/problem+json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{title: "Unauthorized"}))
      end)

      assert {:error, %Error{trace_id: "trace-abc-123", status: 401}} =
               Payments.get_payment(client, "bad")
    end
  end

  describe "cancel_payment/3" do
    test "returns ok on success", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/payments/pay_001/cancel", 200, %{})
      assert {:ok, _} = Payments.cancel_payment(client, "pay_001")
    end
  end

  describe "start_authorization_flow/3" do
    test "returns flow response", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/payments/pay_001/authorization-flow", 200, %{
        status: "authorizing",
        authorization_flow: %{
          actions: %{next: %{type: "redirect", uri: "https://bank.example.com"}}
        }
      })

      assert {:ok, resp} =
               Payments.start_authorization_flow(client, "pay_001", %{
                 redirect: %{return_uri: "https://app.com/return"}
               })

      assert resp["status"] == "authorizing"
    end
  end

  describe "submit_provider_selection/3" do
    test "posts provider_id and returns response", %{bypass: bypass, client: client} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v3/payments/pay_001/authorization-flow/actions/provider-selection",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["provider_id"] == "ob-monzo"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "authorizing"}))
        end
      )

      assert {:ok, _} = Payments.submit_provider_selection(client, "pay_001", "ob-monzo")
    end
  end

  describe "list_refunds/2" do
    test "returns refund list", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/payments/pay_001/refunds", 200, %{
        items: [%{id: "ref_001", status: "executed"}, %{id: "ref_002", status: "pending"}]
      })

      assert {:ok, [r1, r2]} = Payments.list_refunds(client, "pay_001")
      assert r1["id"] == "ref_001"
      assert r2["id"] == "ref_002"
    end
  end

  describe "get_refund/3" do
    test "returns a single refund", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/payments/pay_001/refunds/ref_001", 200, %{
        id: "ref_001",
        status: "executed",
        amount_in_minor: 500
      })

      assert {:ok, %{"id" => "ref_001"}} = Payments.get_refund(client, "pay_001", "ref_001")
    end
  end

  describe "get_payment_link/2" do
    test "returns payment link", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/payment-links/link_001", 200, %{
        id: "link_001",
        link: "https://pay.truelayer.com/link_001",
        status: "active"
      })

      assert {:ok, %{"id" => "link_001"}} = Payments.get_payment_link(client, "link_001")
    end
  end

  describe "search_providers/2" do
    test "returns provider list", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/payments-providers/search", 200, %{
        providers: [%{id: "ob-monzo"}, %{id: "ob-revolut"}]
      })

      assert {:ok, %{"providers" => providers}} = Payments.search_providers(client, %{})
      assert length(providers) == 2
    end
  end

  describe "get_provider/2" do
    test "returns a single provider", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/payments-providers/ob-monzo", 200, %{
        id: "ob-monzo",
        display_name: "Monzo"
      })

      assert {:ok, %{"id" => "ob-monzo"}} = Payments.get_provider(client, "ob-monzo")
    end
  end
end
