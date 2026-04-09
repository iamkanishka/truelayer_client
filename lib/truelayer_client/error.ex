defmodule TruelayerClient.Error do
  @moduledoc """
  Structured error type for all TruelayerClient operations.

  Every public API function returns `{:ok, result}` or `{:error, %TruelayerClient.Error{}}`.

  ## Fields

    * `:type` - machine-readable error category atom
    * `:status` - HTTP status code (nil for non-HTTP errors)
    * `:trace_id` - `Tl-Trace-Id` header value for support
    * `:should_retry` - whether TrueLayer indicated `Tl-Should-Retry: true`
    * `:title` - RFC 7807 error title
    * `:detail` - RFC 7807 error detail
    * `:errors` - per-field validation errors (400 responses)
    * `:reason` - underlying reason for non-API errors

  ## Examples

      case TruelayerClient.Payments.get_payment(client, id) do
        {:ok, payment} -> payment
        {:error, %TruelayerClient.Error{type: :not_found}} -> nil
        {:error, %TruelayerClient.Error{trace_id: tid} = err} ->
          Logger.error("TrueLayer error trace=\#{tid}: \#{Exception.message(err)}")
      end
  """

  @type error_type ::
          :api_error
          | :auth_error
          | :validation_error
          | :not_found
          | :unauthorized
          | :forbidden
          | :conflict
          | :rate_limited
          | :server_error
          | :signing_required
          | :replay_attack
          | :signature_invalid
          | :network_error
          | :decode_error
          | :timeout
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          status: non_neg_integer() | nil,
          trace_id: String.t() | nil,
          should_retry: boolean(),
          title: String.t() | nil,
          detail: String.t() | nil,
          errors: [map()] | nil,
          reason: term()
        }

  defexception [
    :type,
    :status,
    :trace_id,
    :detail,
    :title,
    :errors,
    :reason,
    should_retry: false
  ]

  @impl true
  def message(%__MODULE__{status: nil, type: type, reason: reason}) do
    "TrueLayer [#{type}]: #{inspect(reason)}"
  end

  def message(%__MODULE__{status: status, title: title, detail: detail, trace_id: trace_id}) do
    "TrueLayer API #{status} #{title}: #{detail} (trace_id=#{trace_id})"
  end

  @doc "Build an `Error` from an API response."
  @spec from_response(map(), map(), non_neg_integer()) :: t()
  def from_response(body, headers, status) when is_integer(status) do
    %__MODULE__{
      type: classify_status(status),
      status: status,
      trace_id: normalised_header(headers, "tl-trace-id"),
      should_retry: normalised_header(headers, "tl-should-retry") == "true",
      title: body["title"],
      detail: body["detail"],
      errors: body["errors"],
      reason: nil
    }
  end

  @doc "Build a network/transport error."
  @spec network(term()) :: t()
  def network(reason) do
    %__MODULE__{type: :network_error, reason: reason, should_retry: true}
  end

  @doc "Build a signing-not-configured error."
  @spec signing_required() :: t()
  def signing_required do
    %__MODULE__{
      type: :signing_required,
      reason: "Request signing is required. Set :signing_key_pem and :signing_key_id.",
      should_retry: false
    }
  end

  @doc "Returns `true` when the error is safe to retry."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{should_retry: true}), do: true
  def retryable?(%__MODULE__{type: :network_error}), do: true
  def retryable?(%__MODULE__{type: :timeout}), do: true
  def retryable?(%__MODULE__{status: s}) when s in [429, 500, 502, 503, 504], do: true
  def retryable?(%__MODULE__{}), do: false

  @doc "Returns `true` for 404 Not Found errors."
  @spec not_found?(t()) :: boolean()
  def not_found?(%__MODULE__{status: 404}), do: true
  def not_found?(_), do: false

  @doc "Returns `true` for 401 Unauthorized errors."
  @spec unauthorized?(t()) :: boolean()
  def unauthorized?(%__MODULE__{status: 401}), do: true
  def unauthorized?(_), do: false

  @doc "Returns `true` for 429 Rate Limited errors."
  @spec rate_limited?(t()) :: boolean()
  def rate_limited?(%__MODULE__{status: 429}), do: true
  def rate_limited?(_), do: false

  @doc "Returns `true` for 409 Conflict errors."
  @spec conflict?(t()) :: boolean()
  def conflict?(%__MODULE__{status: 409}), do: true
  def conflict?(_), do: false

  @doc "Returns `true` for 5xx Server errors."
  @spec server_error?(t()) :: boolean()
  def server_error?(%__MODULE__{status: s}) when is_integer(s) and s >= 500, do: true
  def server_error?(_), do: false

  # ── Private ───────────────────────────────────────────────────────────────────

  defp classify_status(400), do: :validation_error
  defp classify_status(401), do: :unauthorized
  defp classify_status(403), do: :forbidden
  defp classify_status(404), do: :not_found
  defp classify_status(409), do: :conflict
  defp classify_status(422), do: :validation_error
  defp classify_status(429), do: :rate_limited
  defp classify_status(s) when s >= 500, do: :server_error
  defp classify_status(_), do: :api_error

  defp normalised_header(headers, key) when is_map(headers) do
    Map.get(headers, key) ||
      Map.get(headers, String.upcase(key))
  end

  defp normalised_header(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn {k, v} -> if String.downcase(k) == key, do: v end)
  end

  defp normalised_header(_, _), do: nil
end
