defmodule HalC2.OpenShell.OperationsTest do
  use ExUnit.Case, async: true

  alias HalC2.OpenShell.Operations

  # A runner that tells the test it started, with the options it was given, and
  # answers what the test sends it. Steps go through the progress function.
  setup do
    test = self()

    runner = fn operation, opts ->
      send(test, {:started, self(), operation, Keyword.delete(opts, :progress)})

      receive do
        {:step, text} ->
          opts[:progress].(text)

          receive do
            {:answer, answer} -> answer
          end

        {:answer, answer} ->
          answer

        :raise ->
          raise "the archive is not gzip"
      end
    end

    server = start_supervised!({Operations, name: nil, runner: runner})
    {:ok, _} = Operations.subscribe(self(), nil, server)
    %{server: server}
  end

  defp started do
    assert_receive {:started, pid, operation, opts}
    {pid, operation, opts}
  end

  defp changed do
    assert_receive {:hal_c2_openshell, _node, state}
    state
  end

  test "an operation runs with its flags, shows its steps and ends with its outcome", %{
    server: server
  } do
    assert {:ok, %{"operation" => "uninstall", "running" => true, "steps" => []}} =
             Operations.run(
               %{"operation" => "uninstall", "drain" => true, "force" => false},
               server
             )

    {runner, :uninstall, opts} = started()
    assert opts == [drain: true]
    assert %{"running" => true} = changed()

    send(runner, {:step, "Removing the gateway"})
    assert %{"steps" => ["Removing the gateway"], "running" => true} = changed()

    send(runner, {:answer, {:ok, "OpenShell removed."}})

    assert %{
             "running" => false,
             "operation" => "uninstall",
             "steps" => ["Removing the gateway"],
             "result" => %{"ok" => true, "message" => "OpenShell removed.", "code" => nil}
           } = changed()

    assert {:ok, %{"running" => false, "result" => %{"ok" => true}}} = Operations.state(server)
  end

  test "a second operation while one runs is answered busy, and runs once it ended", %{
    server: server
  } do
    assert {:ok, _} = Operations.run(%{"operation" => "install"}, server)
    {runner, :install, []} = started()

    assert {:error,
            %{"_tag" => "ServerOpenShellOperationError", "reason" => "busy", "message" => message}} =
             Operations.run(%{"operation" => "check"}, server)

    assert message =~ "install is already running"
    refute_received {:started, _, _, _}

    send(runner, {:answer, {:ok, "installed"}})
    changed()
    assert %{"running" => false} = changed()

    assert {:ok, _} = Operations.run(%{"operation" => "check"}, server)
    {_runner, :check, []} = started()
  end

  test "an error is worded for Settings, with the sandboxes it would stop", %{server: server} do
    assert {:ok, _} = Operations.run(%{"operation" => "uninstall"}, server)
    {runner, :uninstall, []} = started()
    changed()

    send(
      runner,
      {:answer,
       {:error,
        "[sandboxes-running] 2 of this MC's sandboxes are on the gateway. Let their reviews finish, or pass --drain to delete them."}}
    )

    assert %{
             "running" => false,
             "result" => %{"ok" => false, "code" => "sandboxes-running", "sandboxes" => 2}
           } = changed()
  end

  @tag :capture_log
  test "a runner that raises or is killed ends the operation with a failure", %{server: server} do
    assert {:ok, _} = Operations.run(%{"operation" => "rotate"}, server)
    {runner, :rotate, []} = started()
    changed()
    send(runner, :raise)

    assert %{"running" => false, "result" => %{"ok" => false, "message" => message}} = changed()
    assert message =~ "MC's log"
    refute message =~ "gzip"

    assert {:ok, _} = Operations.run(%{"operation" => "rotate"}, server)
    {runner, :rotate, []} = started()
    changed()
    Process.exit(runner, :kill)

    assert %{"running" => false, "result" => %{"ok" => false, "message" => message}} = changed()
    assert message =~ "stopped before it finished"
  end

  test "input names an operation and its flags, nothing else", %{server: server} do
    for input <- [
          %{},
          %{"operation" => "reap"},
          %{"operation" => "install", "archive" => "/tmp/openshell.tar.gz"},
          %{"operation" => "install", "drain" => "yes"},
          %{"operation" => "check", "force" => true},
          "install"
        ] do
      assert {:error, %{"reason" => "invalid"}} = Operations.run(input, server)
    end

    refute_received {:started, _, _, _}
    assert {:ok, %{"running" => false, "operation" => nil}} = Operations.state(server)
  end

  test "a session that may manage the machine can run them; another is told what it lacks" do
    assert Operations.manage(:all) == %{"canManage" => true, "manageReason" => nil}

    assert Operations.manage(["access:write", "terminal:operate", "orchestration:read"]) ==
             %{"canManage" => true, "manageReason" => nil}

    assert %{"canManage" => false, "manageReason" => reason} =
             Operations.manage(["orchestration:read", "access:write"])

    assert reason =~ "terminal:operate"
    refute reason =~ "access:write"
  end
end
