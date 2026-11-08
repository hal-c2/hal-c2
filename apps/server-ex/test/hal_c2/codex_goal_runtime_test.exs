defmodule HalC2.CodexGoalRuntimeTest do
  # A Codex goal's run waits between turns for Codex's next one, with a grace timer.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    # The test fires the grace itself.
    Application.put_env(:hal_c2, :codex_goal_grace_ms, 3_600_000)
    System.put_env("FAKE_CODEX_GOAL_STALL", "1")

    on_exit(fn ->
      HalC2.Test.Machines.refuse_changes(nil)

      for key <- ~w(codex_command codex_goal_grace_ms unrecorded_retry_ms)a,
          do: Application.delete_env(:hal_c2, key)

      System.delete_env("FAKE_CODEX_GOAL_STALL")
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    for registry <- [HalC2.Claude.Registry, HalC2.Acp.Registry, HalC2.Pi.Registry],
        do: start_supervised!({Registry, keys: :unique, name: registry}, id: registry)

    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    %{work: work}
  end

  # The run the app-server's exit failed kept the goal's grace, and the grace then
  # ended a turn that was no longer there, crashing the thread's runtime.
  test "a goal's run whose app-server exits between turns fails, and its grace ends nothing",
       %{work: work} do
    thread_id = "thread-goal"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Goal",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "m1",
        "text" => "/goal ship the fix",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, thread_id) end)
    %{goal_hold: hold, conn: conn} = await_state(pid, &(&1.goal_hold != nil))
    assert ["running"] = statuses(thread_id)

    ref = Process.monitor(conn)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert %{turn: nil, goal_hold: nil} = await_state(pid, &(&1.conn == nil))
    assert ["failed"] = statuses(thread_id)

    send(pid, {:goal_grace, hold})
    assert %{turn: nil} = :sys.get_state(pid)
    assert ["failed"] = statuses(thread_id)
  end

  # The stop of a goal's run the store failed between its turns wrote the turn Codex had
  # completed as interrupted.
  test "a goal's run the store fails between turns fails, its completed turn kept",
       %{work: work} do
    thread_id = "thread-goal-unrecorded"
    Application.put_env(:hal_c2, :unrecorded_retry_ms, 20)
    pid = goal_run(thread_id, work)
    %{conn: conn, native_thread_id: native} = await_state(pid, &(&1.goal_hold != nil))
    assert ["completed"] = provider_turns(thread_id)

    # Codex reports what the goal used so far, which the store refuses.
    HalC2.Test.Machines.refuse_changes(thread_id)
    goal = %{"objective" => "ship the fix", "status" => "active", "tokensUsed" => 10}
    params = %{"threadId" => native, "goal" => goal}
    send(pid, {:json_rpc, conn, {:notification, "thread/goal/updated", params}})
    assert %{turn: nil, goal_hold: nil} = :sys.get_state(pid)
    HalC2.Test.Machines.refuse_changes(nil)

    assert %{"status" => "failed", "failure" => "The turn could not be saved" <> _} =
             await_run(thread_id)

    assert ["completed"] = provider_turns(thread_id)
  end

  defp goal_run(thread_id, work) do
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Goal",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "m1",
        "text" => "/goal ship the fix",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, thread_id) end)
    pid
  end

  # Wakes on the thread stream's commits until its one run ended.
  defp await_run(thread_id) do
    case runs(thread_id) do
      [%{"status" => status} = run] when status in ~w(completed failed interrupted) ->
        run

      _ ->
        assert_receive {:hal_c2_stream, _, _}, 5_000
        await_run(thread_id)
    end
  end

  defp provider_turns(thread_id),
    do: Enum.map(list(thread_id, "provider-turn"), & &1["status"])

  defp runs(thread_id), do: list(thread_id, "run")

  defp list(thread_id, kind),
    do: HalC2.Streams.ensure(thread_id) |> HalC2.Streams.Server.state() |> StreamState.list(kind)

  defp statuses(thread_id) do
    HalC2.Streams.ensure(thread_id)
    |> HalC2.Streams.Server.state()
    |> StreamState.list("run")
    |> Enum.map(& &1["status"])
  end

  # Wakes on the thread stream's commits.
  defp await(fun) do
    case fun.() do
      [] ->
        assert_receive {:hal_c2_stream, _, _}, 5_000
        await(fun)

      found ->
        found
    end
  end

  # Wakes on the thread stream's commits: each state waited for comes with one.
  defp await_state(pid, fun) do
    state = :sys.get_state(pid)

    if fun.(state) do
      state
    else
      assert_receive {:hal_c2_stream, _, _}, 5_000
      await_state(pid, fun)
    end
  end
end
