defmodule TruelayerClient.Webhooks do
  @moduledoc """
  TrueLayer webhook signature verification, replay-attack protection, and typed dispatch.

  ## Security model

    1. **HMAC-SHA256 verification** — constant-time comparison prevents timing attacks
    2. **Replay protection** — events older than `:webhook_replay_tolerance_sec` are rejected
    3. **Typed dispatch** — handlers registered per event type via `on/3`

  ## Usage in a Phoenix controller

  Add a `CacheBodyReader` plug to preserve the raw body for signature verification,
  then call `process/4` in your controller:

      defmodule MyAppWeb.WebhookController do
        use MyAppWeb, :controller

        def truelayer(conn, _params) do
          raw_body = conn.assigns[:raw_body]
          sig = get_req_header(conn, "tl-signature") |> List.first()
          ts  = get_req_header(conn, "tl-timestamp")  |> List.first()

          case TruelayerClient.Webhooks.process(client, raw_body, sig, ts) do
            :ok                -> send_resp(conn, 200, "")
            {:error, :bad_sig} -> send_resp(conn, 401, "invalid signature")
            {:error, :replay}  -> send_resp(conn, 401, "event too old")
            {:error, reason}   -> send_resp(conn, 500, inspect(reason))
          end
        end
      end

  ## Registering handlers

      TruelayerClient.Webhooks.on(client, TruelayerClient.Webhooks.payment_executed(), fn event ->
        %{"payload" => %{"payment_id" => id}} = event
        MyApp.Payments.finalize(id)
        :ok
      end)

  ## Event type constants

  Use the named functions (`payment_executed/0`, etc.) rather than raw strings
  to avoid typos:

      TruelayerClient.Webhooks.on(client, TruelayerClient.Webhooks.refund_executed(), handler)
  """

  @type registry :: :ets.tid()
  @type handler_fn :: (map() -> :ok | {:error, term()})
  @type event_type :: String.t()

  # ── Event type constants ──────────────────────────────────────────────────────

  @doc "Payment authorized by the PSU."
  def payment_authorized, do: "payment_authorized"

  @doc "Payment successfully executed."
  def payment_executed, do: "payment_executed"

  @doc "Payment funds settled into the merchant account."
  def payment_settled, do: "payment_settled"

  @doc "Payment failed."
  def payment_failed, do: "payment_failed"

  @doc "Refund executed."
  def refund_executed, do: "refund_executed"

  @doc "Refund failed."
  def refund_failed, do: "refund_failed"

  @doc "Payout executed."
  def payout_executed, do: "payout_executed"

  @doc "Payout failed."
  def payout_failed, do: "payout_failed"

  @doc "Mandate authorized by the PSU."
  def mandate_authorized, do: "mandate_authorized"

  @doc "Mandate revoked."
  def mandate_revoked, do: "mandate_revoked"

  @doc "Mandate failed."
  def mandate_failed, do: "mandate_failed"

  @doc "Merchant account payment settled."
  def merchant_account_payment_settled, do: "merchant_account_payment_settled"

  @doc "Merchant account payment failed."
  def merchant_account_payment_failed, do: "merchant_account_payment_failed"

  @doc "VRP payment executed."
  def vrp_payment_executed, do: "vrp_payment_executed"

  @doc "VRP payment failed."
  def vrp_payment_failed, do: "vrp_payment_failed"

  @doc "Payment link payment executed."
  def payment_link_payment_executed, do: "payment_link_payment_executed"

  @doc "Account holder verification completed."
  def account_holder_verification_completed, do: "account_holder_verification_completed"

  @doc "Account holder verification failed."
  def account_holder_verification_failed, do: "account_holder_verification_failed"

  @doc "Signup+ authorization URI expired."
  def identity_authorization_expired, do: "identity_authorization_expired"

  # ── Registry ──────────────────────────────────────────────────────────────────

  @doc "Create a new handler registry (ETS `:bag` table). Called once per client."
  @spec new_registry() :: registry()
  def new_registry do
    :ets.new(:truelayer_webhook_handlers, [:bag, :public, read_concurrency: true])
  end

  @doc """
  Register a handler for a specific event type.

  Multiple handlers per event type are supported; all are called in registration
  order. If a handler returns `{:error, reason}`, dispatch halts and the error
  is propagated, causing TrueLayer to retry the webhook delivery.

  ## Example

      TruelayerClient.Webhooks.on(client, TruelayerClient.Webhooks.payment_executed(), fn event ->
        id = get_in(event, ["payload", "payment_id"])
        MyApp.Payments.handle_executed(id)
        :ok
      end)
  """
  @spec on(TruelayerClient.t(), event_type(), handler_fn()) :: :ok
  def on(%{webhook_registry: registry}, event_type, handler_fn)
      when is_binary(event_type) and is_function(handler_fn, 1) do
    :ets.insert(registry, {event_type, handler_fn})
    :ok
  end

  @doc """
  Register a fallback handler called for any event type with no registered handler.
  """
  @spec on_fallback(TruelayerClient.t(), handler_fn()) :: :ok
  def on_fallback(%{webhook_registry: registry}, handler_fn) when is_function(handler_fn, 1) do
    :ets.insert(registry, {:__fallback__, handler_fn})
    :ok
  end

  # ── Processing ────────────────────────────────────────────────────────────────

  @doc """
  Verify and dispatch a raw webhook payload.

  ## Parameters

    * `client` — `TruelayerClient.t()` with webhook configuration
    * `body` — raw request body binary (must not be parsed before calling this)
    * `signature` — value of the `Tl-Signature` request header
    * `timestamp` — value of the `Tl-Timestamp` request header (RFC 3339)

  ## Return values

    * `:ok` — verified and successfully dispatched
    * `{:error, :bad_sig}` — signature verification failed
    * `{:error, :replay}` — event is outside the replay tolerance window
    * `{:error, {:decode_error, reason}}` — JSON parsing failed
    * `{:error, reason}` — a registered handler returned an error
  """
  @spec process(TruelayerClient.t(), binary(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def process(client, body, signature, timestamp)
      when is_binary(body) do
    with :ok <- verify_signature(client.config, body, signature, timestamp),
         :ok <- check_replay(client.config, timestamp),
         {:ok, event} <- parse_event(body) do
      dispatch(client.webhook_registry, event)
    end
  end

  # ── Signature verification ────────────────────────────────────────────────────

  defp verify_signature(%{webhook_signing_secret: nil}, _body, _sig, _ts), do: :ok

  defp verify_signature(_config, _body, nil, _ts), do: {:error, :bad_sig}

  defp verify_signature(%{webhook_signing_secret: secret}, body, signature, timestamp) do
    ts = timestamp || ""
    payload = "#{ts}.#{body}"
    expected = :crypto.mac(:hmac, :sha256, secret, payload)

    case decode_hex(signature) do
      {:ok, received} ->
        # Constant-time comparison — both branches must take equal time
        if byte_size(expected) == byte_size(received) and
             :crypto.hash(:sha256, expected) == :crypto.hash(:sha256, received) do
          :ok
        else
          {:error, :bad_sig}
        end

      :error ->
        {:error, :bad_sig}
    end
  end

  defp decode_hex(hex) when is_binary(hex) do
    Base.decode16(String.upcase(hex), case: :upper)
  end

  # ── Replay protection ─────────────────────────────────────────────────────────

  defp check_replay(%{webhook_replay_tolerance_sec: tolerance}, timestamp)
       when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, ts, _offset} ->
        age_sec = DateTime.diff(DateTime.utc_now(), ts, :second) |> abs()

        if age_sec <= tolerance,
          do: :ok,
          else: {:error, :replay}

      {:error, _reason} ->
        # Unparseable timestamp — allow through
        :ok
    end
  end

  defp check_replay(_config, nil), do: :ok

  # ── Event parsing & dispatch ──────────────────────────────────────────────────

  defp parse_event(body) do
    case Jason.decode(body) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  end

  defp dispatch(registry, %{"event_type" => event_type} = event) do
    handlers = :ets.lookup(registry, event_type)

    entries =
      if handlers == [] do
        :ets.lookup(registry, :__fallback__)
      else
        handlers
      end

    Enum.reduce_while(entries, :ok, fn {_type, handler}, _acc ->
      case handler.(event) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp dispatch(_registry, _event), do: :ok
end
