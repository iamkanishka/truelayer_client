defmodule TruelayerClient.Auth do
  @moduledoc """
  TrueLayer Authentication Server client.

  Manages the full OAuth2 token lifecycle for both the Payments and Data APIs.

  ## Token isolation

  Payments tokens (`:payments`) and Data tokens (`:data`) are stored in separate
  slots in the token store. Each domain client requests the correct token type,
  ensuring a Data token is never used to authorise a payment.

  ## Automatic refresh

  `valid_token/2` automatically refreshes an expired token if a `:refresh_token`
  is available. For client-credentials flows (`client_credentials/3`), the SDK
  fetches a new token whenever the cached one has expired.

  ## Scopes

    * Payments scopes: `["payments"]`
    * Data scopes: `["accounts", "balance", "transactions", "cards", "info", "offline_access"]`
  """

  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{Config, Error, HTTP}

  @payments_scopes ["payments"]
  @data_scopes ["accounts", "balance", "transactions", "cards", "info", "offline_access"]

  @doc "Default scopes for Payments API client-credentials calls."
  @spec payments_scopes() :: [String.t()]
  def payments_scopes, do: @payments_scopes

  @doc "Default scopes for Data API user-delegated calls."
  @spec data_scopes() :: [String.t()]
  def data_scopes, do: @data_scopes

  # ── Authorization link ─────────────────────────────────────────────────────────

  @type auth_link_option ::
          {:scopes, [String.t()]}
          | {:state, String.t()}
          | {:nonce, String.t()}
          | {:providers, [String.t()]}
          | {:enable_mock, boolean()}

  @doc """
  Generate an OAuth2 authorization URL to redirect the user to for bank login.

  ## Options

    * `:scopes` - list of OAuth2 scopes (required)
    * `:state` - CSRF token (required — validate on redirect!)
    * `:nonce` - replay-protection nonce
    * `:providers` - whitelist of provider IDs shown to the user
    * `:enable_mock` - show the TrueLayer mock bank in Sandbox

  ## Example

      {:ok, url} = TruelayerClient.Auth.auth_link(client,
        scopes: TruelayerClient.Auth.payments_scopes(),
        state: csrf_token
      )
      # Redirect user to url
  """
  @spec auth_link(TruelayerClient.t(), [auth_link_option()]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def auth_link(client, opts) when is_list(opts) do
    %{config: config} = client

    with {:ok, scopes} <- require_opt(opts, :scopes),
         {:ok, state} <- require_opt(opts, :state),
         :ok <- require_redirect_uri(config) do
      params =
        %{
          "response_type" => "code",
          "client_id" => config.client_id,
          "redirect_uri" => config.redirect_uri,
          "scope" => Enum.join(scopes, " "),
          "state" => state
        }
        |> put_if_present("nonce", Keyword.get(opts, :nonce))
        |> put_if_present(
          "providers",
          opts |> Keyword.get(:providers, []) |> nonempty_join(" ")
        )
        |> put_if_true("enable_mock", Keyword.get(opts, :enable_mock, false))

      {:ok, "#{config.auth_url}/?#{URI.encode_query(params)}"}
    end
  end

  # ── Code exchange ──────────────────────────────────────────────────────────────

  @doc """
  Exchange an authorization code for an access token (POST /connect/token).

  Call this in your OAuth2 redirect handler with the `code` from query params.
  The token is cached automatically in the configured store.

  ## Example

      def callback(conn, %{"code" => code, "state" => state}) do
        verify_csrf!(state)
        {:ok, token} = TruelayerClient.Auth.exchange_code(client, code, :payments)
        # Store token association with user session
      end
  """
  @spec exchange_code(TruelayerClient.t(), String.t(), Token.token_type()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def exchange_code(%{config: config, store_id: store_id, http: http} = _client, code, token_type)
      when token_type in [:payments, :data] do
    params = %{
      "grant_type" => "authorization_code",
      "client_id" => config.client_id,
      "client_secret" => config.client_secret,
      "code" => code,
      "redirect_uri" => config.redirect_uri
    }

    with {:ok, resp} <- HTTP.form_post(http, "#{config.auth_url}/connect/token", params),
         token = Token.from_response(resp, token_type),
         :ok <- config.token_store.put(store_id, token_type, token) do
      {:ok, token}
    end
  end

  # ── Client credentials ─────────────────────────────────────────────────────────

  @doc """
  Obtain a client-credentials token (server-to-server, no user interaction).

  Results are cached in the token store. The cache is checked first; a new
  token is fetched only when the cached one has expired.

  This is the primary token source for Payments, Payouts, and Mandates clients.

  ## Example

      {:ok, token} = TruelayerClient.Auth.client_credentials(
        client,
        TruelayerClient.Auth.payments_scopes(),
        :payments
      )
  """
  @spec client_credentials(TruelayerClient.t(), [String.t()], Token.token_type()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def client_credentials(
        %{config: config, store_id: store_id, http: http},
        scopes,
        token_type
      )
      when token_type in [:payments, :data] do
    case config.token_store.get(store_id, token_type) do
      {:ok, %Token{} = token} ->
        if Token.expired?(token) do
          fetch_client_credentials(http, config, store_id, scopes, token_type)
        else
          {:ok, token}
        end

      {:ok, _} ->
        fetch_client_credentials(http, config, store_id, scopes, token_type)

      {:error, _} ->
        fetch_client_credentials(http, config, store_id, scopes, token_type)
    end
  end

  @doc """
  Refresh an access token using the stored refresh token.

  Called automatically by `valid_token/2` when the cached token is expired
  and has a refresh token available.
  """
  @spec refresh_token(TruelayerClient.t(), String.t(), Token.token_type()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def refresh_token(
        %{config: config, store_id: store_id, http: http},
        refresh_token_value,
        token_type
      ) do
    params = %{
      "grant_type" => "refresh_token",
      "client_id" => config.client_id,
      "client_secret" => config.client_secret,
      "refresh_token" => refresh_token_value
    }

    with {:ok, resp} <- HTTP.form_post(http, "#{config.auth_url}/connect/token", params),
         token = Token.from_response(resp, token_type),
         :ok <- config.token_store.put(store_id, token_type, token) do
      {:ok, token}
    end
  end

  @doc """
  Return a valid, non-expired token for `token_type`.

  If the stored token is expired and a refresh token is available, it is
  refreshed automatically. If no token is stored, returns `{:error, ...}`.

  Used by Data API domain clients before each API call.
  """
  @spec valid_token(TruelayerClient.t(), Token.token_type()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def valid_token(%{config: config, store_id: store_id} = client, token_type)
      when token_type in [:payments, :data] do
    case config.token_store.get(store_id, token_type) do
      {:ok, nil} ->
        {:error,
         %Error{
           type: :auth_error,
           reason: "No #{token_type} token stored. Complete an OAuth2 auth flow first.",
           should_retry: false
         }}

      {:ok, %Token{} = token} ->
        cond do
          not Token.expired?(token) ->
            {:ok, token}

          is_nil(token.refresh_token) ->
            {:error,
             %Error{
               type: :auth_error,
               reason: "#{token_type} token expired and no refresh token is available.",
               should_retry: false
             }}

          true ->
            refresh_token(client, token.refresh_token, token_type)
        end

      {:error, reason} ->
        {:error, %Error{type: :auth_error, reason: reason, should_retry: false}}
    end
  end

  @doc """
  Delete a stored credential (DELETE /connect/token/{credentials_id}).

  Requires a valid Data-scoped token.
  """
  @spec delete_credential(TruelayerClient.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_credential(client, credentials_id) do
    with {:ok, token} <- valid_token(client, :data),
         {:ok, _} <-
           HTTP.json_request(client.http, client.config,
             method: :delete,
             url: "#{client.config.auth_url}/connect/token/#{credentials_id}",
             headers: Token.bearer_header(token)
           ) do
      :ok
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────────

  defp fetch_client_credentials(http, config, store_id, scopes, token_type) do
    params = %{
      "grant_type" => "client_credentials",
      "client_id" => config.client_id,
      "client_secret" => config.client_secret,
      "scope" => Enum.join(scopes, " ")
    }

    with {:ok, resp} <- HTTP.form_post(http, "#{config.auth_url}/connect/token", params),
         token = Token.from_response(resp, token_type),
         :ok <- config.token_store.put(store_id, token_type, token) do
      {:ok, token}
    end
  end

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when val not in [nil, [], ""] -> {:ok, val}
      {:ok, _} -> {:error, validation("#{key} must not be empty")}
      :error -> {:error, validation("#{key} is required")}
    end
  end

  defp require_redirect_uri(%Config{redirect_uri: nil}) do
    {:error, validation(":redirect_uri is required for authorization code flow")}
  end

  defp require_redirect_uri(_config), do: :ok

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, val), do: Map.put(map, key, val)

  defp put_if_true(map, _key, false), do: map
  defp put_if_true(map, key, true), do: Map.put(map, key, "true")

  defp nonempty_join([], _sep), do: nil
  defp nonempty_join(list, sep), do: Enum.join(list, sep)

  defp validation(msg) do
    %Error{type: :validation_error, reason: msg, should_retry: false}
  end
end
