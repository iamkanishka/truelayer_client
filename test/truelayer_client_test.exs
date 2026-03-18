defmodule TruelayerClientTest do
  use ExUnit.Case
  doctest TruelayerClient

  test "greets the world" do
    assert TruelayerClient.hello() == :world
  end
end
