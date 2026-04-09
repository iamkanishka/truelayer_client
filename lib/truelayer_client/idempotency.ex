defmodule TruelayerClient.Idempotency do
  @moduledoc """
  Thread-safe idempotency key manager backed by ETS.

  The same `operation_id` always yields the same key until `release/2` is
  called, ensuring POST retries always send an identical `Idempotency-Key`
  header — preventing duplicate payments or payouts.

  Each `TruelayerClient` instance owns a separate ETS table created at
  construction time, so multiple clients on the same node are fully isolated.
  """

  @type table :: :ets.tid()

  @doc "Create a new ETS table for idempotency keys. Called once per client."
  @spec new_table() :: table()
  def new_table do
    :ets.new(:truelayer_idempotency, [:set, :public, read_concurrency: true])
  end

  @doc """
  Return the idempotency key for `operation_id`.

  Creates a new UUID-shaped key on first call and returns the same key on
  every subsequent call with the same `operation_id` (until `release/2`).
  Safe to call concurrently from multiple processes.
  """
  @spec key_for(table(), String.t()) :: String.t()
  def key_for(table, operation_id) when is_binary(operation_id) do
    case :ets.lookup(table, operation_id) do
      [{^operation_id, key}] ->
        key

      [] ->
        candidate = new_key()

        # :ets.insert_new/2 is atomic; if a concurrent writer won, use their key.
        if :ets.insert_new(table, {operation_id, candidate}) do
          candidate
        else
          [{^operation_id, existing}] = :ets.lookup(table, operation_id)
          existing
        end
    end
  end

  @doc """
  Remove the stored key for `operation_id` after a confirmed successful response.

  Subsequent calls to `key_for/2` with the same `operation_id` will generate
  a fresh key, making re-use of operation IDs safe after confirmed success.
  """
  @spec release(table(), String.t()) :: :ok
  def release(table, operation_id) do
    :ets.delete(table, operation_id)
    :ok
  end

  @doc "Generate a random UUID v4-shaped key using `:crypto.strong_rand_bytes/1`."
  @spec new_key() :: String.t()
  def new_key do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c,
      Bitwise.bor(0x8000, Bitwise.band(d, 0x3FFF)),
      e
    ])
    |> IO.iodata_to_binary()
  end
end
