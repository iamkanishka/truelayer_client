defmodule TruelayerClient.WebhooksTest do
  use ExUnit.Case, async: true

  import TruelayerClient.Factory

  alias TruelayerClient.Webhooks

  @secret "test-hmac-secret-key"

  setup do
    bypass = Bypass.open()
    client = client(bypass, webhook_signing_secret: @secret, webhook_replay_tolerance_sec: 300)
    {:ok, client: client}
  end

  defp fresh_ts, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ── Signature verification ────────────────────────────────────────────────────

  describe "process/4 — signature verification" do
    test "accepts a valid HMAC signature", %{client: client} do
      body = webhook_body("payment_executed", %{payment_id: "pay_001"})
      ts = fresh_ts()
      sig = sign_webhook(body, ts, @secret)

      assert :ok = Webhooks.process(client, body, sig, ts)
    end

    test "rejects an invalid signature", %{client: client} do
      body = webhook_body("payment_executed")
      ts = fresh_ts()

      assert {:error, :bad_sig} = Webhooks.process(client, body, "deadbeef00000000", ts)
    end

    test "rejects a nil signature when secret is configured", %{client: client} do
      body = webhook_body("payment_executed")
      assert {:error, :bad_sig} = Webhooks.process(client, body, nil, fresh_ts())
    end

    test "rejects a tampered body", %{client: client} do
      original = webhook_body("payment_executed", %{payment_id: "pay_001"})
      ts = fresh_ts()
      sig = sign_webhook(original, ts, @secret)

      tampered = webhook_body("payment_executed", %{payment_id: "pay_EVIL"})
      assert {:error, :bad_sig} = Webhooks.process(client, tampered, sig, ts)
    end

    test "skips verification when no secret configured" do
      {:ok, c} = TruelayerClient.new(client_id: "id", client_secret: "s")
      body = webhook_body("payment_executed")
      assert :ok = Webhooks.process(c, body, nil, nil)
    end
  end

  # ── Replay protection ─────────────────────────────────────────────────────────

  describe "process/4 — replay protection" do
    test "accepts events within the tolerance window", %{client: client} do
      body = webhook_body("payment_executed")
      ts = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      sig = sign_webhook(body, ts, @secret)

      assert :ok = Webhooks.process(client, body, sig, ts)
    end

    test "rejects events older than the tolerance window", %{client: client} do
      body = webhook_body("payment_executed")
      ts = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_iso8601()
      sig = sign_webhook(body, ts, @secret)

      assert {:error, :replay} = Webhooks.process(client, body, sig, ts)
    end
  end

  # ── Handler dispatch ──────────────────────────────────────────────────────────

  describe "on/3 — dispatch" do
    test "dispatches event to registered handler", %{client: client} do
      test_pid = self()

      Webhooks.on(client, Webhooks.payment_executed(), fn event ->
        send(test_pid, {:received, event["event_type"]})
        :ok
      end)

      body = webhook_body(Webhooks.payment_executed(), %{payment_id: "pay_abc"})
      ts = fresh_ts()
      sig = sign_webhook(body, ts, @secret)

      assert :ok = Webhooks.process(client, body, sig, ts)
      assert_receive {:received, "payment_executed"}
    end

    test "calls all handlers registered for the same event type", %{client: client} do
      test_pid = self()

      for i <- 1..3 do
        Webhooks.on(client, Webhooks.payment_settled(), fn _ ->
          send(test_pid, {:called, i})
          :ok
        end)
      end

      body = webhook_body(Webhooks.payment_settled())
      ts = fresh_ts()
      sig = sign_webhook(body, ts, @secret)

      assert :ok = Webhooks.process(client, body, sig, ts)
      assert_receive {:called, 1}
      assert_receive {:called, 2}
      assert_receive {:called, 3}
    end

    test "calls fallback handler for unregistered event type", %{client: client} do
      test_pid = self()

      Webhooks.on_fallback(client, fn event ->
        send(test_pid, {:fallback, event["event_type"]})
        :ok
      end)

      body = webhook_body("brand_new_event_type_2099")
      ts = fresh_ts()
      sig = sign_webhook(body, ts, @secret)

      assert :ok = Webhooks.process(client, body, sig, ts)
      assert_receive {:fallback, "brand_new_event_type_2099"}
    end

    test "returns :ok with no handler and no fallback", %{client: client} do
      body = webhook_body("unhandled_event")
      ts = fresh_ts()
      sig = sign_webhook(body, ts, @secret)

      assert :ok = Webhooks.process(client, body, sig, ts)
    end

    test "propagates handler error and stops dispatch", %{client: client} do
      test_pid = self()

      Webhooks.on(client, Webhooks.payment_failed(), fn _event ->
        {:error, :processing_failed}
      end)

      Webhooks.on(client, Webhooks.payment_failed(), fn _event ->
        send(test_pid, :second_handler_called)
        :ok
      end)

      body = webhook_body(Webhooks.payment_failed(), %{payment_id: "pay_err"})
      ts = fresh_ts()
      sig = sign_webhook(body, ts, @secret)

      assert {:error, :processing_failed} = Webhooks.process(client, body, sig, ts)
      refute_receive :second_handler_called, 100
    end
  end

  # ── Event type constants ──────────────────────────────────────────────────────

  describe "event type constants" do
    test "all constants return unique binary strings" do
      types = [
        Webhooks.payment_authorized(),
        Webhooks.payment_executed(),
        Webhooks.payment_settled(),
        Webhooks.payment_failed(),
        Webhooks.refund_executed(),
        Webhooks.refund_failed(),
        Webhooks.payout_executed(),
        Webhooks.payout_failed(),
        Webhooks.mandate_authorized(),
        Webhooks.mandate_revoked(),
        Webhooks.mandate_failed(),
        Webhooks.merchant_account_payment_settled(),
        Webhooks.merchant_account_payment_failed(),
        Webhooks.vrp_payment_executed(),
        Webhooks.vrp_payment_failed(),
        Webhooks.payment_link_payment_executed(),
        Webhooks.account_holder_verification_completed(),
        Webhooks.account_holder_verification_failed(),
        Webhooks.identity_authorization_expired()
      ]

      Enum.each(types, fn t ->
        assert is_binary(t), "Expected #{inspect(t)} to be a binary string"
      end)

      assert Enum.uniq(types) == types, "Event type constants must all be unique"
    end
  end
end
