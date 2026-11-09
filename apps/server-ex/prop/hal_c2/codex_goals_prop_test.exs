defmodule HalC2.CodexGoalsPropTest do
  @moduledoc """
  A state machine over one Codex goal's run (`HalC2.Codex.ThreadRuntime`): the user
  sets a goal with `/goal`, its first turn ends with the goal still active, and from
  there Codex starts turns of its own for it, changes the goal (completes it, pauses
  it, runs out of budget), or does not go on before the grace runs out; the user may
  press Stop; the app-server may exit; and once the run has ended Codex may still
  start a turn for the goal, or a grace armed before it ended may still fire. While a
  turn runs Codex may report the context's usage on the thread, of that turn or of
  another turn or thread.

  The promise: the goal's turns are one run, running until the goal stops being
  active between turns, the grace runs out, or the user stops it, and each turn
  Codex starts for it is a provider turn of that run. A run that ends with the goal
  still active (the grace, or Stop) pauses it, and a turn Codex starts for it after
  that is stopped; a goal Codex itself took out of active is left as it is, and so
  are its later turns. A run whose app-server exits fails, and a grace that fires
  after leaves the thread's runtime and its run as they were. However the run ends,
  between turns too, the last provider turn it names keeps the usage Codex reported
  last during that turn, with the time it was reported, from the report on (a running
  turn shows it at once), and none if Codex reported none in it: never an earlier
  turn's, nor what Codex reported of another turn or thread.

  The goal runs on the fake app-server in `test/support/fake_codex.py` with
  FAKE_CODEX_GOAL_STALL set, so Codex never goes on by itself: the test plays its
  side, and fires the grace timer itself (the runtime's own is set far off).

  Or Codex has already worked the goal to its end, in turns of its own, by the time
  the runtime reads its answer to the activation (FAKE_CODEX_GOAL_ANSWER_LAST): what
  Codex said after it was asked is not dropped as stale, so the run ends with the goal
  complete, and a turn Codex starts later is left as it is.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "codex-goal-thread"
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @wait_ms 10_000
  @objective "ship the fix"

  # What a goal Codex reports shows as on the provider thread.
  @shown %{"complete" => "complete", "paused" => "paused", "budgetLimited" => "budget_limited"}

  property "a Codex goal's turns are one run, which pauses a goal it leaves active",
    numtests: HalC2.Prop.numtests(25),
    max_size: 12 do
    forall answered_last <- frequency([{3, false}, {1, true}]) do
      forall cmds <- commands(__MODULE__, initial(answered_last)) do
        trap_exit do
          started = start(answered_last)
          {history, state, result} = run_commands(__MODULE__, cmds)
          HalC2.Prop.stop_services()

          for key <- [:codex_command, :codex_goal_grace_ms],
              do: Application.delete_env(:hal_c2, key)

          for key <- ~w(FAKE_CODEX_TRACE FAKE_CODEX_GOAL_STALL FAKE_CODEX_GOAL_ANSWER_LAST),
              do: System.delete_env(key)

          (started == started(answered_last) and result == :ok)
          |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
          |> when_fail(IO.puts("started as #{inspect(started)}"))
          |> aggregate(command_names(cmds))
        end
      end
    end
  end

  # Starts the goal's run, and returns what it shows once started.
  defp start(answered_last) do
    home = HalC2.Prop.scratch_home("codex-goals")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    trace = Path.join(home, "codex.log")
    Process.put(:trace, trace)
    System.put_env("FAKE_CODEX_TRACE", trace)

    if answered_last,
      do: System.put_env("FAKE_CODEX_GOAL_ANSWER_LAST", "1"),
      else: System.put_env("FAKE_CODEX_GOAL_STALL", "1")

    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    Application.put_env(:hal_c2, :codex_goal_grace_ms, 3_600_000)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      HalC2.Mcp,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
        id: :pi_registry
      ),
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
      HalC2.Settings
    ])

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Codex",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m1",
        "text" => "/goal #{@objective}",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    Process.delete(:late)
    Process.delete(:stale_hold)

    if answered_last do
      # The fake's two turns for the goal, the last completing it.
      Process.put(:goal_turns, 2)
      await_until(fn -> observed().run != "running" end, "the goal's run never ended")
      {_, %{native_thread_id: thread}} = runtime()
      Process.put(:native_thread, thread)
    else
      Process.put(:goal_turns, 0)

      # The goal's first turn (the fake's scripted reply) ends with the goal active.
      await_until(
        fn ->
          case runtime() do
            {_, %{goal_hold: hold, native_thread_id: thread}} when hold != nil ->
              Process.put(:native_thread, thread)
              observed().run == "running"

            _ ->
              false
          end
        end,
        "the goal's first turn never ended"
      )
    end

    settle_runtime()
    observed()
  end

  # What `start/1` should find: the model's initial state, as `observed/0` reads it.
  defp started(answered_last) do
    answered_last
    |> initial()
    |> Map.take([:run, :goal, :turns, :late])
    |> Map.merge(%{runs: 1, usage: nil})
  end

  # --- model ---------------------------------------------------------------------

  # phase: :held (between the goal's turns, waiting for Codex's next), :turn (a turn
  # Codex started for the goal is running), :ended (the run ended) or :exited (the
  # app-server exited, so nothing more comes from Codex). turns: the
  # run's provider turns. stops: whether a turn Codex starts after the run is stopped.
  # kept: the usage the run's last provider turn keeps, which Codex reported during
  # it (none until it reports).
  def initial_state, do: initial(false)

  defp initial(false),
    do: %{
      phase: :held,
      run: "running",
      goal: "active",
      turns: 1,
      stops: false,
      late: nil,
      kept: nil
    }

  defp initial(true),
    do: %{
      phase: :ended,
      run: "completed",
      goal: "complete",
      turns: 3,
      stops: false,
      late: nil,
      kept: nil
    }

  def command(%{phase: :held}) do
    frequency([
      {4, {:call, __MODULE__, :continue_goal, []}},
      {2, {:call, __MODULE__, :grace, []}},
      {2, {:call, __MODULE__, :goal_update, [oneof(Map.keys(@shown))]}},
      {1, {:call, __MODULE__, :stop, []}},
      {1, {:call, __MODULE__, :exit_app_server, []}}
    ])
  end

  def command(%{phase: :turn}) do
    frequency([
      {4, {:call, __MODULE__, :finish_turn, []}},
      {2, {:call, __MODULE__, :report_usage, [integer(1, 200_000), whose()]}},
      {2, {:call, __MODULE__, :goal_update, [oneof(Map.keys(@shown))]}},
      {1, {:call, __MODULE__, :stop, []}},
      {1, {:call, __MODULE__, :exit_app_server, []}}
    ])
  end

  def command(%{phase: :ended}), do: {:call, __MODULE__, :late_turn, []}
  def command(%{phase: :exited}), do: {:call, __MODULE__, :stale_grace, []}

  def precondition(state, {:call, _, :late_turn, []}), do: state.phase == :ended
  def precondition(state, {:call, _, :stale_grace, []}), do: state.phase == :exited
  def precondition(state, {:call, _, :continue_goal, []}), do: state.phase == :held
  def precondition(state, {:call, _, :grace, []}), do: state.phase == :held
  def precondition(state, {:call, _, :finish_turn, []}), do: state.phase == :turn
  def precondition(state, {:call, _, :report_usage, [_, _]}), do: state.phase == :turn
  def precondition(state, {:call, _, _, _}), do: state.phase in [:held, :turn]

  def next_state(state, _result, {:call, _, :continue_goal, []}),
    do: %{state | phase: :turn, turns: state.turns + 1, late: nil, kept: nil}

  # The running turn keeps its own as it comes, and keeps it however it ends.
  def next_state(state, _result, {:call, _, :report_usage, [n, :own]}), do: %{state | kept: n}
  def next_state(state, _result, {:call, _, :report_usage, [_n, _other]}), do: state

  def next_state(state, result, call), do: step(state, result, call)

  defp step(state, _result, {:call, _, :grace, []}),
    do: ended(state, "completed", "paused", true)

  defp step(%{phase: :held} = state, _result, {:call, _, :goal_update, [status]}),
    do: ended(state, "completed", @shown[status], false)

  defp step(state, _result, {:call, _, :goal_update, [status]}),
    do: %{state | goal: @shown[status]}

  defp step(%{goal: "active"} = state, _result, {:call, _, :finish_turn, []}),
    do: %{state | phase: :held}

  defp step(state, _result, {:call, _, :finish_turn, []}),
    do: ended(state, "completed", state.goal, false)

  # Stop pauses a goal still active; between turns it ends the run at once.
  defp step(%{goal: "active"} = state, _result, {:call, _, :stop, []}),
    do: ended(state, "interrupted", "paused", true)

  defp step(state, _result, {:call, _, :stop, []}),
    do: ended(state, "interrupted", state.goal, false)

  defp step(state, _result, {:call, _, :exit_app_server, []}),
    do: %{state | phase: :exited, run: "failed", late: nil}

  defp step(state, _result, {:call, _, :late_turn, []}), do: %{state | late: state.stops}
  defp step(state, _result, _call), do: state

  defp ended(state, run, goal, stops),
    do: %{state | phase: :ended, run: run, goal: goal, stops: stops, late: nil}

  def postcondition(state, {:call, _, :stale_grace, []} = call, {alive, seen}),
    do: alive and postcondition(state, call, seen)

  def postcondition(state, call, seen) do
    expected = next_state(state, nil, call)

    seen == %{
      runs: 1,
      run: expected.run,
      goal: expected.goal,
      turns: expected.turns,
      late: expected.late,
      usage: expected.kept
    }
  end

  # --- commands ------------------------------------------------------------------

  # Codex starts its next turn for the goal.
  def continue_goal do
    n = Process.get(:goal_turns) + 1
    Process.put(:goal_turns, n)
    Process.put(:native_turn, "goal-turn-#{n}")
    notify("turn/started", %{"turn" => %{"id" => "goal-turn-#{n}", "status" => "inProgress"}})
    settle_runtime()
    # The runtime does not wait on Codex's answer to a stop; a call of our own through
    # the same app-server, after it, is answered once the fake has read the stop.
    {_, runtime} = runtime()
    HalC2.JsonRpc.Connection.call(runtime.conn, "test/ping", %{})
    observed()
  end

  # The grace runs out with no turn from Codex.
  def grace do
    {pid, %{goal_hold: hold}} = runtime()
    send(pid, {:goal_grace, hold})
    await_until(fn -> observed().run != "running" end, "the run never ended")
    settle_runtime()
    observed()
  end

  # Codex reports the goal as `status`: done, paused or out of budget.
  def goal_update(status) do
    notify("thread/goal/updated", %{
      "goal" => %{"objective" => @objective, "status" => status, "tokensUsed" => 10}
    })

    settle_runtime()
    observed()
  end

  # Whose usage Codex reports: the running turn's, an earlier turn's, or another
  # thread's under the running turn's id.
  defp whose, do: frequency([{3, :own}, {1, :other_turn}, {1, :other_thread}])

  # Codex reports the context's usage on the thread, as it does while a turn runs.
  def report_usage(n, whose) do
    turn = if whose == :other_turn, do: "an-earlier-turn", else: Process.get(:native_turn)
    params = %{"turnId" => turn, "tokenUsage" => %{"last" => %{"totalTokens" => n}}}
    params = if whose == :other_thread, do: Map.put(params, "threadId", "other"), else: params
    notify("thread/tokenUsage/updated", params)

    settle_runtime()
    observed()
  end

  def finish_turn do
    notify("turn/completed", %{
      "turn" => %{"id" => Process.get(:native_turn), "status" => "completed"}
    })

    settle_runtime()
    observed()
  end

  # The user presses Stop. A running turn ends once Codex reports it interrupted,
  # as the fake does for every turn/interrupt.
  def stop do
    {pid, _} = runtime()
    :ok = GenServer.call(pid, :interrupt)
    await_until(fn -> observed().run != "running" end, "the run never stopped")
    settle_runtime()
    observed()
  end

  # Codex starts another turn for the goal after the run ended.
  def late_turn do
    n = Process.get(:goal_turns) + 1
    Process.put(:goal_turns, n)
    Process.put(:late, "goal-turn-#{n}")
    notify("turn/started", %{"turn" => %{"id" => "goal-turn-#{n}", "status" => "inProgress"}})
    settle_runtime()
    # The runtime does not wait on Codex's answer to a stop; a call of our own through
    # the same app-server, after it, is answered once the fake has read the stop.
    {_, runtime} = runtime()
    HalC2.JsonRpc.Connection.call(runtime.conn, "test/ping", %{})
    observed()
  end

  # The app-server exits (killed by the pid its connection started, never by name).
  def exit_app_server do
    {pid, %{conn: conn, goal_hold: hold}} = runtime()
    Process.put(:stale_hold, hold || Process.get(:stale_hold))
    ref = Process.monitor(conn)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @wait_ms -> :ok
    end

    await_until(fn -> observed().run != "running" end, "the run never failed")
    # Behind the runtime's handling of its connection's end.
    _ = :sys.get_state(pid)
    observed()
  end

  # A grace armed before the app-server exited fires after.
  def stale_grace do
    {pid, _} = runtime()
    send(pid, {:goal_grace, Process.get(:stale_hold)})

    # Behind the grace in the runtime's mailbox.
    alive =
      try do
        is_map(:sys.get_state(pid))
      catch
        :exit, _ -> false
      end

    {alive, observed()}
  end

  # --- the real side ---------------------------------------------------------------

  # As the app-server would send it; the `:settle` call after rides behind it,
  # so what is read back is what its handling committed.
  defp notify(method, params) do
    {pid, runtime} = runtime()
    params = Map.put_new(params, "threadId", Process.get(:native_thread))
    send(pid, {:json_rpc, runtime.conn, {:notification, method, params}})
  end

  defp settle_runtime do
    case runtime() do
      {pid, _} -> GenServer.call(pid, :settle)
      nil -> :ok
    end
  end

  defp runtime do
    case Registry.lookup(HalC2.Codex.Registry, @tid) do
      [{pid, _}] -> {pid, :sys.get_state(pid)}
      [] -> nil
    end
  end

  defp observed do
    state = current(@tid)
    runs = StreamState.list(state, "run")
    thread = state |> StreamState.list("provider-thread") |> List.first()

    %{
      runs: length(runs),
      run: runs |> List.first() |> Map.get("status"),
      goal: get_in(thread, ["goal", "status"]),
      turns: length(StreamState.list(state, "provider-turn")),
      late: late_stopped(),
      usage: kept(state)
    }
  end

  # The usage the run's last provider turn keeps, which a turn's usage must stamp.
  defp kept(state) do
    attempt = state |> StreamState.list("run-attempt") |> List.first() || %{}

    case StreamState.get(state, "provider-turn")[attempt["providerTurnId"]] do
      %{"tokenUsage" => %{"usedTokens" => n, "updatedAt" => at}} when is_binary(at) -> n
      %{"tokenUsage" => %{} = usage} -> {:unstamped, usage}
      _ -> nil
    end
  end

  # Whether the late turn, if there was one, was stopped: the fake logs every
  # message it reads before it answers, so a stop the runtime sent is there.
  defp late_stopped do
    case Process.get(:late) do
      nil ->
        nil

      late ->
        Process.get(:trace)
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.any?(
          &match?(
            %{"in" => %{"method" => "turn/interrupt", "params" => %{"turnId" => ^late}}},
            &1
          )
        )
    end
  end

  # Wakes on the stream's own commits; what it waited for never happening is
  # the failure the postcondition then shows, so it returns rather than raises.
  defp await_until(fun, _what, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms

    if fun.() do
      :ok
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_until(fun, nil, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
      end
    end
  end

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
end
