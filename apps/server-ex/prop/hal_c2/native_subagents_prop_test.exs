defmodule HalC2.NativeSubagentsPropTest do
  @moduledoc """
  A state machine over the subagents setting (`nativeSubagents`) and two threads, one on
  Codex (`HalC2.Codex.ThreadRuntime`) and one on Claude (`HalC2.Claude.ThreadRuntime`):
  switch the setting between the provider's own subagents and HAL-C2's workers, run a
  turn on either thread, and release either thread's provider session.

  The promise: a Claude turn runs on a CLI started with the setting as it was when the
  turn began, its `Agent` and `Task` tools taken away and its prompt telling it to
  delegate exactly when the choice is HAL-C2's workers. A Codex thread reads the choice
  when its session starts its native thread and keeps it until the session is
  released: the native thread's subagent features and every turn's instructions follow
  the kept choice, whatever the setting says meanwhile.

  Turns run on the fakes in `test/support/fake_codex.py` and `fake_claude.py`, which
  append what they are sent to a trace the test reads after each turn completes.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @threads %{
    codex: {"codex-thread", %{"instanceId" => "codex", "model" => "gpt-5.4"}},
    claude: {"claude-thread", %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}}
  }
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @off %{"multi_agent" => false, "multi_agent_v2" => false}
  @wait_ms 10_000

  property "agents are kept to HAL-C2's workers as the setting said when their session began",
    numtests: HalC2.Prop.numtests(20),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)
        Application.delete_env(:hal_c2, :claude_command)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("native-subagents")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    for provider <- [:codex, :claude] do
      log = Path.join(home, "#{provider}.trace")
      Process.put({:trace, provider}, log)
      Process.put({:read, provider}, 0)
    end

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_TRACE=#{Process.get({:trace, :codex})}",
      "python3",
      "-u",
      @fake_codex
    ])

    Application.put_env(:hal_c2, :claude_command, [
      "env",
      "FAKE_CLAUDE_TRACE=#{Process.get({:trace, :claude})}",
      "python3",
      "-u",
      @fake_claude
    ])

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

    for {tid, selection} <- Map.values(@threads) do
      :ok = HalC2.Streams.subscribe(tid, self(), nil)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.create",
          "threadId" => tid,
          "projectId" => "project-1",
          "title" => tid,
          "modelSelection" => selection,
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "worktreePath" => work
        })
    end
  end

  # --- model ----------------------------------------------------------------------

  # workers: whether the setting keeps agents to HAL-C2's workers; codex: the choice the
  # Codex session kept when it started its native thread, nil while it has none;
  # turns: each thread's completed turns.
  def initial_state, do: %{workers: false, codex: nil, turns: %{codex: 0, claude: 0}}

  def command(_state) do
    frequency([
      {2, {:call, __MODULE__, :choose, [oneof([:provider, :workers])]}},
      {4, {:call, __MODULE__, :turn, [oneof([:codex, :claude])]}},
      {1, {:call, __MODULE__, :release, [oneof([:codex, :claude])]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :choose, [choice]}),
    do: %{state | workers: choice == :workers}

  def next_state(state, _result, {:call, _, :turn, [provider]}) do
    state = update_in(state.turns[provider], &(&1 + 1))
    if provider == :codex, do: %{state | codex: state.codex || {state.workers}}, else: state
  end

  def next_state(state, _result, {:call, _, :release, [:codex]}), do: %{state | codex: nil}
  def next_state(state, _result, {:call, _, :release, [:claude]}), do: state

  def postcondition(state, {:call, _, :turn, [:claude]}, seen) do
    seen == %{
      completed: state.turns.claude + 1,
      disallowed: if(state.workers, do: "Agent,Task"),
      prompt: told_to(state.workers)
    }
  end

  # A turn that starts the native thread (a session's first) carries the features the
  # session keeps; the turns after it start none.
  def postcondition(state, {:call, _, :turn, [:codex]}, seen) do
    {workers} = state.codex || {state.workers}

    seen == %{
      completed: state.turns.codex + 1,
      features: if(state.codex, do: :none, else: {:started, if(workers, do: @off)}),
      instructions: told_to(workers)
    }
  end

  def postcondition(_state, _call, result), do: result == :ok

  defp told_to(true), do: :workers
  defp told_to(false), do: :anything

  # --- commands -------------------------------------------------------------------

  def choose(choice) do
    {doc, version} = HalC2.Settings.get()
    value = if choice == :workers, do: "hal-c2", else: "provider"
    {:ok, _} = HalC2.Settings.put(Map.put(doc, "nativeSubagents", value), version)
    :ok
  end

  # Runs one turn to its end and says what the provider was told for it.
  def turn(provider) do
    {tid, selection} = @threads[provider]

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => tid,
        "messageId" => "m#{System.unique_integer([:positive])}",
        "text" => "hello",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    completed = await_turns(tid, System.monotonic_time(:millisecond) + @wait_ms)
    told(provider, new_trace(provider)) |> Map.put(:completed, completed)
  end

  def release(provider) do
    {tid, _} = @threads[provider]
    :ok = Orchestration.release_session(tid)
    :ok
  end

  # The Claude CLI running the turn is the last one started: its argv opens its trace.
  defp told(:claude, _entries) do
    argv =
      trace(:claude)
      |> Enum.filter(&is_map_key(&1, "argv"))
      |> List.last()
      |> Map.fetch!("argv")

    %{
      disallowed: flag(argv, "--disallowedTools"),
      prompt: told(flag(argv, "--append-system-prompt"))
    }
  end

  defp told(:codex, entries) do
    requests = for %{"in" => %{"method" => method} = request} <- entries, do: {method, request}

    started =
      for {method, request} <- requests,
          method in ~w(thread/start thread/resume),
          do: {:started, get_in(request, ["params", "config", "features"])}

    [instructions] =
      for {"turn/start", request} <- requests,
          do:
            get_in(request, [
              "params",
              "collaborationMode",
              "settings",
              "developer_instructions"
            ])

    %{features: List.first(started, :none), instructions: told(instructions)}
  end

  # Whether the instructions keep the agent to HAL-C2's workers, short for a report.
  defp told(text) do
    cond do
      text == HalC2.Mcp.instructions(true) -> :workers
      text == HalC2.Mcp.instructions(false) -> :anything
      true -> {:other, text}
    end
  end

  defp flag(argv, name) do
    case Enum.find_index(argv, &(&1 == name)) do
      nil -> nil
      i -> Enum.at(argv, i + 1)
    end
  end

  # --- the real side ----------------------------------------------------------------

  defp trace(provider) do
    case File.read(Process.get({:trace, provider})) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  # The trace entries since the last call: what this turn sent.
  defp new_trace(provider) do
    entries = trace(provider)
    read = Process.put({:read, provider}, length(entries))
    Enum.drop(entries, read)
  end

  # Waits until the thread has no run left unfinished, and returns how many completed.
  defp await_turns(tid, deadline) do
    flush(tid)
    runs = StreamState.list(current(tid), "run")

    if Enum.all?(runs, &(&1["status"] in ~w(completed failed interrupted cancelled))) do
      Enum.count(runs, &(&1["status"] == "completed"))
    else
      receive do
        {:hal_c2_stream, ^tid, _} -> await_turns(tid, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, runs}
      end
    end
  end

  defp flush(tid) do
    receive do
      {:hal_c2_stream, ^tid, _} -> flush(tid)
    after
      0 -> :ok
    end
  end

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
end
