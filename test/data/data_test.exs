defmodule TruelayerClient.DataTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Data, Error}

  setup do
    bypass = Bypass.open()
    client = bypass |> client() |> with_data_token()
    {:ok, bypass: bypass, client: client}
  end

  describe "list_accounts/1" do
    test "returns list of accounts", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts", 200, %{
        results: [
          %{account_id: "acc-001", display_name: "Current", currency: "GBP"},
          %{account_id: "acc-002", display_name: "Savings", currency: "GBP"}
        ],
        status: "Succeeded"
      })

      assert {:ok, accounts} = Data.list_accounts(client)
      assert length(accounts) == 2
      assert hd(accounts)["account_id"] == "acc-001"
    end
  end

  describe "get_account/2" do
    test "returns single account", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/acc-001", 200, %{
        results: [%{account_id: "acc-001", currency: "GBP"}],
        status: "Succeeded"
      })

      assert {:ok, %{"account_id" => "acc-001"}} = Data.get_account(client, "acc-001")
    end

    test "returns not_found when results empty", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/missing", 200, %{
        results: [],
        status: "Succeeded"
      })

      assert {:error, %Error{type: :not_found}} = Data.get_account(client, "missing")
    end
  end

  describe "get_account_balance/2" do
    test "returns balance", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/acc-001/balance", 200, %{
        results: [%{available: 100.50, current: 100.50, currency: "GBP"}],
        status: "Succeeded"
      })

      assert {:ok, %{"currency" => "GBP"}} = Data.get_account_balance(client, "acc-001")
    end
  end

  describe "get_transactions/3" do
    test "returns transactions", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/acc-001/transactions", 200, %{
        results: [
          %{transaction_id: "txn-001", amount: -25.0, description: "Coffee"},
          %{transaction_id: "txn-002", amount: 1000.0, description: "Salary"}
        ],
        status: "Succeeded"
      })

      assert {:ok, txns} = Data.get_transactions(client, "acc-001")
      assert length(txns) == 2
    end

    test "passes from and to as query params", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/data/v1/accounts/acc-001/transactions", fn conn ->
        assert conn.query_string =~ "from="
        assert conn.query_string =~ "to="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{results: [], status: "Succeeded"}))
      end)

      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-01-31 23:59:59Z]
      assert {:ok, []} = Data.get_transactions(client, "acc-001", from: from, to: to)
    end
  end

  describe "transaction_stream/3" do
    test "returns all transactions lazily", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/acc-001/transactions", 200, %{
        results: [
          %{transaction_id: "t1", amount: -10.0},
          %{transaction_id: "t2", amount: 200.0},
          %{transaction_id: "t3", amount: -5.0}
        ],
        status: "Succeeded"
      })

      all = Data.transaction_stream(client, "acc-001") |> Enum.to_list()
      assert length(all) == 3
    end

    test "stream is composable with Stream.filter", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/acc-001/transactions", 200, %{
        results: [%{amount: -10.0}, %{amount: 500.0}, %{amount: -3.0}],
        status: "Succeeded"
      })

      credits =
        client
        |> Data.transaction_stream("acc-001")
        |> Stream.filter(&(&1["amount"] > 0))
        |> Enum.to_list()

      assert length(credits) == 1
      assert hd(credits)["amount"] == 500.0
    end
  end

  describe "get_standing_orders/2" do
    test "returns standing orders", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/accounts/acc-001/standing_orders", 200, %{
        results: [%{standing_order_id: "so-001", frequency: "Monthly"}],
        status: "Succeeded"
      })

      assert {:ok, [%{"standing_order_id" => "so-001"}]} =
               Data.get_standing_orders(client, "acc-001")
    end
  end

  describe "list_cards/1" do
    test "returns cards", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/cards", 200, %{
        results: [%{account_id: "card-001", card_network: "VISA"}],
        status: "Succeeded"
      })

      assert {:ok, [%{"card_network" => "VISA"}]} = Data.list_cards(client)
    end
  end

  describe "get_card_balance/2" do
    test "returns card balance", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/data/v1/cards/card-001/balance", 200, %{
        results: [%{current: -50.25, credit_limit: 1000.0, currency: "GBP"}],
        status: "Succeeded"
      })

      assert {:ok, %{"currency" => "GBP"}} = Data.get_card_balance(client, "card-001")
    end
  end
end
