defmodule TruelayerClient.PayoutsTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Error, Payouts}

  setup do
    bypass = Bypass.open()
    client = bypass |> client() |> with_payments_token()
    {:ok, bypass: bypass, client: client}
  end

  describe "create_payout/3" do
    test "returns created payout on success", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/payouts", 201, %{id: "po_001", status: "pending"})

      assert {:ok, payout} =
               Payouts.create_payout(
                 client,
                 %{merchant_account_id: "ma-001", amount_in_minor: 5000, currency: "GBP"},
                 operation_id: "payout-op-001"
               )

      assert payout["id"] == "po_001"
      assert payout["status"] == "pending"
    end

    test "sends Tl-Signature and Idempotency-Key headers", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v3/payouts", fn conn ->
        assert Plug.Conn.get_req_header(conn, "tl-signature") != []
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, Jason.encode!(%{id: "po_002", status: "pending"}))
      end)

      {:ok, _} = Payouts.create_payout(client, %{}, operation_id: "op-headers")
    end

    test "returns signing_required when signer not configured" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s")
      with_payments_token(c)

      assert {:error, %Error{type: :signing_required}} =
               Payouts.create_payout(c, %{}, operation_id: "op")
    end

    test "returns error on API failure", %{bypass: bypass, client: client} do
      stub_error(bypass, "POST", "/v3/payouts", 400, "Bad Request", "invalid beneficiary")
      assert {:error, %Error{status: 400}} = Payouts.create_payout(client, %{}, operation_id: "op")
    end
  end

  describe "get_payout/2" do
    test "returns payout on success", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/payouts/po_999", 200, %{
        id: "po_999",
        amount_in_minor: 10_000,
        currency: "GBP",
        status: "executed"
      })

      assert {:ok, payout} = Payouts.get_payout(client, "po_999")
      assert payout["status"] == "executed"
      assert payout["amount_in_minor"] == 10_000
    end

    test "returns not_found on 404", %{bypass: bypass, client: client} do
      stub_error(bypass, "GET", "/v3/payouts/missing", 404, "Not Found", "Payout not found")
      assert {:error, %Error{type: :not_found}} = Payouts.get_payout(client, "missing")
    end
  end
end
