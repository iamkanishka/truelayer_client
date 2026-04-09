defmodule TruelayerClient.MerchantTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Error, Merchant}

  setup do
    bypass = Bypass.open()
    client = bypass |> client() |> with_payments_token()
    {:ok, bypass: bypass, client: client}
  end

  describe "list_accounts/1" do
    test "returns list of merchant accounts", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/merchant-accounts", 200, %{
        items: [
          %{id: "ma-001", currency: "GBP", available_balance_in_minor: 100_000},
          %{id: "ma-002", currency: "EUR", available_balance_in_minor: 50_000}
        ]
      })

      assert {:ok, accounts} = Merchant.list_accounts(client)
      assert length(accounts) == 2
      assert hd(accounts)["id"] == "ma-001"
    end
  end

  describe "get_account/2" do
    test "returns a single account", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/merchant-accounts/ma-001", 200, %{
        id: "ma-001",
        currency: "GBP"
      })

      assert {:ok, %{"id" => "ma-001"}} = Merchant.get_account(client, "ma-001")
    end

    test "returns not_found on 404", %{bypass: bypass, client: client} do
      stub_error(bypass, "GET", "/v3/merchant-accounts/gone", 404, "Not Found", "")
      assert {:error, %Error{type: :not_found}} = Merchant.get_account(client, "gone")
    end
  end

  describe "get_transactions/3" do
    test "returns transactions", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/merchant-accounts/ma-001/transactions", 200, %{
        items: [%{id: "txn-1", type: "payout"}, %{id: "txn-2", type: "refund"}]
      })

      assert {:ok, resp} = Merchant.get_transactions(client, "ma-001")
      assert length(resp["items"]) == 2
    end

    test "passes query params", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/v3/merchant-accounts/ma-001/transactions", fn conn ->
        assert conn.query_string =~ "type=payout"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{items: []}))
      end)

      {:ok, _} = Merchant.get_transactions(client, "ma-001", type: "payout")
    end
  end

  describe "setup_sweeping/3" do
    test "returns sweeping config", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/merchant-accounts/ma-001/sweeping", 200, %{
        max_amount_in_minor: 100_000,
        currency: "GBP",
        frequency: "daily"
      })

      assert {:ok, %{"frequency" => "daily"}} =
               Merchant.setup_sweeping(client, "ma-001", %{
                 max_amount_in_minor: 100_000,
                 currency: "GBP",
                 frequency: "daily"
               })
    end
  end

  describe "disable_sweeping/2" do
    test "returns :ok on success", %{bypass: bypass, client: client} do
      stub_json(bypass, "DELETE", "/v3/merchant-accounts/ma-001/sweeping", 200, %{})
      assert :ok = Merchant.disable_sweeping(client, "ma-001")
    end
  end

  describe "get_payment_sources/2" do
    test "returns payment sources", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/merchant-accounts/ma-001/payment-sources", 200, %{
        items: [%{id: "ps-001", account_holder_name: "Jane Doe"}]
      })

      assert {:ok, [%{"id" => "ps-001"}]} = Merchant.get_payment_sources(client, "ma-001")
    end
  end
end
