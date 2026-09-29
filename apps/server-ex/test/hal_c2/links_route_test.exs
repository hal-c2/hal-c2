defmodule HalC2.Links.RouteTest do
  use ExUnit.Case, async: false

  alias HalC2.Web.Protocol

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!({Registry, keys: :unique, name: HalC2.Links.Registry})
    :ok
  end

  # A process registered under `id`, as a link's connection registers its environment
  # and the members of its cluster.
  defp register(id) do
    test = self()

    spawn_link(fn ->
      Registry.register(HalC2.Links.Registry, id, :member)
      send(test, :registered)
      Process.sleep(:infinity)
    end)

    assert_receive :registered
  end

  test "this node's own environment routes to this node" do
    assert HalC2.Links.route(HalC2.Environment.id()) == {:node, node()}
  end

  test "a cluster member's environment routes to that member" do
    :ok = HalC2.Shell.subscribe(self())
    descriptor = %{"environmentId" => "env-member", "label" => "member"}
    GenServer.cast(HalC2.Shell, {:peer_environment, :member@host, descriptor})
    assert_receive {:hal_c2_shell, {:environment, :member@host, _}}

    assert HalC2.Links.route("env-member") == {:node, :member@host}
  end

  test "an environment a link reaches routes through the link, and others are unknown" do
    register("env-linked")
    assert HalC2.Links.route("env-linked") == :link
    assert HalC2.Links.route("env-nowhere") == :unknown
  end

  test "a cluster member wins over a link that also reaches it" do
    :ok = HalC2.Shell.subscribe(self())
    GenServer.cast(HalC2.Shell, {:peer_environment, :both@host, %{"environmentId" => "env-both"}})
    assert_receive {:hal_c2_shell, {:environment, :both@host, _}}
    register("env-both")

    assert HalC2.Links.route("env-both") == {:node, :both@host}
  end

  test "a routed shape by environment keeps its environment once its node form decodes" do
    vcs = %{"type" => "vcs", "environment" => "env-any", "cwd" => "/repo"}
    frame = JSON.encode!(%{"t" => "sub", "id" => 1, "shape" => vcs})

    assert {:ok, {:sub, 1, {:environment, "env-any", ^vcs}, nil}} =
             Protocol.decode(frame, [node()])

    node_form =
      JSON.encode!(%{
        "t" => "sub",
        "id" => 1,
        "shape" => Map.put(Map.delete(vcs, "environment"), "node", Atom.to_string(node()))
      })

    assert {:ok, {:sub, 1, local, nil}} = Protocol.decode(node_form, [node()])
    assert Protocol.at_node(vcs, node()) == {:ok, local}
  end

  test "a routed shape by environment is refused when its node form is malformed" do
    frame =
      JSON.encode!(%{
        "t" => "sub",
        "id" => 1,
        "shape" => %{"type" => "vcs", "environment" => "env-any"}
      })

    assert {:error, _} = Protocol.decode(frame, [node()])
  end

  test "shapes about one node's host are not routed" do
    for type <- ~w(shell authAccess scheduledTasks devices serverUpdate providerInstall),
        do: refute(type in Protocol.routed())

    frame =
      JSON.encode!(%{
        "t" => "sub",
        "id" => 1,
        "shape" => %{"type" => "devices", "environment" => "env-any"}
      })

    assert {:error, _} = Protocol.decode(frame, [node()])
  end

  test "an unreachable environment's error names the environment and why" do
    assert HalC2.Links.unreachable("env-x", "unreachable", "x is unreachable") == %{
             "_tag" => "EnvironmentUnreachableError",
             "environmentId" => "env-x",
             "reason" => "unreachable",
             "message" => "x is unreachable"
           }
  end
end
