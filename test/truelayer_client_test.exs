defmodule TruelayerClientTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.{Config, Error}

  describe "new/1" do
    test "returns {:ok, client} with valid options" do
      assert {:ok, client} =
               TruelayerClient.new(client_id: "id", client_secret: "secret")

      assert %TruelayerClient{} = client
      assert client.config.client_id == "id"
      assert client.config.environment == :sandbox
    end

    test "defaults to :sandbox environment" do
      {:ok, client} = TruelayerClient.new(client_id: "id", client_secret: "s")
      assert client.config.environment == :sandbox
      assert client.config.api_url =~ "sandbox"
    end

    test "accepts :live environment" do
      {:ok, client} =
        TruelayerClient.new(client_id: "id", client_secret: "s", environment: :live)

      assert client.config.api_url == "https://api.truelayer.com"
      assert client.config.auth_url == "https://auth.truelayer.com"
    end

    test "returns error when client_id is missing" do
      assert {:error, %Error{type: :validation_error}} =
               TruelayerClient.new(client_secret: "s")
    end

    test "returns error when client_id is empty string" do
      assert {:error, %Error{type: :validation_error}} =
               TruelayerClient.new(client_id: "", client_secret: "s")
    end

    test "returns error when client_secret is missing" do
      assert {:error, %Error{type: :validation_error}} =
               TruelayerClient.new(client_id: "id")
    end

    test "returns error for unknown environment" do
      assert {:error, %Error{type: :validation_error}} =
               TruelayerClient.new(client_id: "id", client_secret: "s", environment: :production)
    end

    test "returns error for invalid signing key PEM" do
      assert {:error, %Error{type: :validation_error}} =
               TruelayerClient.new(
                 client_id: "id",
                 client_secret: "s",
                 signing_key_pem: "not-a-valid-pem",
                 signing_key_id: "kid"
               )
    end

    test "signer is nil when no signing key configured" do
      {:ok, client} = TruelayerClient.new(client_id: "id", client_secret: "s")
      assert is_nil(client.signer)
    end

    test "each call produces a unique store_id" do
      {:ok, c1} = TruelayerClient.new(client_id: "id", client_secret: "s")
      {:ok, c2} = TruelayerClient.new(client_id: "id", client_secret: "s")
      refute c1.store_id == c2.store_id
    end

    test "idem_table is a valid ETS table reference" do
      {:ok, client} = TruelayerClient.new(client_id: "id", client_secret: "s")
      assert :ets.info(client.idem_table) != :undefined
    end

    test "webhook_registry is a valid ETS table reference" do
      {:ok, client} = TruelayerClient.new(client_id: "id", client_secret: "s")
      assert :ets.info(client.webhook_registry) != :undefined
    end
  end

  describe "new!/1" do
    test "returns client on success" do
      assert %TruelayerClient{} = TruelayerClient.new!(client_id: "id", client_secret: "s")
    end

    test "raises TruelayerClient.Error on failure" do
      assert_raise TruelayerClient.Error, fn ->
        TruelayerClient.new!(client_id: "", client_secret: "s")
      end
    end
  end

  describe "environment/1" do
    test "returns :sandbox for sandbox clients" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s", environment: :sandbox)
      assert TruelayerClient.environment(c) == :sandbox
    end

    test "returns :live for live clients" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s", environment: :live)
      assert TruelayerClient.environment(c) == :live
    end
  end

  describe "sandbox?/1" do
    test "returns true for sandbox" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s", environment: :sandbox)
      assert TruelayerClient.sandbox?(c)
    end

    test "returns false for live" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s", environment: :live)
      refute TruelayerClient.sandbox?(c)
    end
  end
end
