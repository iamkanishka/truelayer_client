defmodule TruelayerClient.Auth.MemoryStore do
  @moduledoc """
  Default in-memory token store backed by ETS, supervised by a GenServer.

  Tokens are keyed by `{store_id, token_type}`, where each `TruelayerClient`
  instance receives a unique `store_id` (`make_ref/0`), providing complete
  isolation between multiple clients in the same node.

  ## Characteristics

    * O(1) reads via ETS with `read_concurrency: true`
    * Atomic `insert_new` for race-free concurrent writes
    * Tokens survive process crashes (ETS table is owned by the GenServer,
      not the calling process)
    * Data is lost on node restart — use a Redis-backed store for persistence

  Started automatically by `TruelayerClient.Application`.
  """

  use GenServer

  @behaviour TruelayerClient.Auth.TokenStore

  alias TruelayerClient.Auth.Token

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl TruelayerClient.Auth.TokenStore
  def get(store_id, token_type) do
    case :ets.lookup(__MODULE__, {store_id, token_type}) do
      [{{^store_id, ^token_type}, %Token{} = token}] -> {:ok, token}
      [] -> {:ok, nil}
    end
  end

  @impl TruelayerClient.Auth.TokenStore
  def put(store_id, token_type, %Token{} = token) do
    :ets.insert(__MODULE__, {{store_id, token_type}, token})
    :ok
  end

  @impl TruelayerClient.Auth.TokenStore
  def delete(store_id, token_type) do
    :ets.delete(__MODULE__, {store_id, token_type})
    :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :set, :public, read_concurrency: true])
    {:ok, :no_state}
  end
end
