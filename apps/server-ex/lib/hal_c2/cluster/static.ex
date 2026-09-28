defmodule HalC2.Cluster.Static do
  @moduledoc """
  Discovery strategy: the machines in `HAL_C2_PEERS`, comma separated, each `host` or
  `host:port`. A `name@host` from before clustering needed no names is read as `host`.
  """

  @behaviour HalC2.Cluster.Discovery

  @impl true
  def addresses do
    for peer <- String.split(System.get_env("HAL_C2_PEERS", ""), ",", trim: true),
        peer = peer |> String.trim() |> String.split("@") |> List.last(),
        peer != "",
        do: peer
  end
end
