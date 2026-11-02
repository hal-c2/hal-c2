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

  test "connected members are sent the table now and then, so one that missed a change learns it" do
    fp = String.duplicate("a", 64)
    entry = %{"id" => "m1", "fingerprint" => fp, "version" => HalC2.Upgrade.version()}
    {:ok, _} = Cluster.admit(entry)
    member = Cluster.mc_name("m1")
    stranger = Cluster.mc_name("stranger")
    # Connected before this process started, so no nodeup comes for them.
    Application.put_env(:hal_c2, :fake_connected, [member, stranger])
    send(Cluster, :gossip)
    _ = :sys.get_state(Cluster)

    assert_received {:sent, ^member, {:merge, %{"m1" => %{"fingerprint" => ^fp}}}}
    refute_received {:sent, ^stranger, _}
  end

  test "shared settings go to members and are taken up from members, until one is removed" do
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    on_exit(fn -> Application.delete_env(:hal_c2, :settings_check_ms) end)
    start_supervised!(HalC2.Settings)
    own = HalC2.Environment.id()

    fp = String.duplicate("a", 64)
    entry = %{"id" => "m1", "fingerprint" => fp, "version" => HalC2.Upgrade.version()}
    {:ok, _} = Cluster.admit(entry)
    member = Cluster.mc_name("m1")
    stranger = Cluster.mc_name("stranger")
    Application.put_env(:hal_c2, :fake_connected, [member, stranger])

    # A change here goes out at once, then with the rest of the gossip and on connect.
    {:ok, 1} = HalC2.Settings.put(%{"defaultRuntimeMode" => "full-access"}, 0)
    _ = :sys.get_state(Cluster)
    assert_received {:sent, ^member, {:settings, ^own, %{"defaultRuntimeMode" => %{"at" => at}}}}

    send(Cluster, :gossip)
    send(Cluster, {:nodeup, member})
    _ = :sys.get_state(Cluster)
    assert_received {:sent, ^member, {:settings, ^own, _}}
    assert_received {:sent, ^member, {:settings, ^own, _}}
    refute_received {:sent, ^stranger, {:settings, _, _}}

    newer = %{"defaultRuntimeMode" => %{"at" => at + 1, "by" => "m1", "value" => "auto"}}
    GenServer.cast(Cluster, {:settings, "stranger", newer})
    _ = :sys.get_state(Cluster)
    _ = :sys.get_state(HalC2.Settings)
    assert {%{"defaultRuntimeMode" => "full-access"}, 1} = HalC2.Settings.get()

    GenServer.cast(Cluster, {:settings, "m1", newer})
    _ = :sys.get_state(Cluster)
    _ = :sys.get_state(HalC2.Settings)
    assert {%{"defaultRuntimeMode" => "auto"}, 2} = HalC2.Settings.get()

    # Removing it cuts it off, as it did the stranger.
    :ok = Cluster.remove("m1")
    assert Transport.connected() == []
    flush_sent()

    newest = %{"defaultRuntimeMode" => %{"at" => at + 2, "by" => "m1", "value" => "full-access"}}
    GenServer.cast(Cluster, {:settings, "m1", newest})
    {:ok, _} = HalC2.Settings.put(%{"defaultRuntimeMode" => "approval-required"}, 2)
    send(Cluster, :gossip)
    _ = :sys.get_state(Cluster)
    _ = :sys.get_state(HalC2.Settings)

    assert {%{"defaultRuntimeMode" => "approval-required"}, 3} = HalC2.Settings.get()
    refute_received {:sent, _, {:settings, _, _}}
  end

  defp flush_sent do
    receive do
      {:sent, _, _} -> flush_sent()
    after
      0 -> :ok
    end
  end

  test "a cluster process that restarts still reports the port distribution listens on" do
    on_exit(fn -> :persistent_term.erase({HalC2.Cluster.Epmd, :listen_port}) end)
    # What distribution does as it starts, once per VM: the cluster process does not.
    {:ok, _} = HalC2.Cluster.Epmd.register_node(:hal_c2, 4999)
    stop_supervised!(Cluster)
    start_supervised!(Cluster)

    assert Cluster.status()["addresses"] == ["127.0.0.1:4999"]
    fp = String.duplicate("a", 64)
    entry = %{"id" => "m1", "fingerprint" => fp, "version" => HalC2.Upgrade.version()}
    assert {:ok, %{"port" => 4999}} = Cluster.admit(entry)
  end

  test "a cluster process updated in place from before keeps its port and starts gossip once" do
    on_exit(fn -> :persistent_term.erase({HalC2.Cluster.Epmd, :listen_port}) end)

    # What the version before kept: the port in the table and no gossip.
    :ets.insert(HalC2.Cluster, {:listen_port, 4998})

    :sys.replace_state(Cluster, fn state ->
      Process.cancel_timer(state.gossip)
      Map.delete(state, :gossip)
    end)

    update_in_place()
    assert HalC2.Cluster.Epmd.listen_port() == 4998
    %{gossip: timer} = :sys.get_state(Cluster)
    assert is_integer(Process.read_timer(timer))

    update_in_place()
    assert %{gossip: ^timer} = :sys.get_state(Cluster)
  end

  # What `HalC2.Hot` does for a process whose module changed.
  defp update_in_place do
    :ok = :sys.suspend(Cluster)
    :ok = :sys.change_code(Cluster, Cluster, nil, :hot)
    :ok = :sys.resume(Cluster)
  end
end
