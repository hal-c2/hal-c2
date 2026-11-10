defmodule HalC2.OpenShell.BrokerTest do
  # Where a review sandbox reaches the report broker (#1412) when nothing configures it.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Broker
  alias HalC2.Test.FakeOpenShell

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    FakeOpenShell.put_env(home: Path.join(dir, "mc"), openshell_broker: [bind: "127.0.0.1"])
    :ok
  end

  # Docker's supervisors reach the machine as `host.docker.internal` on either of the
  # networks `HalC2.OpenShell.Platform` picks, the Mac's bridge included.
  for network <- ["host", "bridge"] do
    test "on Docker with supervisors on the #{network} network a sandbox dials host.docker.internal" do
      OpenShell.put_state(%{"driver" => "docker", "network" => unquote(network)})
      assert %{host: "host.docker.internal", url: url} = listen!()
      assert url =~ ~r"^http://host\.docker\.internal:\d+/report$"
    end
  end

  # Its agent dials the fully-qualified name, which the sandbox's resolver answers
  # with the way through its proxy; the policy's endpoint names the bare host.
  test "on Podman a sandbox dials host.containers.internal by its fully-qualified name" do
    OpenShell.put_state(%{"driver" => "podman"})
    assert %{host: "host.containers.internal", url: url} = listen!()
    assert url =~ ~r"^http://host\.containers\.internal\.:\d+/report$"
  end

  defp listen! do
    {:ok, at, pid} = Broker.listen()
    :ok = Supervisor.stop(pid)
    at
  end
end
