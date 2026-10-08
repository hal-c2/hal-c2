defmodule HalC2.ClusterServerTest do
  # `HalC2.Cluster` against a transport that stands in for Erlang distribution.
  use ExUnit.Case, async: false

  alias HalC2.Cluster

  @moduletag :tmp_dir

  defmodule Transport do
    @moduledoc false
    # Members "connected" are a list in the app env; sends go to the test process.
    def start(_dir, _id), do: :ok
    def connected, do: Application.get_env(:hal_c2, :fake_connected, [])
    def disconnect(mc), do: Application.put_env(:hal_c2, :fake_connected, connected() -- [mc])

    def send(mc, message),
      do: Kernel.send(Application.get_env(:hal_c2, :fake_owner), {:sent, mc, message})

    def version_changed(_dir), do: :ok
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :cluster_transport, Transport)
    Application.put_env(:hal_c2, :cluster_listen, "127.0.0.1")
    Application.put_env(:hal_c2, :fake_owner, self())

    on_exit(fn ->
      for key <- [:cluster_transport, :cluster_listen, :fake_owner, :fake_connected],
          do: Application.delete_env(:hal_c2, key)
    end)

    start_supervised!(Cluster)
    :ok
  end

  test "a machine that connects but is no member is cut off and not told the members" do
    stranger = Cluster.mc_name("stranger")
    Application.put_env(:hal_c2, :fake_connected, [stranger])
    send(Cluster, {:nodeup, stranger})
    _ = :sys.get_state(Cluster)

    assert Transport.connected() == []
    refute_received {:sent, ^stranger, _}

    # A member that connects is told them.
    fp = String.duplicate("a", 64)
    entry = %{"id" => "m1", "fingerprint" => fp, "version" => HalC2.Upgrade.version()}
    {:ok, _} = Cluster.admit(entry)
    member = Cluster.mc_name("m1")
    Application.put_env(:hal_c2, :fake_connected, [member])
    send(Cluster, {:nodeup, member})
    _ = :sys.get_state(Cluster)

    assert_received {:sent, ^member, {:merge, %{"m1" => %{"fingerprint" => ^fp}}}}
  end
end
