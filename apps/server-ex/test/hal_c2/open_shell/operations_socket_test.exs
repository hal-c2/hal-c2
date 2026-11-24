defmodule HalC2.OpenShell.OperationsSocketTest do
  # The MC's home, its auth and the operations' runner are the app's.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell.Operations
  alias HalC2.Test.FakeOpenShell
  alias HalC2.Test.Mc
  alias HalC2.Test.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    mc = Mc.start(dir)
    test = self()

    # The status reads a machine with no OpenShell, asking a fake service manager.
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    Storage.fake_service_manager(bin)

    FakeOpenShell.put_env(
      openshell_facts: %{os: :darwin, arch: "x86_64", runtime: nil},
      service_platform: {:unix, :linux},
      service_user_home: Path.join(dir, "user"),
      systemctl_command: Path.join(bin, "systemctl"),
      loginctl_command: Path.join(bin, "loginctl"),
      launchctl_command: Path.join(bin, "launchctl")
    )

    # Stands in for `HalC2.OpenShell.Command.run/2`: nothing is installed.
    runner = fn operation, opts ->
      send(test, {:started, operation, Keyword.delete(opts, :progress)})
      send(test, {:runner, self()})
      opts[:progress].("Starting the gateway")

      receive do
        {:answer, answer} -> answer
      end
    end

    Mc.ensure({Operations, runner: runner})
    %{mc: mc}
  end

  defp shape, do: %{"type" => "openShell", "mc" => Atom.to_string(node())}

  test "a session that cannot manage the machine is refused, and its status says why", %{mc: mc} do
    for scopes <- [
          HalC2.Auth.standard_scopes(),
          ["orchestration:read", "access:write"],
          ["orchestration:read", "terminal:operate"]
        ] do
      client = Mc.connect_as(mc, Mc.pair(scopes, "Without both"))
      missing = Enum.find(Operations.scopes(), &(&1 not in scopes))

      assert {{:error, _,
               %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => ^missing}}, client} =
               Mc.call(client, mc.environment, "server.runOpenShellOperation", %{
                 "operation" => "install"
               })

      if "orchestration:read" in scopes do
        {status, _} = Mc.call!(client, mc.environment, "server.getOpenShellStatus")
        assert %{"canManage" => false, "manageReason" => reason} = status
        assert reason =~ missing
      end
    end

    refute_received {:started, _, _}
  end

  test "a session that can runs one, and every subscriber sees it through", %{mc: mc} do
    scopes = ["orchestration:read", "access:write", "terminal:operate"]
    client = Mc.connect_as(mc, Mc.pair(scopes, "Manager"))
    watcher = Mc.connect_as(mc, Mc.pair(["orchestration:read"], "Watcher"))

    {status, client} = Mc.call!(client, mc.environment, "server.getOpenShellStatus")
    assert %{"canManage" => true, "manageReason" => nil, "actions" => _} = status

    # The watcher may read, not run. (A call skips the frames before its reply.)
    assert {{:error, _, %{"_tag" => "EnvironmentScopeRequiredError"}}, watcher} =
             Mc.call(watcher, mc.environment, "server.runOpenShellOperation", %{
               "operation" => "check"
             })

    watcher = Mc.sub(watcher, 1, shape())

    {%{"operation" => %{"running" => false, "operation" => nil}}, watcher} =
      Mc.await(watcher, &(&1["t"] == "openShell"))

    {running, client} =
      Mc.call!(client, mc.environment, "server.runOpenShellOperation", %{
        "operation" => "uninstall",
        "drain" => true
      })

    assert %{"operation" => "uninstall", "running" => true} = running
    assert_receive {:started, :uninstall, [drain: true]}

    assert {{:error, _, %{"_tag" => "ServerOpenShellOperationError", "reason" => "busy"}}, _} =
             Mc.call(client, mc.environment, "server.runOpenShellOperation", %{
               "operation" => "check"
             })

    {%{"operation" => %{"steps" => ["Starting the gateway"]}}, watcher} =
      Mc.await(watcher, &(&1["t"] == "openShell" and &1["operation"]["steps"] != []))

    assert_receive {:runner, runner}
    send(runner, {:answer, {:ok, "OpenShell removed."}})

    {%{"operation" => operation}, _} =
      Mc.await(watcher, &(&1["t"] == "openShell" and &1["operation"]["result"] != nil))

    assert %{"running" => false, "result" => %{"ok" => true, "message" => "OpenShell removed."}} =
             operation
  end

  test "arguments it does not take are refused before anything runs", %{mc: mc} do
    client = Mc.connect(mc)

    assert {{:error, _, %{"_tag" => "ServerOpenShellOperationError", "reason" => "invalid"}}, _} =
             Mc.call(client, mc.environment, "server.runOpenShellOperation", %{
               "operation" => "install",
               "archive" => "/home/user/openshell.tar.gz"
             })

    refute_received {:started, _, _}
  end
end
