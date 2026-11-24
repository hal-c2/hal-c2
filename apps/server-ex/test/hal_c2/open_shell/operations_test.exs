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
    %{server: server, runner: runner}
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
               %{"operation" => "uninstall", "drain" => ["review-1"], "force" => false},
               server
             )

    {runner, :uninstall, opts} = started()
    assert opts == [drain: ["review-1"]]
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

  # A client tells its own run's frames from older ones by this number.
  test "each run's number is larger than the last's, and its reply and frames carry it", %{
    server: server
  } do
    assert {:ok, %{"run" => started, "operation" => nil}} = Operations.state(server)

    assert {:ok, %{"run" => first}} = Operations.run(%{"operation" => "check"}, server)
    assert first > started
    {runner, :check, []} = started()
    assert %{"run" => ^first, "running" => true} = changed()
    send(runner, {:step, "Checking"})
    assert %{"run" => ^first, "steps" => ["Checking"]} = changed()
    send(runner, {:answer, {:ok, "fine"}})
    assert %{"run" => ^first, "running" => false} = changed()

    assert {:ok, %{"run" => second}} = Operations.run(%{"operation" => "check"}, server)
    assert second > first
    assert %{"run" => ^second, "running" => true} = changed()
  end

  # A client still waiting on a run when the MC restarts knows by this that the run
  # went with the old server.
  test "a server started after a run shows no operation, numbered above the run", %{
    server: server
  } do
    assert {:ok, %{"run" => run}} = Operations.run(%{"operation" => "uninstall"}, server)
    {_runner, :uninstall, []} = started()

    restarted = start_supervised!({Operations, name: nil}, id: :restarted)

    assert {:ok, %{"operation" => nil, "running" => false, "result" => nil, "run" => started}} =
             Operations.state(restarted)

    assert started > run
  end

  # The last number outlives the server; the clock alone would go back with it.
  test "a server started with the clock stepped back numbers above every run before", %{
    server: server
  } do
    assert {:ok, %{"run" => run}} = Operations.run(%{"operation" => "check"}, server)
    {_runner, :check, []} = started()

    restarted =
      start_supervised!(
        {Operations, name: nil, clock: fn -> 1 end, runner: fn _, _ -> {:ok, "fine"} end},
        id: :clock_back
      )

    assert {:ok, %{"operation" => nil, "run" => started}} = Operations.state(restarted)
    assert started > run
    assert {:ok, %{"run" => next}} = Operations.run(%{"operation" => "check"}, restarted)
    assert next > started
  end

  test "an error is worded for Settings, with the sandboxes it would stop", %{server: server} do
    assert {:ok, _} = Operations.run(%{"operation" => "uninstall"}, server)
    {runner, :uninstall, []} = started()
    changed()

    send(
      runner,
      {:answer,
       {:error,
        "[sandboxes-running] 2 of this MC's sandboxes are on the gateway (review-a, review-b). Let their reviews finish, or pass --drain to delete them."}}
    )

    # The names are what a yes sends back as `drain`.
    assert %{
             "running" => false,
             "result" => %{
               "ok" => false,
               "code" => "sandboxes-running",
               "sandboxes" => 2,
               "drain" => ["review-a", "review-b"],
               "message" => message
             }
           } = changed()

    assert message =~ "2 of this MC's review sandboxes"
    refute message =~ "--drain"
  end

  # A server under the MC's name, restarted while its run goes on.
  test "a server started while a run goes on takes it back, and hears how it ends", %{
    runner: runner
  } do
    name = :"openshell_operations_#{System.unique_integer([:positive])}"
    first = start_supervised!({Operations, name: name, runner: runner}, id: :first)

    assert {:ok, %{"run" => run}} = Operations.run(%{"operation" => "uninstall"}, first)
    {job, :uninstall, []} = started()
    :ok = stop_supervised(:first)

    restarted = start_supervised!({Operations, name: name, runner: runner}, id: :again)
    {:ok, _} = Operations.subscribe(self(), nil, restarted)

    assert {:ok, %{"operation" => "uninstall", "run" => ^run, "running" => true}} =
             Operations.state(restarted)

    send(job, {:step, "Removing the gateway"})
    assert %{"run" => ^run, "steps" => ["Removing the gateway"]} = changed()
    send(job, {:answer, {:ok, "OpenShell removed."}})

    assert %{"run" => ^run, "running" => false, "result" => %{"ok" => true}} = changed()

    # Ended: the next server under the name starts with none.
    :ok = stop_supervised(:again)
    again = start_supervised!({Operations, name: name, runner: runner}, id: :third)
    assert {:ok, %{"operation" => nil, "running" => false}} = Operations.state(again)
  end

  @tag :capture_log
  test "a run that went while no server was there ends not ok under its number", %{
    runner: runner
  } do
    name = :"openshell_operations_#{System.unique_integer([:positive])}"
    first = start_supervised!({Operations, name: name, runner: runner}, id: :first)

    assert {:ok, %{"run" => run}} = Operations.run(%{"operation" => "rotate"}, first)
    {job, :rotate, []} = started()
    :ok = stop_supervised(:first)
    ref = Process.monitor(job)
    Process.exit(job, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}

    restarted = start_supervised!({Operations, name: name, runner: runner}, id: :again)

    assert {:ok,
            %{
              "run" => ^run,
              "running" => false,
              "result" => %{"ok" => false, "message" => message}
            }} = Operations.state(restarted)

    assert message =~ "stopped before it finished"
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
          %{"operation" => "install", "drain" => true},
          %{"operation" => "install", "drain" => [""]},
          %{"operation" => "install", "force" => "yes"},
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
