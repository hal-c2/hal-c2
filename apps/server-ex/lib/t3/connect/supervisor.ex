defmodule T3.Connect.Supervisor do
  @moduledoc """
  T3 Connect's processes: the managed tunnel, the startup link, and the agent
  activity publisher. The link stops before the tunnel so it can release it.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([T3.Connect.Tunnel, T3.Connect.Link, T3.Connect.Publisher],
      strategy: :one_for_one
    )
  end
end
