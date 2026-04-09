defmodule TruelayerClient.HTTP do
  @moduledoc """
  Instrumented HTTP client wrapping `Req`.

  Handles:
    * JSON encoding/decoding
    * RFC 7807 problem+json error body parsing
    * `Tl-Trace-Id` and `Tl-Should-Retry` response header extraction
    * Telemetry events (`:start`, `:stop`, `:exception`)
    * TLS 1.2+ enforcement via transport options
  """

  alias TruelayerClient.{Config, Error}

  @user_agent "truelayer-client-elixir/1.0.0 (Req)"

  @doc "Build a `Req.Request` base client from a `TruelayerClient.Config`."
  @spec build_client(Config.t()) :: Req.Request.t()
  def build_client(%Config{request_timeout_ms: timeout_ms}) do
    Req.new(
      receive_timeout: timeout_ms,
      connect_options: [
        transport_opts: [
          versions: [:"tlsv1.2", :"tlsv1.3"],
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get()
        ]
      ],
      headers: %{
        "accept" => "application/json",
        "user-agent" => @user_agent
      },
      # SDK handles its own retry logic
      retry: false,
      # Req decodes JSON by default; keep it enabled
      decode_body: true
    )
  end

  @doc """
  Execute a JSON request.

  Returns `{:ok, decoded_body}` for 2xx responses or
  `{:error, %TruelayerClient.Error{}}` for errors.
  """
  @spec json_request(Req.Request.t(), Config.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def json_request(req, %Config{telemetry_prefix: prefix} = _config, opts) do
    method = Keyword.fetch!(opts, :method)
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, %{})
    body = Keyword.get(opts, :body)

    req_opts =
      [method: method, url: url, headers: headers]
      |> maybe_put(:json, body)

    start = System.monotonic_time()

    emit(prefix, :start, %{system_time: System.system_time()}, %{
      method: method,
      url: url
    })

    result =
      case Req.request(req, req_opts) do
        {:ok, %Req.Response{status: status, body: resp_body, headers: _resp_headers}}
        when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
          body_map = ensure_map(resp_body)
          {:error, Error.from_response(body_map, resp_headers, status)}

        {:error, %Req.TransportError{} = e} ->
          {:error, Error.network(e)}

        {:error, reason} ->
          {:error, Error.network(reason)}
      end

    duration = System.monotonic_time() - start

    case result do
      {:ok, _} ->
        emit(prefix, :stop, %{duration: duration}, %{
          method: method,
          url: url,
          status: :ok
        })

      {:error, %Error{status: status}} ->
        emit(prefix, :stop, %{duration: duration}, %{
          method: method,
          url: url,
          status: status
        })
    end

    result
  end

  @doc """
  Execute an `application/x-www-form-urlencoded` POST request.

  Used exclusively for OAuth2 token-endpoint calls.
  """
  @spec form_post(Req.Request.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def form_post(req, url, params) when is_binary(url) and is_map(params) do
    case Req.post(req, url: url, form: params) do
      {:ok, %Req.Response{status: status, body: body, headers: _headers}}
      when status in 200..299 ->
        {:ok, ensure_map(body)}

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:error, Error.from_response(ensure_map(body), headers, status)}

      {:error, %Req.TransportError{} = e} ->
        {:error, Error.network(e)}

      {:error, reason} ->
        {:error, Error.network(reason)}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp ensure_map(map) when is_map(map), do: map

  defp ensure_map(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp ensure_map(_), do: %{}

  defp emit(prefix, event, measurements, metadata) do
    :telemetry.execute(prefix ++ [:request, event], measurements, metadata)
  end
end
