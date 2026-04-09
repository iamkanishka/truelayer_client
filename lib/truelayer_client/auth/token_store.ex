defmodule TruelayerClient.Auth.TokenStore do
  @moduledoc """
  Behaviour for pluggable OAuth2 token storage backends.

  The default implementation (`TruelayerClient.Auth.MemoryStore`) stores tokens
  in a GenServer-managed ETS table — suitable for single-node deployments.

  For distributed systems implement this behaviour with a Redis or DynamoDB backend:

      defmodule MyApp.RedisTokenStore do
        @behaviour TruelayerClient.Auth.TokenStore

        @impl true
        def get(store_id, token_type) do
          case Redix.command(:redix, ["GET", key(store_id, token_type)]) do
            {:ok, nil}    -> {:ok, nil}
            {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
            {:error, _}   -> {:ok, nil}
          end
        end

        @impl true
        def put(store_id, token_type, token) do
          ttl = max(DateTime.diff(token.expires_at, DateTime.utc_now()), 1)
          Redix.command!(:redix, ["SETEX", key(store_id, token_type), ttl,
                                   :erlang.term_to_binary(token)])
          :ok
        end

        @impl true
        def delete(store_id, token_type) do
          Redix.command(:redix, ["DEL", key(store_id, token_type)])
          :ok
        end

        defp key(store_id, type), do: "truelayer:token:\#{store_id}:\#{type}"
      end

  Pass the module to `TruelayerClient.new/1`:

      {:ok, client} = TruelayerClient.new(
        client_id: "...",
        client_secret: "...",
        token_store: MyApp.RedisTokenStore
      )
  """

  alias TruelayerClient.Auth.Token

  @type store_id :: reference() | atom()
  @type token_type :: Token.token_type()

  @doc """
  Fetch a token by store_id and type.
  Returns `{:ok, %Token{}}`, `{:ok, nil}` if not found, or `{:error, reason}`.
  """
  @callback get(store_id(), token_type()) :: {:ok, Token.t() | nil} | {:error, term()}

  @doc """
  Persist a token. Returns `:ok` or `{:error, reason}`.
  """
  @callback put(store_id(), token_type(), Token.t()) :: :ok | {:error, term()}

  @doc """
  Remove a stored token. Always returns `:ok`.
  """
  @callback delete(store_id(), token_type()) :: :ok
end
