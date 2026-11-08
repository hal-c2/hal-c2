defmodule HalC2.ClaudeSessionPropTest do
  @moduledoc """
  A state machine over the turns of one Claude thread (`HalC2.Claude.ThreadRuntime`)
  on the fake CLI in `test/support/fake_claude.py`: turns on one model or another,
  with fast mode on, off or unset, that say hello, leave a subagent and a command
  running in the background, put Claude's own session in plan mode (EnterPlanMode), or
  ask which mode the session runs in, compact the conversation (`/compact`), or that
  Claude acknowledges without ever starting a turn for; and the user stopping the
  thread between turns. Every resumed process first runs a turn of its own, reporting a
  background task the previous one left behind. Each process is handed HAL-C2's MCP
  server over stdin, which Claude takes or refuses (`HalC2.Claude.Session`), and a
  turn can ask which tools it has. A turn on a new process can find Claude slow to
  answer about that server, so its message is held: meanwhile the MC can go down and
  the next one adopt the process (it runs durable), and the user can stop the turn,
  until Claude answers. Between turns Claude's settings in the project can turn
  bypassing permissions off, and Auto mode with it, the MC can let go of the thread's
  runtime, as on a restart, and, with no Claude process up, Claude can lose what the
  session's transcript held (its messages, or the whole file), as when it went down
  before saving a prompt.

  The promise: a turn on another selection (fast mode off and unset are one) while
  background work runs is refused, and the work and its Claude process are kept; any
  other turn runs, on the same process when the selection is the same, so the work
  survives it. Stopping between turns ends the background work with its process. Plan
  mode Claude entered itself lasts one turn: the next one runs in the thread's mode. A
  prompt Claude acknowledges but never starts a turn for fails, and keeps the process.
  A turn Claude runs by itself never ends the user's: each turn ends on its own result,
  and `/compact` once its compaction is in. A `/compact` before any turn has started
  Claude's session has nothing to compact, and is refused without starting Claude.
  Every user message reaches Claude, whether its process took HAL-C2's server or
  refused it, and the process has HAL-C2's tools exactly when it took them. A held
  message reaches Claude once it answers, across an MC that went down meanwhile, and a
  stop sent while it is held ends its turn as interrupted. A Full access turn runs in
  bypass mode, in Auto when Claude's settings turn bypass off, and in the default
  mode when they turn Auto off too: each turn reads them again. The message of a turn
  refused for background work reaches Claude with the next turn's, before it; a
  `/compact` reaches Claude as the command alone, and leaves them for the turn after;
  a refused one is not passed on. A new process resumes the thread's session, unless
  that session lost its transcript or its last prompt handed the thread over
  unconfirmed: then it starts a new one, handed the whole thread, which the next
  process resumes.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Claude.ThreadRuntime
  alias HalC2.Orchestration.Recovery
  alias HalC2.Subprocess.Durable

  @moduletag timeout: :infinity

  @tid "claude-session-thread"
  @models ~w(claude-opus-4-6 claude-opus-4-5)
  @texts %{
    hello: "hello",
    background: "survey in the background",
    enter_plan: "enter plan mode yourself",
    which_mode: "which mode",
    compact: "/compact",
    never_start: "never start a turn",
    which_tools: "which tools",
    halfway: "answer halfway"
  }
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 15_000

  property "a Claude thread keeps its background work across the turns it allows",
    numtests: HalC2.Prop.numtests(20),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :claude_command)
        System.delete_env("FAKE_CLAUDE_ORPHANED")
        System.delete_env("FAKE_CLAUDE_MCP_REFUSE")
        System.delete_env("FAKE_CLAUDE_MCP_HOLD")
        System.delete_env("CLAUDE_CONFIG_DIR")
        System.delete_env("FAKE_CLAUDE_INPUT_LOG")
        Enum.each(~w(FAKE_SESSIONS FAKE_CLAUDE_TRACE), &System.delete_env/1)
        Application.put_env(:hal_c2, :durable_programs, false)
        Application.delete_env(:hal_c2, :claude_interrupt_timeout_ms)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("claude-session")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    # Claude's own settings are the scratch home's, never the user's (`policy/1`).
    config = Path.join(home, "claude")
    File.mkdir_p!(config)
    System.put_env("CLAUDE_CONFIG_DIR", config)
    Process.put(:work, work)
    # Every message Claude reads, one JSON string a line (`sent/1`).
    System.put_env("FAKE_CLAUDE_INPUT_LOG", Path.join(home, "input.log"))
    # The fake keeps transcripts as Claude does, in that home, and traces its argv.
    System.put_env("FAKE_SESSIONS", "1")
    System.put_env("FAKE_CLAUDE_TRACE", Path.join(home, "claude-trace.jsonl"))
    Application.put_env(:hal_c2, :claude_command, ["python3", "-u", @fake_claude])
    # Durable, so a process outlives the MC that started it (`adopt/0`).
    Application.put_env(:hal_c2, :durable_programs, true)
    # A stopped turn is Claude's to end: no settling it while its message is held.
    Application.put_env(:hal_c2, :claude_interrupt_timeout_ms, 600_000)
    System.put_env("FAKE_CLAUDE_ORPHANED", "task-agent-1")

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      {Registry, keys: :unique, name: HalC2.Claude.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
        id: :codex_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
        id: :pi_registry
      ),
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
      HalC2.Settings,
      HalC2.Mcp
    ])

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Claude",
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => hd(@models)},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok
  end

  # --- model ----------------------------------------------------------------------

  # launch: the selection the thread's Claude process runs ({model, fast mode on}), or
  #   nil before the first turn; session: whether that process is up; background:
  #   whether work it left running in the background still runs; refusing: whether a
  #   process started now refuses HAL-C2's server; tools: whether the thread's process
  #   took it; held: the turn whose message waits on Claude's answer about the
  #   server (%{n, text, interrupted}), or nil; policy: what Claude's settings turn
  #   off (`policy/1`); missed: the texts of turns refused since a message last reached
  #   Claude, oldest first; lost: whether the session's transcript lost what it held;
  #   marked: whether the last prompt handed the thread over and Claude never started
  #   it; n: a counter.
  def initial_state,
    do: %{
      launch: nil,
      session: false,
      background: false,
      refusing: false,
      tools: false,
      held: nil,
      policy: :allowed,
      missed: [],
      lost: false,
      marked: false,
      n: 1
    }

  @turn_texts Map.keys(@texts) -- [:halfway]
  @full_access_modes %{allowed: "bypassPermissions", no_bypass: "auto", no_auto: "default"}
  @held_texts [:hello, :which_tools, :halfway]

  def command(%{held: nil, n: n}) do
    frequency([
      {6,
       {:call, __MODULE__, :turn,
        [n, oneof(@models), oneof([:unset, false, true]), oneof(@turn_texts)]}},
      {1, {:call, __MODULE__, :stop, []}},
      {1, {:call, __MODULE__, :refuse_tools, [boolean()]}},
      {1, {:call, __MODULE__, :policy, [oneof([:allowed, :no_bypass, :no_auto])]}},
      {2,
       {:call, __MODULE__, :held_turn,
        [n, oneof(@models), oneof([:unset, false, true]), oneof(@held_texts)]}},
      {2, {:call, __MODULE__, :let_go, []}},
      {2, {:call, __MODULE__, :lose, [oneof([:messages, :file])]}}
    ])
  end

  def command(%{held: %{text: :halfway, interrupted: false}}),
    do:
      frequency([
        {2, {:call, __MODULE__, :interrupt, []}},
        {1, {:call, __MODULE__, :adopt, []}}
      ])

  def command(%{held: held}),
    do:
      frequency([
        {2, {:call, __MODULE__, :release, [held.n]}},
        {1, {:call, __MODULE__, :adopt, []}}
      ])

  # A held turn starts a new process; one half-answered runs until it is stopped. The
  # fake answers a message by what it finds in it, so a refused "never start a turn"
  # would fail every turn that carries it, and a held turn's answer is checked whole.
  # One that hands the thread over is not modelled.
  def precondition(%{held: nil} = state, {:call, _, :held_turn, [_n, model, fast, _text]}),
    do:
      not reused?(state, model, fast) and not refused?(state, model, fast) and
        state.missed == [] and not state.marked and not state.lost

  # How `/compact` meets a session that has to start over is not modelled.
  def precondition(%{held: nil} = state, {:call, _, :turn, [_n, model, fast, text]}),
    do:
      not (refused?(state, model, fast) and text == :never_start) and
        not (text == :compact and (state.marked or state.lost))

  # The MC lets go of an idle runtime only; a transcript is lost with no process up.
  def precondition(%{held: nil} = state, {:call, _, :let_go, []}),
    do: state.session and not state.background

  def precondition(%{held: nil} = state, {:call, _, :lose, [_]}),
    do: state.launch != nil and not state.session and not state.lost

  def precondition(%{held: nil}, {:call, _, name, _}),
    do: name in [:turn, :stop, :refuse_tools, :policy]

  def precondition(%{held: held}, {:call, _, :release, [n]}),
    do: held.n == n and (held.text != :halfway or held.interrupted)

  def precondition(%{held: held}, {:call, _, :interrupt, []}),
    do: held.text == :halfway and not held.interrupted

  def precondition(%{held: %{}}, {:call, _, name, _}), do: name == :adopt

  def next_state(state, _result, {:call, _, :turn, [_n, model, fast, text]}) do
    state = %{state | n: state.n + 1}

    cond do
      # A refused `/compact` is not quoted to the next turn: it would compact nothing.
      refused?(state, model, fast) and text == :compact -> state
      refused?(state, model, fast) -> %{state | missed: state.missed ++ [text]}
      empty_compact?(state, text) -> state
      true -> ran(state, model, fast, text)
    end
  end

  defp ran(state, model, fast, text),
    do: %{
      state
      | launch: {model, fast == true},
        session: true,
        # The fake reads "never start a turn" before "in the background".
        background:
          state.background or text == :background or
            (text != :never_start and carries?(state, :background, text)),
        tools: if(reused?(state, model, fast), do: state.tools, else: not state.refusing),
        missed: if(text == :compact, do: state.missed, else: []),
        lost: false,
        marked: handed?(state) and text == :never_start
    }

  def next_state(state, _result, {:call, _, :refuse_tools, [refusing]}),
    do: %{state | refusing: refusing}

  def next_state(state, _result, {:call, _, :policy, [policy]}), do: %{state | policy: policy}
  def next_state(state, _result, {:call, _, :let_go, []}), do: %{state | session: false}
  def next_state(state, _result, {:call, _, :lose, [_]}), do: %{state | lost: true}

  def next_state(state, _result, {:call, _, :held_turn, [n, model, fast, text]}),
    do: %{
      state
      | n: state.n + 1,
        launch: {model, fast == true},
        session: true,
        tools: not state.refusing,
        held: %{n: n, text: text, interrupted: false}
    }

  def next_state(state, _result, {:call, _, :release, [_n]}), do: %{state | held: nil}

  def next_state(state, _result, {:call, _, :interrupt, []}),
    do: put_in(state.held.interrupted, true)

  def next_state(state, _result, {:call, _, :adopt, []}), do: state

  def next_state(%{background: true} = state, _result, {:call, _, :stop, []}),
    do: %{state | session: false, background: false}

  def next_state(state, _result, {:call, _, :stop, []}), do: state

  # Whether this turn hands Claude the refused message `missed` along with its own.
  defp carries?(state, missed, text), do: text != :compact and missed in state.missed

  # A turn runs on the same process when its selection is, and no handoff went
  # unconfirmed.
  defp reused?(state, model, fast),
    do: state.session and state.launch == {model, fast == true} and not state.marked

  defp refused?(state, model, fast),
    do: state.background and state.launch != {model, fast == true}

  # No turn has started Claude's session yet, so it has no conversation to compact.
  defp empty_compact?(state, text), do: text == :compact and state.launch == nil

  # Whether a turn's Claude starts a new session rather than resume one.
  defp fresh?(state),
    do: state.launch == nil or state.marked or (state.lost and not state.session)

  # Whether it is handed the thread: a new session after earlier turns.
  defp handed?(state), do: fresh?(state) and state.launch != nil

  # Whether history goes before its text: the whole thread, or the refused turns'.
  defp history?(state, text), do: handed?(state) or (text != :compact and state.missed != [])

  def postcondition(state, {:call, _, :turn, [_n, model, fast, text]} = call, seen) do
    cond do
      refused?(state, model, fast) ->
        seen.status == "failed" and seen.reused and seen.background and seen.sent == []

      empty_compact?(state, text) ->
        seen.status == "failed" and not seen.background and seen.compactions == 0

      text == :never_start ->
        seen.status == "failed" and started?(state, model, fast, text, seen) and
          seen.background == state.background and
          sent?(state, text, seen.sent)

      # The fake answers what it finds first in a message, so one that carries refused
      # messages is checked by what reached Claude, not by its answer.
      text != :compact and state.missed != [] ->
        seen.status == "completed" and started?(state, model, fast, text, seen) and
          seen.background == next_state(state, seen, call).background and
          sent?(state, text, seen.sent)

      true ->
        # A turn ends on its own answer, not on the one a turn of Claude's own gave.
        seen.status == "completed" and started?(state, model, fast, text, seen) and
          seen.background == (state.background or text == :background) and
          (text != :which_mode or seen.reply == "mode #{@full_access_modes[state.policy]}") and
          (text != :hello or seen.reply == "Hello from claude") and
          (text != :which_tools or
             seen.reply ==
               if(next_state(state, seen, call).tools,
                 do: "tools: hal-c2",
                 else: "tools: none"
               )) and
          seen.compactions == if(text == :compact, do: 1, else: 0) and
          sent?(state, text, seen.sent)
    end
  end

  # What reached Claude for a turn that ran: its text, after those of the turns refused
  # before it, oldest first, and the thread's history when handed it; a `/compact` alone.
  defp sent?(state, text, [sent]) do
    own = @texts[text]

    if not history?(state, text),
      do: sent == own,
      else:
        String.ends_with?(sent, "\n\n" <> own) and
          ordered?(String.replace_suffix(sent, own, ""), Enum.map(state.missed, &@texts[&1]))
  end

  defp sent?(_state, _text, _sent), do: false

  defp ordered?(_sent, []), do: true

  defp ordered?(sent, [text | rest]) do
    case String.split(sent, text, parts: 2) do
      [_, after_text] -> ordered?(after_text, rest)
      _ -> false
    end
  end

  def postcondition(state, {:call, _, :stop, []}, seen),
    do: seen == %{stopped: state.background, background: false}

  def postcondition(_state, {:call, _, :refuse_tools, [_]}, seen), do: seen == :ok
  def postcondition(_state, {:call, _, :policy, [_]}, seen), do: seen == :ok
  def postcondition(_state, {:call, _, :let_go, []}, seen), do: seen == :ok
  def postcondition(_state, {:call, _, :lose, [_]}, _seen), do: true

  # A new process starts a new session when `fresh?/1`, else resumes the thread's own;
  # and history goes before the text only as `history?/2` says.
  defp started?(state, model, fast, text, seen) do
    reused = reused?(state, model, fast)

    seen.reused == reused and seen.handed == history?(state, text) and
      if reused,
        do: seen.starts == [],
        else:
          seen.starts != [] and
            resumed(List.last(seen.starts)) ==
              if(fresh?(state), do: nil, else: seen.native)
  end

  defp resumed(argv) do
    case Enum.drop_while(argv, &(&1 != "--resume")) do
      ["--resume", id | _] -> id
      _ -> nil
    end
  end

  # Nothing reaches Claude before it has answered about the server.
  def postcondition(_state, {:call, _, :held_turn, _}, seen),
    do: seen == %{status: "running", held: true}

  def postcondition(%{held: held} = state, {:call, _, :release, [_n]}, seen) do
    if held.interrupted,
      do: seen.status == "interrupted",
      else:
        seen.status == "completed" and
          seen.reply ==
            if(held.text == :hello,
              do: "Hello from claude",
              else: if(state.tools, do: "tools: hal-c2", else: "tools: none")
            )
  end

  def postcondition(_state, {:call, _, :interrupt, []}, seen),
    do: seen == %{stopped: true, held: true}

  def postcondition(_state, {:call, _, :adopt, []}, seen),
    do: seen == %{adopted: :ok, held: true}

  # --- commands -------------------------------------------------------------------

  # Sends a message on a selection and waits for its run to end: how it ended, whether
  # the thread's Claude process is the one before, whether background work runs, and
  # what Claude said.
  def turn(n, model, fast, text) do
    before = current(@tid)
    runs = MapSet.new(StreamState.list(before, "run"), & &1["id"])
    session = session()
    read = read_lines()
    traced = length(trace())
    native = native(before)

    dispatch(n, model, fast, text)
    run = await_run(runs, System.monotonic_time(:millisecond) + @wait_ms)
    state = current(@tid)
    new = Enum.drop(trace(), traced)
    sent = sent(read)

    %{
      status: run["status"],
      reused: session != nil and session() == session,
      background: background?(),
      reply: reply(state, run),
      compactions: Enum.count(items(state, run), &(&1["type"] == "compaction")),
      sent: sent,
      starts: for(%{"argv" => argv} <- new, do: argv),
      handed: Enum.any?(sent, &(&1 =~ "<conversation_history>")),
      native: native
    }
  end

  # The messages Claude read since `read` lines of its input log.
  defp sent(read) do
    case File.read(System.fetch_env!("FAKE_CLAUDE_INPUT_LOG")) do
      {:ok, log} ->
        log |> String.split("\n", trim: true) |> Enum.drop(read) |> Enum.map(&Jason.decode!/1)

      {:error, :enoent} ->
        []
    end
  end

  defp read_lines do
    case File.read(System.fetch_env!("FAKE_CLAUDE_INPUT_LOG")) do
      {:ok, log} -> length(String.split(log, "\n", trim: true))
      {:error, :enoent} -> 0
    end
  end

  defp dispatch(n, model, fast, text) do
    options = if fast == :unset, do: [], else: [%{"id" => "fastMode", "value" => fast}]

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => @texts[text],
        "attachments" => [],
        "modelSelection" => %{
          "instanceId" => "claudeAgent",
          "model" => model,
          "options" => options
        },
        "dispatchMode" => %{"type" => "start_immediately"}
      })
  end

  defp items(state, run) do
    for item <- Enum.sort_by(StreamState.list(state, "turn-item"), & &1["ordinal"]),
        item["runId"] == run["id"],
        do: item
  end

  defp reply(state, run),
    do:
      List.last(
        for %{"type" => "assistant_message"} = item <- items(state, run), do: item["text"]
      )

  defp release_file(n), do: Path.join(Application.fetch_env!(:hal_c2, :home), "release-#{n}")

  # Claude's settings in the project: nothing turned off, bypassing permissions, or
  # bypassing and Auto mode.
  def policy(policy) do
    path = Path.join([Process.get(:work), ".claude", "settings.local.json"])
    File.mkdir_p!(Path.dirname(path))
    off = %{"permissions" => %{"disableBypassPermissionsMode" => "disable"}}

    settings =
      case policy do
        :allowed -> %{}
        :no_bypass -> off
        :no_auto -> Map.put(off, "disableAutoMode", "disable")
      end

    File.write!(path, Jason.encode!(settings))
  end

  # Whether the next Claude process refuses the MCP servers it is handed.
  def refuse_tools(true), do: System.put_env("FAKE_CLAUDE_MCP_REFUSE", "1")
  def refuse_tools(false), do: System.delete_env("FAKE_CLAUDE_MCP_REFUSE")

  # A turn on a new process whose answer about HAL-C2's server waits on a file:
  # returns once its message is held.
  def held_turn(n, model, fast, text) do
    System.put_env("FAKE_CLAUDE_MCP_HOLD", release_file(n))
    # The turn the user stops starts on a process with nothing of its own to report:
    # the fake would run that report to its result before it read the stop, where
    # Claude stops the turn it is running.
    if text == :halfway, do: System.put_env("FAKE_CLAUDE_ORPHANED", "")
    runs = ended_runs()
    dispatch(n, model, fast, text)
    held = await_held(System.monotonic_time(:millisecond) + @wait_ms)
    System.delete_env("FAKE_CLAUDE_MCP_HOLD")
    System.put_env("FAKE_CLAUDE_ORPHANED", "task-agent-1")
    run = Enum.find(StreamState.list(current(@tid), "run"), &(not MapSet.member?(runs, &1["id"])))
    %{status: run["status"], held: held}
  end

  # Claude answers about the server: the held turn runs, and ends.
  def release(n) do
    runs = ended_runs()
    File.write!(release_file(n), "")
    run = await_run(runs, System.monotonic_time(:millisecond) + @wait_ms)
    %{status: run["status"], reply: reply(current(@tid), run)}
  end

  # The MC goes down with the message held, and the next one adopts the process.
  def adopt do
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, @tid)
    session = Process.monitor(:sys.get_state(runtime).session)
    Recovery.leaving(true)
    GenServer.stop(runtime, :shutdown)

    receive do
      {:DOWN, ^session, :process, _, _} -> :ok
    after
      @wait_ms -> raise "the session outlived its runtime"
    end

    Recovery.leaving(false)
    survivor = Map.fetch!(Durable.survivors_peek(), @tid)
    %{adopted: ThreadRuntime.adopt(@tid, survivor), held: held?()}
  end

  # The user stops the turn whose message is held.
  def interrupt do
    stopped = ThreadRuntime.interrupt(@tid, nil) == :ok
    %{stopped: stopped, held: held?()}
  end

  # The MC lets go of the thread's idle runtime, as IdleSessions or a restart does.
  def let_go do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, @tid)
    ref = Process.monitor(pid)
    :ok = GenServer.call(pid, :release)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @wait_ms -> raise "the runtime was not let go of"
    end
  end

  # Claude loses what the thread's session saved: its messages, or the transcript.
  def lose(what) do
    path =
      HalC2.PortableSessions.claude_transcript(
        "claudeAgent",
        native(current(@tid)),
        Process.get(:work)
      )

    case what do
      :file ->
        File.rm!(path)

      :messages ->
        kept = path |> File.stream!() |> Enum.reject(&(JSON.decode!(&1)["type"] == "user"))
        File.write!(path, kept)
    end
  end

  # The user stops the thread between turns.
  def stop do
    stopped = HalC2.Claude.ThreadRuntime.interrupt(@tid, nil) == :ok
    %{stopped: stopped, background: background?()}
  end

  # --- the runtime ------------------------------------------------------------------

  defp runtime do
    case Registry.lookup(HalC2.Claude.Registry, @tid) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> nil
    end
  end

  defp session do
    case runtime() do
      %{session: session} when is_pid(session) -> if Process.alive?(session), do: session
      _ -> nil
    end
  end

  # Whether the thread's Claude session holds a message for Claude's answer.
  defp held? do
    case session() do
      nil -> false
      session -> :sys.get_state(session).held != []
    end
  end

  # Until the runtime has a turn and its session holds the turn's message.
  defp await_held(deadline) do
    case runtime() do
      %{turn: turn} when turn != nil ->
        held?()

      _ ->
        receive do
          {:hal_c2_stream, @tid, _} -> await_held(deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> raise "the turn never started"
        end
    end
  end

  defp ended_runs do
    for run <- StreamState.list(current(@tid), "run"),
        run["status"] in ["completed", "failed", "interrupted"],
        into: MapSet.new(),
        do: run["id"]
  end

  defp background? do
    case runtime() do
      %{work: work} -> Enum.any?(work, fn {_, work} -> work.background end)
      nil -> false
    end
  end

  # Until a run not in `runs` has ended; the runtime has handled its end by then.
  defp await_run(runs, deadline) do
    run =
      current(@tid)
      |> StreamState.list("run")
      |> Enum.find(
        &(not MapSet.member?(runs, &1["id"]) and
            &1["status"] in ["completed", "failed", "interrupted"])
      )

    if run do
      runtime()
      run
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_run(runs, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> raise "the turn never ended"
      end
    end
  end

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))

  defp native(state) do
    state
    |> StreamState.list("provider-thread")
    |> Enum.find_value(&get_in(&1, ["nativeThreadRef", "nativeId"]))
  end

  # What the fake was started with and sent, oldest first.
  defp trace do
    case File.read(System.fetch_env!("FAKE_CLAUDE_TRACE")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end
end
