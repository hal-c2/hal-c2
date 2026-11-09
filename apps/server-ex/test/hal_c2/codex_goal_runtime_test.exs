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
    HalC2.Test.Env.put_app(:home, dir)
    HalC2.Test.Env.put_app(:codex_command, ["python3", "-u", @fake_codex])
    # The test fires the grace itself.
    HalC2.Test.Env.put_app(:codex_goal_grace_ms, 3_600_000)
    HalC2.Test.Env.put_system("FAKE_CODEX_GOAL_STALL", "1")

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
    start_goal_run(thread_id, work)

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

  # Codex finishes the goal while the MC still waits for its answer to the goal being
  # set active (the fake reports the completion ahead of that answer), so the report
  # is already queued when the answer is read. Keeping the goal active would hold the
  # run until the grace paused it.
  test "a goal Codex finished before the MC heard the activation answer is complete, not active",
       %{work: work} do
    HalC2.Test.Env.put_system("FAKE_CODEX_GOAL_FINISH_FIRST", "1")
    thread_id = "thread-goal-done"
    start_goal_run(thread_id, work)

    [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, thread_id) end)
    state = await_state(pid, &(&1.turn == nil and &1.goal != nil))
    assert %{goal_hold: nil, goal: %{"status" => "complete"}} = state
    assert ["completed"] = statuses(thread_id)
  end

  # Codex finishes the goal just before the user's clear or pause reaches it, so its
  # report that the goal is complete is queued ahead of the answer. The answer is newer:
  # the goal stays cleared or paused.
  for {command, expected} <- [{"/goal clear", nil}, {"/goal pause", "paused"}] do
    test "#{command} answered after Codex reported the goal complete keeps the answer",
         %{work: work} do
      HalC2.Test.Env.put_system(
        "FAKE_CODEX_GOAL",
        ~s({"objective": "ship the fix", "status": "active"})
      )

      HalC2.Test.Env.put_system("FAKE_CODEX_GOAL_DONE_BEFORE_STOP", "1")

      thread_id = "thread-goal-#{String.replace(unquote(command), " ", "-")}"
      start_goal_run(thread_id, work, unquote(command))

      [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, thread_id) end)
      state = await_state(pid, &(&1.turn == nil))
      assert get_in(state.goal, ["status"]) == unquote(expected)
      assert ["completed"] = statuses(thread_id)
    end
  end

  # Codex's report of the context's usage reaches the turn it runs in as it comes: a
  # goal's later turn, which the run's attempt names from its start, shows it while it
  # is still running (the goals property's counterexample, a continue then a report).
  test "a goal's later turn keeps the usage Codex reports in it while it runs",
       %{work: work} do
    thread_id = "thread-goal-usage"
    start_goal_run(thread_id, work)

    [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, thread_id) end)
    %{conn: conn, native_thread_id: native} = await_state(pid, &(&1.goal_hold != nil))

    notify = fn method, params ->
      send(pid, {:json_rpc, conn, {:notification, method, Map.put(params, "threadId", native)}})
    end

    notify.("turn/started", %{"turn" => %{"id" => "goal-turn-1", "status" => "inProgress"}})
    GenServer.call(pid, :settle)
    assert nil == attempt_turn(thread_id)["tokenUsage"]

    notify.("thread/tokenUsage/updated", %{
      "turnId" => "goal-turn-1",
      "tokenUsage" => %{"last" => %{"totalTokens" => 5}}
    })

    GenServer.call(pid, :settle)
    assert ["running"] = statuses(thread_id)

    assert %{"id" => "provider-turn:codex:goal-turn-1", "tokenUsage" => usage} =
             attempt_turn(thread_id)

    assert %{"usedTokens" => 5, "updatedAt" => at} = usage
    assert is_binary(at)
  end

  # Codex names the turn and thread each usage report is of. A report of another turn
  # (one that ended before the running turn's start was answered, say) or of a thread
  # that is not the conversation's is not the running turn's to keep, nor the meter's.
  test "a running turn keeps only the usage Codex reports of it", %{work: work} do
    thread_id = "thread-goal-usage-other"
    start_goal_run(thread_id, work)

    [{pid, _}] = await(fn -> Registry.lookup(HalC2.Codex.Registry, thread_id) end)
    %{conn: conn, native_thread_id: native} = await_state(pid, &(&1.goal_hold != nil))

    notify = fn method, params ->
      send(
        pid,
        {:json_rpc, conn, {:notification, method, Map.put_new(params, "threadId", native)}}
      )
    end

    notify.("turn/started", %{"turn" => %{"id" => "goal-turn-1", "status" => "inProgress"}})
    GenServer.call(pid, :settle)
    meter = provider_thread(thread_id)["contextUsage"]

    notify.("thread/tokenUsage/updated", %{
      "turnId" => "an-earlier-turn",
      "tokenUsage" => %{"last" => %{"totalTokens" => 7}}
    })

    notify.("thread/tokenUsage/updated", %{
      "threadId" => "another-thread",
      "turnId" => "goal-turn-1",
      "tokenUsage" => %{"last" => %{"totalTokens" => 9}}
    })

    GenServer.call(pid, :settle)
    assert nil == attempt_turn(thread_id)["tokenUsage"]
    assert meter == provider_thread(thread_id)["contextUsage"]

    notify.("thread/tokenUsage/updated", %{
      "turnId" => "goal-turn-1",
      "tokenUsage" => %{"last" => %{"totalTokens" => 5}}
    })

    GenServer.call(pid, :settle)
    assert %{"usedTokens" => 5} = attempt_turn(thread_id)["tokenUsage"]
  end

  defp provider_thread(thread_id) do
    state = HalC2.Streams.ensure(thread_id) |> HalC2.Streams.Server.state()
    state |> StreamState.list("provider-thread") |> List.first()
  end

  # The provider turn the thread's run attempt names.
  defp attempt_turn(thread_id) do
    state = HalC2.Streams.ensure(thread_id) |> HalC2.Streams.Server.state()
    [attempt] = StreamState.list(state, "run-attempt")
    StreamState.get(state, "provider-turn")[attempt["providerTurnId"]]
  end

  defp start_goal_run(thread_id, work, text \\ "/goal ship the fix") do
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
        "text" => text,
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })
  end

  # Codex's answer to the activation came behind its reports of the goal turns it ran
  # and of the goal it completed in the last; dropping those as stale left the run
  # waiting for a turn Codex would never start.
  test "a goal Codex completes before its answer to the activation is read ends the run",
       %{work: work} do
    System.delete_env("FAKE_CODEX_GOAL_STALL")
    System.put_env("FAKE_CODEX_GOAL_ANSWER_LAST", "1")
    on_exit(fn -> System.delete_env("FAKE_CODEX_GOAL_ANSWER_LAST") end)

    thread_id = "thread-goal-answer-last"
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

    await(fn -> if statuses(thread_id) == ["completed"], do: :done, else: [] end)
    state = HalC2.Streams.ensure(thread_id) |> HalC2.Streams.Server.state()
    assert [%{"goal" => %{"status" => "complete"}}] = StreamState.list(state, "provider-thread")

    assert ["completed", "completed", "completed"] =
             state |> StreamState.list("provider-turn") |> Enum.map(& &1["status"])
  end

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
