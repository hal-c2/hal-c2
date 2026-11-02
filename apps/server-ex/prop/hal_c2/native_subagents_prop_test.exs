defmodule HalC2.NativeSubagentsPropTest do
  @moduledoc """
  A state machine over the subagents setting (`nativeSubagents`) and three threads, on
  Codex (`HalC2.Codex.ThreadRuntime`), Claude (`HalC2.Claude.ThreadRuntime`) and Kimi
  CLI (`HalC2.Acp.ThreadRuntime`):
  switch the setting between the provider's own subagents and HAL-C2's workers, run a
  turn on either thread, and release either thread's provider session.

  The promise: a Claude turn runs on a CLI started with the setting as it was when the
  turn began, its `Agent` and `Task` tools taken away and its prompt telling it to
  delegate exactly when the choice is HAL-C2's workers. A Codex thread reads the choice
  when its session starts its native thread and keeps it until the session is
  released: the native thread's subagent features and every turn's instructions follow
  the kept choice, whatever the setting says meanwhile. Kimi, whose Agent tool cannot be
  taken away, is told the choice with the first prompt of each session it opens, and
  nothing with the prompts after it.

  Turns run on the fakes in `test/support/fake_codex.py`, `fake_claude.py` and
  `fake_acp_scripted.py`, which append what they are sent to a trace the test reads
  after each turn completes.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @threads %{
    codex: {"codex-thread", %{"instanceId" => "codex", "model" => "gpt-5.4"}},
    claude: {"claude-thread", %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}},
    kimi: {"kimi-thread", %{"instanceId" => "kimi", "model" => "fake/one"}}
  }
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @fake_acp Path.expand("../../test/support/fake_acp_scripted.py", __DIR__)
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
        Application.delete_env(:hal_c2, :acp_commands)
        HalC2.Acp.forget("kimi")

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

    # The fake ACP agent logs to `log.jsonl` in its directory.
    kimi = Path.join(home, "kimi")
    File.mkdir_p!(kimi)
    Process.put({:trace, :kimi}, Path.join(kimi, "log.jsonl"))
    Process.put({:read, :kimi}, 0)

    File.write!(
      Path.join(kimi, "config.json"),
      JSON.encode!(%{"capabilities" => %{"mcpCapabilities" => %{"http" => true}}})
    )

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

    Application.put_env(:hal_c2, :acp_commands, %{
      "kimi" => ["env", "FAKE_DIR=#{kimi}", "python3", "-u", @fake_acp]
    })

    HalC2.Acp.forget("kimi")

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

    {doc, version} = HalC2.Settings.get()

    instances = %{
      "kimi" => %{
        "driver" => "acpRegistry",
        "enabled" => true,
        "config" => %{"agentId" => "kimi"}
      }
    }

    {:ok, _} = HalC2.Settings.put(Map.put(doc, "providerInstances", instances), version)

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
  # Codex session kept when it started its native thread, nil while it has none; kimi:
  # whether the Kimi thread holds a session; turns: each thread's completed turns.
  def initial_state,
    do: %{workers: false, codex: nil, kimi: false, turns: %{codex: 0, claude: 0, kimi: 0}}

  def command(_state) do
    frequency([
      {2, {:call, __MODULE__, :choose, [oneof([:provider, :workers])]}},
      {4, {:call, __MODULE__, :turn, [oneof([:codex, :claude, :kimi])]}},
      {1, {:call, __MODULE__, :release, [oneof([:codex, :claude, :kimi])]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :choose, [choice]}),
    do: %{state | workers: choice == :workers}

  def next_state(state, _result, {:call, _, :turn, [provider]}) do
    state = update_in(state.turns[provider], &(&1 + 1))

    case provider do
      :codex -> %{state | codex: state.codex || {state.workers}}
      :kimi -> %{state | kimi: true}
      :claude -> state
    end
  end

  def next_state(state, _result, {:call, _, :release, [:codex]}), do: %{state | codex: nil}
  def next_state(state, _result, {:call, _, :release, [:kimi]}), do: %{state | kimi: false}
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

  # A turn that opens a session announces HAL-C2's tools with its prompt.
  def postcondition(state, {:call, _, :turn, [:kimi]}, seen) do
    seen == %{
      completed: state.turns.kimi + 1,
      instructions: if(state.kimi, do: :none, else: told_to(state.workers))
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

  defp told(:kimi, entries) do
    [text] =
      for %{
            "recv" => %{
              "method" => "session/prompt",
              "params" => %{"prompt" => [%{"text" => t} | _]}
            }
          } <-
            entries,
          do: t

    instructions =
      case Regex.run(
             ~r{<hal_c2_orchestration_instructions>(.*)</hal_c2_orchestration_instructions>}s,
             text
           ) do
        [_, instructions] -> told(instructions)
        nil -> :none
      end

    %{instructions: instructions}
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
  # A session's instructions are the orchestration text with the mode, browser
  # and runtime sections around it (`HalC2.Mcp.Instructions`), so classify by
  # what they contain, not by equality with the orchestration text alone.
  defp told(text) do
    cond do
      is_binary(text) and String.contains?(text, HalC2.Mcp.workers_only_note()) -> :workers
      is_binary(text) and String.contains?(text, HalC2.Mcp.instructions()) -> :anything
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
