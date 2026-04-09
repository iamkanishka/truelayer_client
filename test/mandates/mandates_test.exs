defmodule TruelayerClient.MandatesTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Error, Mandates}

  setup do
    bypass = Bypass.open()
    client = bypass |> client() |> with_payments_token()
    {:ok, bypass: bypass, client: client}
  end

  describe "create_mandate/3" do
    test "returns created mandate", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/mandates", 201, %{
        id: "man-001",
        status: "authorization_required",
        mandate_type: "sweeping"
      })

      assert {:ok, mandate} =
               Mandates.create_mandate(
                 client,
                 %{mandate_type: "sweeping", currency: "GBP"},
                 operation_id: "mandate-op-001"
               )

      assert mandate["id"] == "man-001"
      assert mandate["status"] == "authorization_required"
    end

    test "requires signer" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s")
      with_payments_token(c)

      assert {:error, %Error{type: :signing_required}} =
               Mandates.create_mandate(c, %{}, operation_id: "op")
    end
  end

  describe "get_mandate/2" do
    test "returns mandate by ID", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/mandates/man-999", 200, %{
        id: "man-999",
        status: "authorized"
      })

      assert {:ok, %{"id" => "man-999"}} = Mandates.get_mandate(client, "man-999")
    end
  end

  describe "list_mandates/2" do
    test "returns mandate list", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/mandates", 200, %{
        items: [%{id: "man-001"}, %{id: "man-002"}]
      })

      assert {:ok, resp} = Mandates.list_mandates(client)
      assert length(resp["items"]) == 2
    end
  end

  describe "confirm_funds/3" do
    test "returns confirmed true", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/v3/mandates/man-001/funds", fn conn ->
        assert conn.query_string =~ "amount_in_minor=10000"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{confirmed: true}))
      end)

      assert {:ok, %{"confirmed" => true}} = Mandates.confirm_funds(client, "man-001", 10_000)
    end
  end

  describe "revoke_mandate/2" do
    test "returns :ok on success", %{bypass: bypass, client: client} do
      stub_json(bypass, "POST", "/v3/mandates/man-001/revoke", 200, %{})
      assert :ok = Mandates.revoke_mandate(client, "man-001")
    end
  end

  describe "get_constraints/2" do
    test "returns constraints", %{bypass: bypass, client: client} do
      stub_json(bypass, "GET", "/v3/mandates/man-001/constraints", 200, %{
        constraints: %{valid_to: "2025-12-31"},
        used_amount_in_minor: 0
      })

      assert {:ok, resp} = Mandates.get_constraints(client, "man-001")
      assert resp["used_amount_in_minor"] == 0
    end
  end
end
