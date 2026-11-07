defmodule HalC2.Test.ClusterTable do
  @moduledoc """
  A `HalC2.Cluster.Distribution` stand-in for scenarios whose machines are `:peer`s
  connected without TLS distribution (`HalC2.Test.Machines`): with it `HalC2.Cluster`
  runs, keeps a member table and answers for it, and leaves the connections, and what
  it would send to members, alone.
  """

  def start(_dir, _id), do: :ok
  def connected, do: []
  def disconnect(_mc), do: :ok
  def send(_mc, _message), do: :ok
  def version_changed(_dir), do: :ok
end
