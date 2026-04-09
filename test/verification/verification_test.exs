defmodule TruelayerClient.VerificationTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Error, Verification}

  setup do
    bypass = Bypass.open()
    # Verification uses data_scopes but client_credentials flow
    client = bypass |> client() |> with_payments_token()
    {:ok, bypass: bypass, client: client}
  end

  describe "verify_account_holder_name/2" do
    test "returns match result", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "data-tok",
            expires_in: 3600,
            token_type: "Bearer",
            scope: "accounts"
          })
        )
      end)

      stub_json(bypass, "POST", "/verification/account-holder-name", 200, %{result: "match"})

      assert {:ok, %{"result" => "match"}} =
               Verification.verify_account_holder_name(client, %{
                 "account_holder_name" => "Jane Doe",
                 "account_identifier" => %{
                   "type" => "sort_code_account_number",
                   "sort_code" => "040004",
                   "account_number" => "12345678"
                 }
               })
    end

    test "returns no_match result", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "data-tok2",
            expires_in: 3600,
            token_type: "Bearer",
            scope: "accounts"
          })
        )
      end)

      stub_json(bypass, "POST", "/verification/account-holder-name", 200, %{result: "no_match"})

      assert {:ok, %{"result" => "no_match"}} =
               Verification.verify_account_holder_name(client, %{
                 "account_holder_name" => "Wrong Name",
                 "account_identifier" => %{"type" => "iban", "iban" => "GB29NWBK60161331926819"}
               })
    end

    test "returns validation_error when account_holder_name is missing", %{client: client} do
      assert {:error, %Error{type: :validation_error}} =
               Verification.verify_account_holder_name(client, %{
                 "account_identifier" => %{"type" => "iban"}
               })
    end

    test "returns validation_error when account_holder_name is empty", %{client: client} do
      assert {:error, %Error{type: :validation_error}} =
               Verification.verify_account_holder_name(client, %{
                 "account_holder_name" => "",
                 "account_identifier" => %{"type" => "iban"}
               })
    end
  end

  describe "create_account_holder_verification/2" do
    test "returns pending verification", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "data-tok3",
            expires_in: 3600,
            token_type: "Bearer",
            scope: "accounts"
          })
        )
      end)

      stub_json(bypass, "POST", "/verification/account-holder", 201, %{
        id: "ahv-001",
        status: "pending"
      })

      assert {:ok, %{"id" => "ahv-001", "status" => "pending"}} =
               Verification.create_account_holder_verification(client, %{
                 "account_holder_name" => "Jane Doe",
                 "account_identifier" => %{"type" => "iban"}
               })
    end
  end

  describe "get_account_holder_verification/2" do
    test "returns completed verification", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            access_token: "data-tok4",
            expires_in: 3600,
            token_type: "Bearer",
            scope: "accounts"
          })
        )
      end)

      stub_json(bypass, "GET", "/verification/account-holder/ahv-001", 200, %{
        id: "ahv-001",
        status: "verified",
        match_score: 0.97
      })

      assert {:ok, %{"status" => "verified", "match_score" => 0.97}} =
               Verification.get_account_holder_verification(client, "ahv-001")
    end
  end
end
