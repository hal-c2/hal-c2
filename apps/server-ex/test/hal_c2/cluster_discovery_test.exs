defmodule HalC2.ClusterDiscoveryTest do
  use ExUnit.Case, async: false

  alias HalC2.Cluster
  alias HalC2.Cluster.{Discovery, Epmd}

  @moduletag :capture_log

  test "an attempt that crashes ends it, and the next poll makes another" do
    Application.put_env(:hal_c2, :cluster_poll_interval, :timer.hours(1))
    on_exit(fn -> Application.delete_env(:hal_c2, :cluster_poll_interval) end)
    test = self()

    attempt = fn ->
      send(test, {:attempt, self()})
      receive do: (:crash -> exit(:boom))
    end

    discovery = start_supervised!({Discovery, attempt: attempt})
    assert_receive {:attempt, first}
    ref = Process.monitor(first)
    send(first, :crash)
    assert_receive {:DOWN, ^ref, :process, ^first, :boom}

    Discovery.poll()
    assert_receive {:attempt, second}
    assert second != first
    assert Process.whereis(Discovery) == discovery
  end

  describe "connect/3" do
    setup do
      :ets.new(Cluster, [:named_table, :public])
      :ok
    end

    test "a member found nowhere leaves no address behind to try first next time" do
      refute Discovery.connect("m1", ["10.0.0.1:5000"], fn _mc -> false end)
      assert Epmd.lookup(Cluster.host("m1")) == nil
    end

    test "a member that moved to the cluster port is reached at the host it had" do
      port = Cluster.dist_port()
      host = Cluster.host("m1")
      reach = fn _mc -> Epmd.lookup(host) == {{10, 0, 0, 1}, port} end

      assert Discovery.connect("m1", ["10.0.0.1:5000"], reach)
      assert Epmd.lookup(host) == {{10, 0, 0, 1}, port}
    end
  end
end
