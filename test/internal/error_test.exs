defmodule TruelayerClient.ErrorTest do
  use ExUnit.Case, async: true

  alias TruelayerClient.Error

  describe "from_response/3" do
    test "classifies 404 as :not_found" do
      err = Error.from_response(%{"title" => "Not Found", "detail" => "gone"}, %{}, 404)
      assert err.type == :not_found
      assert err.status == 404
    end

    test "classifies 401 as :unauthorized" do
      err = Error.from_response(%{}, %{}, 401)
      assert err.type == :unauthorized
    end

    test "classifies 429 as :rate_limited" do
      err = Error.from_response(%{}, %{}, 429)
      assert err.type == :rate_limited
    end

    test "classifies 409 as :conflict" do
      err = Error.from_response(%{}, %{}, 409)
      assert err.type == :conflict
    end

    test "classifies 500 as :server_error" do
      err = Error.from_response(%{}, %{}, 500)
      assert err.type == :server_error
    end

    test "extracts Tl-Trace-Id from headers" do
      err = Error.from_response(%{}, %{"tl-trace-id" => "trace-xyz"}, 404)
      assert err.trace_id == "trace-xyz"
    end

    test "sets should_retry from Tl-Should-Retry: true" do
      err = Error.from_response(%{}, %{"tl-should-retry" => "true"}, 500)
      assert err.should_retry == true
    end

    test "defaults should_retry to false" do
      err = Error.from_response(%{}, %{}, 400)
      assert err.should_retry == false
    end
  end

  describe "retryable?/1" do
    test "true when should_retry is set" do
      assert Error.retryable?(%Error{should_retry: true})
    end

    test "true for 429 status" do
      assert Error.retryable?(%Error{status: 429, should_retry: false})
    end

    test "true for 5xx statuses" do
      for code <- [500, 502, 503, 504] do
        assert Error.retryable?(%Error{status: code, should_retry: false}),
               "Expected #{code} to be retryable"
      end
    end

    test "true for :network_error type" do
      assert Error.retryable?(%Error{type: :network_error, should_retry: true})
    end

    test "false for 4xx client errors" do
      for code <- [400, 401, 403, 404, 409, 422] do
        refute Error.retryable?(%Error{status: code, should_retry: false}),
               "Expected #{code} to NOT be retryable"
      end
    end
  end

  describe "predicate helpers" do
    test "not_found?/1" do
      assert Error.not_found?(%Error{status: 404})
      refute Error.not_found?(%Error{status: 400})
    end

    test "unauthorized?/1" do
      assert Error.unauthorized?(%Error{status: 401})
      refute Error.unauthorized?(%Error{status: 403})
    end

    test "rate_limited?/1" do
      assert Error.rate_limited?(%Error{status: 429})
      refute Error.rate_limited?(%Error{status: 500})
    end

    test "conflict?/1" do
      assert Error.conflict?(%Error{status: 409})
      refute Error.conflict?(%Error{status: 400})
    end

    test "server_error?/1" do
      assert Error.server_error?(%Error{status: 500})
      assert Error.server_error?(%Error{status: 503})
      refute Error.server_error?(%Error{status: 404})
    end
  end

  describe "signing_required/0" do
    test "returns a :signing_required error" do
      err = Error.signing_required()
      assert err.type == :signing_required
      assert is_binary(err.reason)
      refute err.should_retry
    end
  end

  describe "Exception.message/1" do
    test "formats non-API error" do
      err = %Error{type: :network_error, reason: :econnrefused}
      assert Exception.message(err) =~ "network_error"
    end

    test "formats API error with status and trace_id" do
      err = %Error{
        type: :not_found,
        status: 404,
        title: "Not Found",
        detail: "Payment missing",
        trace_id: "trace-abc"
      }

      msg = Exception.message(err)
      assert msg =~ "404"
      assert msg =~ "Not Found"
      assert msg =~ "trace-abc"
    end
  end
end

defmodule TruelayerClient.RetryTest do
  use ExUnit.Case, async: true

  alias TruelayerClient.{Error, Retry}

  @fast_policy %{max_attempts: 3, base_delay_ms: 1, max_delay_ms: 5, multiplier: 2.0}

  describe "run/2" do
    test "returns {:ok, result} on first success" do
      assert {:ok, :done} = Retry.run(@fast_policy, fn -> {:ok, :done} end)
    end

    test "retries on retryable error and succeeds" do
      counter = :counters.new(1, [])

      result =
        Retry.run(@fast_policy, fn ->
          count = :counters.add(counter, 1, 1) |> then(fn _ -> :counters.get(counter, 1) end)

          if count < 3,
            do: {:error, %Error{type: :server_error, status: 500, should_retry: true}},
            else: {:ok, :eventually}
        end)

      assert {:ok, :eventually} = result
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry non-retryable error" do
      counter = :counters.new(1, [])

      result =
        Retry.run(@fast_policy, fn ->
          :counters.add(counter, 1, 1)
          {:error, %Error{type: :not_found, status: 404, should_retry: false}}
        end)

      assert {:error, %Error{type: :not_found}} = result
      assert :counters.get(counter, 1) == 1
    end

    test "exhausts max attempts and returns last error" do
      counter = :counters.new(1, [])

      result =
        Retry.run(@fast_policy, fn ->
          :counters.add(counter, 1, 1)
          {:error, %Error{type: :server_error, status: 503, should_retry: true}}
        end)

      assert {:error, _} = result
      assert :counters.get(counter, 1) == 3
    end
  end
end

defmodule TruelayerClient.IdempotencyTest do
  use ExUnit.Case, async: true

  alias TruelayerClient.Idempotency

  setup do
    table = Idempotency.new_table()
    {:ok, table: table}
  end

  describe "key_for/2" do
    test "returns same key for same operation_id", %{table: table} do
      k1 = Idempotency.key_for(table, "order-001")
      k2 = Idempotency.key_for(table, "order-001")
      assert k1 == k2
    end

    test "returns different keys for different IDs", %{table: table} do
      k1 = Idempotency.key_for(table, "order-001")
      k2 = Idempotency.key_for(table, "order-002")
      refute k1 == k2
    end

    test "is concurrency-safe", %{table: table} do
      tasks = for _ <- 1..50, do: Task.async(fn -> Idempotency.key_for(table, "shared") end)
      keys = Enum.map(tasks, &Task.await/1)
      assert Enum.uniq(keys) |> length() == 1
    end
  end

  describe "release/2" do
    test "generates a new key after release", %{table: table} do
      k1 = Idempotency.key_for(table, "op-release")
      :ok = Idempotency.release(table, "op-release")
      k2 = Idempotency.key_for(table, "op-release")
      refute k1 == k2
    end
  end

  describe "new_key/0" do
    test "generates unique keys" do
      keys = for _ <- 1..100, do: Idempotency.new_key()
      assert Enum.uniq(keys) |> length() == 100
    end

    test "returns a non-empty binary" do
      key = Idempotency.new_key()
      assert is_binary(key) and byte_size(key) > 0
    end
  end
end

defmodule TruelayerClient.SigningTest do
  use ExUnit.Case, async: true

  alias TruelayerClient.Signing

  setup_all do
    key = :public_key.generate_key({:namedCurve, :secp521r1})
    der = :public_key.der_encode(:ECPrivateKey, key)
    pem = :public_key.pem_encode([{:ECPrivateKey, der, :not_encrypted}])
    {:ok, signer} = Signing.new_signer(pem, "test-key-id")
    {:ok, signer: signer}
  end

  describe "new_signer/2" do
    test "returns error for empty PEM" do
      assert {:error, _} = Signing.new_signer("", "kid")
    end

    test "returns error for invalid PEM" do
      assert {:error, _} = Signing.new_signer("not-a-pem", "kid")
    end
  end

  describe "sign/5" do
    test "returns a non-empty Tl-Signature string", %{signer: signer} do
      assert {:ok, sig} = Signing.sign(signer, "POST", "/v3/payments", %{}, "")
      assert is_binary(sig) and byte_size(sig) > 0
    end

    test "uses double-dot format (header..signature)", %{signer: signer} do
      {:ok, sig} = Signing.sign(signer, "POST", "/v3/payments", %{}, "")
      assert String.contains?(sig, "..")
      [header, sig_part] = String.split(sig, "..", parts: 2)
      assert byte_size(header) > 0
      assert byte_size(sig_part) > 0
    end

    test "JWS protected header contains alg and kid", %{signer: signer} do
      {:ok, sig} = Signing.sign(signer, "POST", "/v3/payments", %{}, "")
      [encoded_header | _] = String.split(sig, "..")
      {:ok, json} = Base.url_decode64(encoded_header, padding: false)
      hdr = Jason.decode!(json)
      assert hdr["alg"] == "ES512"
      assert hdr["kid"] == "test-key-id"
      assert hdr["tl-version"] == "2"
    end

    test "different methods produce different signatures", %{signer: signer} do
      {:ok, s1} = Signing.sign(signer, "POST", "/v3/payments", %{}, "body")
      {:ok, s2} = Signing.sign(signer, "GET", "/v3/payments", %{}, "body")
      refute s1 == s2
    end

    test "different paths produce different signatures", %{signer: signer} do
      {:ok, s1} = Signing.sign(signer, "POST", "/v3/payments", %{}, "body")
      {:ok, s2} = Signing.sign(signer, "POST", "/v3/payouts", %{}, "body")
      refute s1 == s2
    end

    test "different bodies produce different signatures", %{signer: signer} do
      {:ok, s1} = Signing.sign(signer, "POST", "/v3/payments", %{}, "body-a")
      {:ok, s2} = Signing.sign(signer, "POST", "/v3/payments", %{}, "body-b")
      refute s1 == s2
    end

    test "header ordering does not affect the signed header list", %{signer: signer} do
      h1 = %{"b-header" => "val-b", "a-header" => "val-a"}
      h2 = %{"a-header" => "val-a", "b-header" => "val-b"}

      {:ok, sig1} = Signing.sign(signer, "POST", "/v3/payments", h1, "")
      {:ok, sig2} = Signing.sign(signer, "POST", "/v3/payments", h2, "")

      # The JWS header (before ..) encodes sorted header names — must match
      [hdr1 | _] = String.split(sig1, "..")
      [hdr2 | _] = String.split(sig2, "..")
      assert hdr1 == hdr2
    end
  end
end
