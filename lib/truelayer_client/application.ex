defmodule TruelayerClient.Application do
  @moduledoc """
  OTP Application for `TruelayerClient`.

  Starts the shared infrastructure required by all client instances.

  ## Supervision tree

      TruelayerClient.Application
      └── TruelayerClient.Auth.MemoryStore   (GenServer, owns ETS token table)

  If you supply a custom `:token_store` to `TruelayerClient.new/1`, the
  `MemoryStore` is still started but unused by that client instance.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      TruelayerClient.Auth.MemoryStore
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: TruelayerClient.Supervisor
    )
  end
end
