defmodule HalC2.CodexTurnEndPropTest do
  @moduledoc """
  A state machine over one Codex turn (`HalC2.Codex.ThreadRuntime`) that spawns
  subagents of its own: Codex starts subagents and reports where each stands,
  then the turn ends one of six ways — Codex reports it completed, failed or
  interrupted, its app-server (and with it the event stream) dies without
  reporting anything, it closes its output and runs on, or it stops taking input
  so the MC's next write to it fails — and a subagent's own report may still
  arrive after a reported end.

  The promise: the run ends as the turn did (a dead or closed stream or a failed
  write fails it), and a subagent still running ends with the turn exactly when
  nothing can report it again — an interrupted turn, or a dead or closed stream or
  a failed write, which fails it. After a completed or failed turn Codex itself
  reported, its subagents carry on in their own threads and their later reports
  land; a report for one that had already ended changes nothing. A stream that
  dies after such a reported end, with no turn active, fails the subagents that
  turn left running and leaves the run as the turn ended it.

  Along the way Codex may finish MCP tool calls that name an app: one whose
  server answers the read of its document, which then lands on the tool item,
  and one whose server never answers, which leaves a plain tool row and holds
  nothing else of the turn (every command's `:settle` call is answered).

  The turn runs on the fake app-server in `test/support/fake_codex.py`, which
  leaves a turn saying "wait" open; the test then plays Codex's side itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "codex-thread"
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @wait_ms 10_000

  # What the thread shows for the state Codex reports of a subagent.
  @shown %{
    "completed" => "completed",
    "errored" => "failed",
    "shutdown" => "cancelled",
    "interrupted" => "interrupted"
  }

  property "a Codex turn's end settles its subagents as the way it ended says",
    numtests: HalC2.Prop.numtests(25),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Prop.restore_env()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("codex-turn-end")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    HalC2.Prop.put_env(:codex_command, ["python3", "-u", @fake_codex])

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
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_until(
      fn ->
        case runtime() do
          {_, %{turn: %{native_turn_id: turn}, native_thread_id: thread}}
          when is_binary(turn) and is_binary(thread) ->
            Process.put(:native_thread, thread)
            Process.put(:native_turn, turn)
            observed().run == "running"

          _ ->
            false
        end
      end,
      "no Codex turn"
    )
  end

  # --- model ---------------------------------------------------------------------

  # phase: :running, :reported (Codex reported the turn's end; its subagents'
  # reports can still arrive) or :ended (the stream died; nothing more can
  # arrive). subs: each spawned subagent's shown status, in spawn order.
  # apps: whether each MCP app tool item, in completion order, shows its app.
  def initial_state, do: %{phase: :running, run: "running", subs: [], apps: []}

  def command(state) do
    reports =
      if state.subs != [] and state.phase != :ended,
        do: [
          {3,
           {:call, __MODULE__, :report,
            [oneof(Enum.to_list(1..length(state.subs))), oneof(Map.keys(@shown))]}}
        ],
        else: []

    case state.phase do
      :running ->
        frequency(
          [
            {3, {:call, __MODULE__, :spawn, [length(state.subs) + 1]}},
            {2, {:call, __MODULE__, :app, [length(state.apps) + 1, boolean()]}},
            {2, {:call, __MODULE__, :end_turn, [:completed]}},
            {2, {:call, __MODULE__, :end_turn, [:failed]}},
            {2, {:call, __MODULE__, :end_turn, [:interrupted]}},
            {2, {:call, __MODULE__, :end_turn, [:stream]}},
            {2, {:call, __MODULE__, :end_turn, [:deaf]}},
            {2, {:call, __MODULE__, :end_turn, [:mute]}}
          ] ++ reports
        )

      :reported ->
        frequency(
          [{1, {:call, __MODULE__, :observe, []}}, {2, {:call, __MODULE__, :end_stream, []}}] ++
            reports
        )

      :ended ->
        {:call, __MODULE__, :observe, []}
    end
  end

  def precondition(state, {:call, _, :spawn, [n]}),
    do: state.phase == :running and n == length(state.subs) + 1

  def precondition(state, {:call, _, :report, [n, reported]}),
    do: state.phase != :ended and n in 1..length(state.subs) and Map.has_key?(@shown, reported)

  def precondition(state, {:call, _, :app, [n, _answered]}),
    do: state.phase == :running and n == length(state.apps) + 1

  def precondition(state, {:call, _, :end_turn, [_kind]}), do: state.phase == :running
  def precondition(state, {:call, _, :end_stream, []}), do: state.phase == :reported
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :spawn, _}),
    do: %{state | subs: state.subs ++ ["running"]}

  def next_state(state, _result, {:call, _, :app, [_n, answered]}),
    do: %{state | apps: state.apps ++ [answered]}

  def next_state(state, _result, {:call, _, :report, [n, reported]}) do
    subs =
      List.update_at(state.subs, n - 1, fn
        "running" -> @shown[reported]
        ended -> ended
      end)

    %{state | subs: subs}
  end

  def next_state(state, _result, {:call, _, :end_turn, [kind]}) do
    case kind do
      :completed ->
        %{state | phase: :reported, run: "completed"}

      :failed ->
        %{state | phase: :reported, run: "failed"}

      :interrupted ->
        %{state | phase: :reported, run: "interrupted", subs: settle(state, "interrupted")}

      # A write the app-server no longer takes, or output it closed while it runs
      # on, retires it, as its death does.
      dead when dead in [:stream, :deaf, :mute] ->
        %{state | phase: :ended, run: "failed", subs: settle(state, "failed")}
    end
  end

  # The stream dies after Codex reported the turn's end: the run keeps how
  # the turn ended, and subagents it left running fail with the stream.
  def next_state(state, _result, {:call, _, :end_stream, []}),
    do: %{state | phase: :ended, subs: settle(state, "failed")}

  def next_state(state, _result, _call), do: state

  defp settle(state, status),
    do:
      Enum.map(state.subs, fn
        "running" -> status
        ended -> ended
      end)

  def postcondition(state, {:call, _, _, _} = call, seen) do
    expected = next_state(state, nil, call)
    seen == %{run: expected.run, subs: expected.subs, apps: expected.apps}
  end

  # --- commands ------------------------------------------------------------------

  # Codex starts subagent `n`, still working on its task.
  def spawn(n) do
    notify("item/started", collab(n, "inProgress", %{"status" => "running"}))
    await_until(fn -> length(observed().subs) >= n end, "subagent #{n} never showed")
    settle_runtime()
    observed()
  end

  # Codex finishes MCP tool call `n`, naming an app whose server answers the read
  # of its document or never does. An answered app lands on the item; the
  # `:settle` call is answered either way, the read being off the runtime.
  def app(n, answered) do
    uri = if answered, do: "ui://weather/forecast.html", else: "ui://weather/slow.html"

    notify("item/completed", %{
      "threadId" => Process.get(:native_thread),
      "turnId" => Process.get(:native_turn),
      "item" => %{
        "type" => "mcpToolCall",
        "id" => "mcp-app-#{n}",
        "server" => "weather",
        "tool" => "get_forecast",
        "arguments" => %{},
        "status" => "completed",
        "result" => %{"content" => [%{"type" => "text", "text" => "Sunny"}]},
        "error" => nil,
        "mcpAppResourceUri" => uri
      }
    })

    settle_runtime()
    if answered, do: await_until(fn -> Enum.at(observed().apps, n - 1) == true end, "no app")
    observed()
  end

  # Codex reports subagent `n` as `reported` (a state that ends it).
  def report(n, reported) do
    notify(
      "item/completed",
      collab(n, "completed", %{"status" => reported, "message" => "result #{n}"})
    )

    settle_runtime()
    observed()
  end

  # The turn ends: as Codex reports it, or with its app-server dying mid-turn.
  def end_turn(:stream) do
    kill_app_server()
    await_until(fn -> observed().run != "running" end, "the run never ended")
    settle_runtime()
    observed()
  end

  # The app-server stops reading its input but keeps its output open; the next
  # thing written to it fails.
  def end_turn(:deaf) do
    {_, runtime} = runtime()
    {:ok, _} = HalC2.JsonRpc.Connection.call(runtime.conn, "test/deaf", %{})
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/ping", nil)
    await_until(fn -> observed().run != "running" end, "the run never ended")
    settle_runtime()
    observed()
  end

  # The app-server closes its output and runs on: nothing more can be reported.
  def end_turn(:mute) do
    {_, runtime} = runtime()
    HalC2.JsonRpc.Connection.notify(runtime.conn, "test/mute", nil)
    await_until(fn -> observed().run != "running" end, "the run never ended")
    settle_runtime()
    observed()
  end

  def end_turn(kind) do
    status = Atom.to_string(kind)

    turn =
      %{"id" => Process.get(:native_turn), "status" => status}
      |> then(fn turn ->
        if kind == :failed,
          do: Map.put(turn, "error", %{"message" => "the turn failed"}),
          else: turn
      end)

    notify("turn/completed", %{"turn" => turn})
    await_until(fn -> observed().run != "running" end, "the run never ended")
    settle_runtime()
    observed()
  end

  # The app-server dies after Codex reported the turn's end, while subagents
  # that turn left running carry on in their own threads.
  def end_stream do
    kill_app_server()

    await_until(
      fn -> Enum.all?(observed().subs, &(&1 != "running")) end,
      "the subagents never settled"
    )

    settle_runtime()
    observed()
  end

  def observe, do: observed()

  # --- the real side ---------------------------------------------------------------

  defp collab(n, status, agent_state) do
    %{
      "threadId" => Process.get(:native_thread),
      "turnId" => Process.get(:native_turn),
      "item" => %{
        "type" => "collabAgentToolCall",
        "id" => "collab-#{n}",
        "tool" => "spawnAgent",
        "prompt" => "List the modules in lib",
        "senderThreadId" => Process.get(:native_thread),
        "receiverThreadIds" => ["native-child-#{n}"],
        "status" => status,
        "agentsStates" => %{"native-child-#{n}" => agent_state}
      }
    }
  end

  # As the app-server would send it; the `:settle` call after rides behind it,
  # so what is read back is what its handling committed.
  defp notify(method, params) do
    {pid, runtime} = runtime()
    send(pid, {:json_rpc, runtime.conn, {:notification, method, params}})
  end

  # The fake app-server dies without ending anything, as a crashed Codex does.
  defp kill_app_server do
    {_, runtime} = runtime()
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
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
    run = state |> StreamState.list("run") |> List.first()

    %{
      run: run && run["status"],
      subs: state |> StreamState.list("subagent") |> Enum.map(& &1["status"]),
      apps:
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(&match?(%{"nativeItemRef" => %{"nativeId" => "mcp-app-" <> _}}, &1))
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(&Map.has_key?(&1, "mcpApp"))
    }
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
