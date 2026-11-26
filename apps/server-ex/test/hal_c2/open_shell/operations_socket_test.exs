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

  test "a session that can runs one, and every subscriber sees it through, the detail only it",
       %{mc: mc} do
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
        "drain" => ["review-1"]
      })

    assert %{"operation" => "uninstall", "running" => true} = running
    assert_receive {:started, :uninstall, [drain: ["review-1"]]}
    client = Mc.sub(client, 2, shape())

    assert {{:error, _, %{"_tag" => "ServerOpenShellOperationError", "reason" => "busy"}}, _} =
             Mc.call(client, mc.environment, "server.runOpenShellOperation", %{
               "operation" => "check"
             })

    {%{"operation" => %{"steps" => ["Starting the gateway"]}}, watcher} =
      Mc.await(watcher, &(&1["t"] == "openShell" and &1["operation"]["steps"] != []))

    assert_receive {:runner, runner}
    # What the CLI prints too: the gateway's address and the log's path.
    done = "OpenShell removed. Log: /home/user/.local/state/hal-c2/openshell.log"
    send(runner, {:answer, {:ok, done}})

    {%{"operation" => operation}, _} =
      Mc.await(watcher, &(&1["t"] == "openShell" and &1["operation"]["result"] != nil))

    assert %{
             "running" => false,
             "result" => %{"ok" => true, "message" => "OpenShell's uninstall finished."}
           } = operation

    {%{"operation" => operation}, _} =
      Mc.await(client, &(&1["t"] == "openShell" and &1["operation"]["result"] != nil))

    assert %{"running" => false, "result" => %{"ok" => true, "message" => ^done}} = operation
  end

  test "a failure's message and the sandboxes it names are the manager's alone" do
    result = %{
      "ok" => false,
      "code" => "sandboxes-running",
      "message" => "2 of this MC's review sandboxes are on the gateway.",
      "sandboxes" => 2,
      "drain" => ["review-a", "review-b"]
    }

    snapshot = %{
      "operation" => "install",
      "run" => 1,
      "running" => false,
      "steps" => [],
      "result" => result
    }

    assert Operations.viewed(snapshot, :all) == snapshot
    assert Operations.viewed(snapshot, Operations.scopes()) == snapshot

    assert %{
             "result" => %{
               "ok" => false,
               "code" => "sandboxes-running",
               "sandboxes" => 2,
               "drain" => nil,
               "message" => message
             }
           } = Operations.viewed(snapshot, ["orchestration:read"])

    assert message =~ "install failed (sandboxes-running)"
  end

  test "arguments it does not take are refused before anything runs", %{mc: mc} do
    client = Mc.connect(mc)

    # A drain names the sandboxes its user agreed to delete: never "whatever is there".
    inputs = [
      %{"operation" => "install", "archive" => "/home/user/openshell.tar.gz"}
      | for(
          drain <- [true, "review-1", [""], [1]],
          do: %{"operation" => "uninstall", "drain" => drain}
        )
    ]

    Enum.reduce(inputs, client, fn input, client ->
      assert {{:error, _, %{"_tag" => "ServerOpenShellOperationError", "reason" => "invalid"}},
              client} = Mc.call(client, mc.environment, "server.runOpenShellOperation", input)

      client
    end)

    refute_received {:started, _, _}
  end
end
