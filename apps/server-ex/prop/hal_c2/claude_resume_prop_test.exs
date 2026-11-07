defmodule HalC2.ClaudeResumePropTest do
  @moduledoc """
  A state machine over where one Claude thread (`HalC2.Claude.ThreadRuntime`) resumes
  its conversation, on the fake CLI in `test/support/fake_claude.py`: turns Claude
  answers ("where are we", which says the message its process resumed at), turns the
  user stops after Claude wrote part of its answer ("answer halfway") or before it
  wrote anything ("wait"), turns Claude cannot be started for, rewinds to a message an earlier turn ended at (or to the
  thread's start, or to a message Claude cannot resume at, which ends its process at
  startup as a subagent's message does), and the idle sweep letting go of the thread's
  Claude process.

  A rewind is played as the orchestration plays one: `ThreadRuntime.rollback/2`, and
  its patch on the provider thread.

  The promise: a new Claude process resumes at the message the last rewind went back
  to, as long as no turn since had Claude write anything; once one did, it resumes
  the whole conversation. A live process keeps the conversation it has. A turn that
  fails because Claude cannot resume at the message lets the next one resume the whole
  conversation, so the thread recovers by itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Claude.ThreadRuntime

  @moduletag timeout: :infinity

  @tid "claude-resume-thread"
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 15_000

  property "a new Claude process resumes where the conversation was left",
    numtests: HalC2.Prop.numtests(100),
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
    home = HalC2.Prop.scratch_home("claude-resume")
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
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-opus-4-6"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok
  end

  # --- model ----------------------------------------------------------------------

  # The fake cannot resume at a subagent's message, as Claude Code cannot, and exits.
  @broken "sub-uuid-1"

  # session: whether the thread's Claude process is up; resumed: the message that
  #   process resumed at (nil: the whole conversation, or a new one); turns: how many
  #   messages it has taken, which the fake numbers its answers by (uuid-N);
  #   pinned: the message a new process would resume at (@broken: one it cannot);
  #   heads: the messages turns Claude answered ended at, which a rewind can go back
  #   to; n: a counter.
  def initial_state,
    do: %{session: false, resumed: nil, turns: 0, pinned: nil, heads: [], n: 1}

  def command(%{n: n} = state) do
    # Mostly when it matters: a turn a new process starts at the message a rewind went
    # back to, which a later process must resume at again unless Claude wrote in it.
    pending = state.pinned != nil and not state.session

    frequency(
      [
        {4, {:call, __MODULE__, :answered, [n]}},
        {if(pending, do: 6, else: 2),
         {:call, __MODULE__, :stopped, [n, frequency([{1, :halfway}, {2, :silent}])]}},
        {if(pending, do: 3, else: 1), {:call, __MODULE__, :unstarted, [n]}},
        # Mostly when it matters: a live process with a message a new one would resume at.
        {if(state.session and state.pinned != nil, do: 8, else: 1),
         {:call, __MODULE__, :release, []}}
      ] ++
        if(state.n > 1,
          do: [{2, {:call, __MODULE__, :rewind, [rewind_to(state.heads)]}}],
          else: []
        ) ++
        if(state.heads != [], do: [{1, {:call, __MODULE__, :rewind, [@broken]}}], else: [])
    )
  end

  # Mostly to a message an earlier turn ended at, sometimes to the thread's start.
  defp rewind_to([]), do: nil
  defp rewind_to(heads), do: frequency([{1, nil}, {3, oneof(heads)}])

  # A rewind needs a provider thread, which the first turn makes.
  # Claude only resumes at a message, @broken included, in a conversation it has.
  def precondition(state, {:call, _, :rewind, [@broken]}), do: state.heads != []
  def precondition(state, {:call, _, :rewind, _}), do: state.n > 1
  # A new process fails at startup on @broken, before the user could stop it.
  def precondition(state, {:call, _, :stopped, _}), do: not broken?(state)
  # A live process takes the message whatever its command is now.
  def precondition(state, {:call, _, :unstarted, _}), do: not state.session
  def precondition(_state, _call), do: true

  # The process exits at startup; no turn of Claude's resumed anywhere.
  def next_state(state, _result, {:call, _, :answered, [_n]})
      when not state.session and state.pinned == @broken,
      do: %{state | pinned: nil, n: state.n + 1}

  def next_state(state, _result, {:call, _, :answered, [_n]}) do
    state = message(state)
    %{state | pinned: nil, heads: Enum.uniq(["uuid-#{state.turns}" | state.heads])}
  end

  def next_state(state, _result, {:call, _, :stopped, [_n, :halfway]}),
    do: %{message(state) | pinned: nil}

  def next_state(state, _result, {:call, _, :stopped, [_n, :silent]}), do: message(state)

  # Claude never got the message: nothing about the conversation changed.
  def next_state(state, _result, {:call, _, :unstarted, [_n]}), do: %{state | n: state.n + 1}

  # Back at the thread's start, no earlier turn is left to go back to.
  def next_state(state, _result, {:call, _, :rewind, [nil]}),
    do: %{state | session: false, pinned: nil, heads: []}

  def next_state(state, _result, {:call, _, :rewind, [head]}),
    do: %{state | session: false, pinned: head}

  def next_state(state, _result, {:call, _, :release, []}), do: %{state | session: false}

  # A message reaches the live process, or a new one resuming at the pinned message.
  defp message(%{session: true} = state), do: %{state | turns: state.turns + 1, n: state.n + 1}

  defp message(state),
    do: %{state | session: true, resumed: state.pinned, turns: 1, n: state.n + 1}

  def postcondition(state, {:call, _, :answered, [_n]}, seen)
      when not state.session and state.pinned == @broken,
      do: seen.status == "failed"

  def postcondition(state, {:call, _, :answered, [_n]}, seen) do
    resumed = message(state).resumed
    # A rewind here leaves the turns it went back past in place, so a new conversation
    # takes them as history: what it carries is not this model's to say.
    seen.status == "completed" and
      String.starts_with?(seen.reply, "resumed at #{resumed || "None"} fork False ")
  end

  def postcondition(_state, {:call, _, :stopped, _}, seen), do: seen.status == "interrupted"
  def postcondition(_state, {:call, _, :unstarted, _}, seen), do: seen.status == "failed"
  def postcondition(_state, {:call, _, :rewind, _}, seen), do: seen == :ok
  def postcondition(_state, {:call, _, :release, []}, seen), do: seen == :ok

  defp broken?(state), do: not state.session and state.pinned == @broken

  # --- commands -------------------------------------------------------------------

  # A turn Claude answers with the message its process resumed at.
  def answered(n) do
    run = send_message(n, "where are we")
    run = await_run(run, &(&1["status"] in ["completed", "failed", "interrupted"]))

    reply =
      for %{"type" => "assistant_message"} = item <- StreamState.list(current(), "turn-item"),
          item["runId"] == run["id"],
          do: item["text"]

    %{status: run["status"], reply: List.last(reply)}
  end

  # A turn the user stops, after Claude wrote part of its answer or before it wrote anything.
  def stopped(n, how) do
    text = if how == :halfway, do: "answer halfway", else: "wait for me"
    run = send_message(n, text)

    # Stopped once Claude has the message, and has written in it when it is to.
    await_run(run, fn seen ->
      case runtime() do
        %{turn: %{ids: %{run: id}} = turn} when id == run ->
          # `:resumed_at` goes once Claude writes.
          how == :silent or not Map.has_key?(turn, :resumed_at)

        _ ->
          if seen["status"] in ["completed", "failed", "interrupted"],
            do: raise("the turn ended before it was stopped: #{inspect(seen)}")
      end
    end)

    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})
    run = await_run(run, &(&1["status"] in ["completed", "failed", "interrupted"]))
    %{status: run["status"]}
  end

  # A turn whose Claude cannot be started, so it fails before Claude gets the message.
  def unstarted(n) do
    command = Application.get_env(:hal_c2, :claude_command)
    Application.put_env(:hal_c2, :claude_command, ["/nonexistent/claude"])

    try do
      run = send_message(n, "where are we")
      run = await_run(run, &(&1["status"] in ["completed", "failed", "interrupted"]))
      %{status: run["status"]}
    after
      Application.put_env(:hal_c2, :claude_command, command)
    end
  end

  # Rewinds to `head` (nil: the thread's start) as the orchestration does.
  def rewind(head) do
    with {:ok, patch} <- ThreadRuntime.rollback(@tid, %{head: head}) do
      HalC2.Streams.transact(@tid, :thread, fn stream ->
        [id] = Map.keys(stream.entities["provider-thread"])
        # A patch that changes nothing is no change.
        change = Orchestration.upsert(stream, "provider-thread", id, &Map.merge(&1, patch))
        {Enum.filter([change], &is_tuple/1), :ok}
      end)
    end
  end

  # The idle sweep lets go of the thread's Claude process.
  def release do
    case Registry.lookup(HalC2.Claude.Registry, @tid) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        :ok = GenServer.call(pid, :release)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          @wait_ms -> raise "the runtime never stopped"
        end

      [] ->
        :ok
    end
  end

  # --- the runtime ------------------------------------------------------------------

  defp send_message(n, text) do
    runs = MapSet.new(StreamState.list(current(), "run"), & &1["id"])

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => text,
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await(fn ->
      Enum.find_value(StreamState.list(current(), "run"), fn run ->
        if not MapSet.member?(runs, run["id"]), do: run["id"]
      end)
    end)
  end

  defp runtime do
    case Registry.lookup(HalC2.Claude.Registry, @tid) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> nil
    end
  end

  # Until run `id` satisfies `done?`; the runtime has handled what led there by then.
  defp await_run(id, done?) do
    await(fn ->
      run = Enum.find(StreamState.list(current(), "run"), &(&1["id"] == id))
      if run && done?.(run), do: tap(run, fn _ -> runtime() end)
    end)
  end

  # Until `fun` gives a value, rechecked on each change to the thread's stream.
  defp await(fun, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    if value = fun.() do
      value
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await(fun, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> raise "never got there"
      end
    end
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
end
