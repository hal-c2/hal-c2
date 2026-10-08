defmodule HalC2.Prop.ClusterTransport do
  @moduledoc """
  A `HalC2.Cluster.Distribution` stand-in for the cluster property test: no Erlang
  distribution, no ports. The members "connected" are a list the test sets with
  `connect/1`, and what `HalC2.Cluster` sends to a member arrives at the test process
  as `{:cluster_sent, mc, message}`, so a test that syncs with the cluster process has
  every message it sent in its mailbox.
  """

  @table __MODULE__

  @doc "Installs the fake for the calling process, which owns it and is sent to."
  def install do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public])
    :ets.insert(@table, [{:owner, self()}, {:connected, []}])
    Application.put_env(:hal_c2, :cluster_transport, __MODULE__)
  end

  @doc "Makes `mc` a connected member, as a handshake that succeeded would."
  def connect(mc), do: :ets.insert(@table, {:connected, Enum.uniq([mc | connected()])})

  def start(_dir, _id), do: :ok

  def connected, do: :ets.lookup_element(@table, :connected, 2)

  def disconnect(mc), do: :ets.insert(@table, {:connected, List.delete(connected(), mc)})

  def send(mc, message), do: Kernel.send(owner(), {:cluster_sent, mc, message})

  def version_changed(_dir) do
    :ets.insert(@table, {:connected, []})
    :ok
  end

  defp owner, do: :ets.lookup_element(@table, :owner, 2)
end
