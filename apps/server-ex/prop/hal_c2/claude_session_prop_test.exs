defmodule HalC2.ClaudeSessionPropTest do
  @moduledoc """
  A state machine over the turns of one Claude thread (`HalC2.Claude.ThreadRuntime`)
  on the fake CLI in `test/support/fake_claude.py`: turns on one model or another,
  with fast mode on, off or unset, that say hello, leave a subagent and a command
  running in the background, put Claude's own session in plan mode (EnterPlanMode), or
  ask which mode the session runs in, or that Claude acknowledges without ever starting
  a turn for; and the user stopping the thread between turns.

  The promise: a turn on another selection (fast mode off and unset are one) while
  background work runs is refused, and the work and its Claude process are kept; any
  other turn runs, on the same process when the selection is the same, so the work
  survives it. Stopping between turns ends the background work with its process. Plan
  mode Claude entered itself lasts one turn: the next one runs in the thread's mode. A
  prompt Claude acknowledges but never starts a turn for fails, and keeps the process.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "claude-session-thread"
  @models ~w(claude-opus-4-6 claude-opus-4-5)
  @texts %{
    hello: "hello",
    background: "survey in the background",
    enter_plan: "enter plan mode yourself",
    which_mode: "which mode",
    never_start: "never start a turn"
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
    Application.put_env(:hal_c2, :claude_command, ["python3", "-u", @fake_claude])

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
      HalC2.Settings
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
  #   whether work it left running in the background still runs; n: a counter.
  def initial_state, do: %{launch: nil, session: false, background: false, n: 1}

  def command(%{n: n}) do
    frequency([
      {6,
       {:call, __MODULE__, :turn,
        [n, oneof(@models), oneof([:unset, false, true]), oneof(Map.keys(@texts))]}},
      {1, {:call, __MODULE__, :stop, []}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [_n, model, fast, text]}) do
    state = %{state | n: state.n + 1}

    if refused?(state, model, fast),
      do: state,
      else: %{
        state
        | launch: {model, fast == true},
          session: true,
          background: state.background or text == :background
      }
  end

  def next_state(%{background: true} = state, _result, {:call, _, :stop, []}),
    do: %{state | session: false, background: false}

  def next_state(state, _result, {:call, _, :stop, []}), do: state

  defp refused?(state, model, fast),
    do: state.background and state.launch != {model, fast == true}

  def postcondition(state, {:call, _, :turn, [_n, model, fast, text]}, seen) do
    cond do
      refused?(state, model, fast) ->
        seen.status == "failed" and seen.reused and seen.background

      text == :never_start ->
        seen.status == "failed" and
          seen.reused == (state.session and state.launch == {model, fast == true}) and
          seen.background == state.background

      true ->
        seen.status == "completed" and
          seen.reused == (state.session and state.launch == {model, fast == true}) and
          seen.background == (state.background or text == :background) and
          (text != :which_mode or seen.reply == "mode bypassPermissions")
    end
  end

  def postcondition(state, {:call, _, :stop, []}, seen),
    do: seen == %{stopped: state.background, background: false}

  # --- commands -------------------------------------------------------------------

  # Sends a message on a selection and waits for its run to end: how it ended, whether
  # the thread's Claude process is the one before, whether background work runs, and
  # what Claude said.
  def turn(n, model, fast, text) do
    before = current(@tid)
    runs = MapSet.new(StreamState.list(before, "run"), & &1["id"])
    session = session()
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

    run = await_run(runs, System.monotonic_time(:millisecond) + @wait_ms)
    state = current(@tid)

    reply =
      for %{"type" => "assistant_message"} = item <-
            Enum.sort_by(StreamState.list(state, "turn-item"), & &1["ordinal"]),
          item["runId"] == run["id"],
          do: item["text"]

    %{
      status: run["status"],
      reused: session != nil and session() == session,
      background: background?(),
      reply: List.last(reply)
    }
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
end
