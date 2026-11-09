defmodule HalC2.CodexGivenUpStartPropTest do
  @moduledoc """
  A state machine over the turns of one Codex thread (`HalC2.Codex.ThreadRuntime`),
  where a turn's start may give up while Codex still takes its prompt: the runtime
  waits to claim the run, the start abandons it (as `begin_turn/2` does when its call
  to the runtime times out), and Codex runs the turn anyway, which the runtime then
  interrupts. A message may wait behind that start, in the same session.

  The promise: a turn the MC lets run never goes into a conversation that holds the
  prompt of a run whose start gave up, unless the MC already knew that conversation
  (a handoff then counts what it may have missed). A conversation Codex opened for
  such a run has an id the MC never learnt.

  The turns run on the fake app-server in `test/support/fake_codex.py` with its
  sessions on, so each new conversation has an id of its own; a turn saying "wait"
  stays open, any other is answered at once.
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
  @env ~w(CODEX_HOME FAKE_SESSIONS FAKE_CODEX_LOG)

  property "a Codex turn never goes into a conversation a given-up start left behind",
    numtests: HalC2.Prop.numtests(20),
    max_size: 8 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        saved = Map.new(@env, &{&1, System.get_env(&1)})
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)

        for {name, value} <- saved,
            do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("codex-given-up-start")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    File.mkdir_p!(Path.join(home, "codex"))
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    System.put_env("CODEX_HOME", Path.join(home, "codex"))
    System.put_env("FAKE_SESSIONS", "1")
    System.put_env("FAKE_CODEX_LOG", Path.join(home, "codex-requests.log"))
    Process.put(:log, Path.join(home, "codex-requests.log"))

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

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Codex",
        "modelSelection" => selection(),
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })
  end

  # --- model ---------------------------------------------------------------------

  # turns: each command's observed result, in order, from which the postcondition
  # reads which conversations the MC knew and which a given-up start left behind.
  def initial_state, do: %{turns: []}

  def command(state) do
    n = length(state.turns) + 1

    frequency([
      {2, {:call, __MODULE__, :answer, [n]}},
      {2, {:call, __MODULE__, :give_up, [n, boolean()]}}
    ])
  end

  def precondition(state, {:call, _, _, [n | _]}), do: n == length(state.turns) + 1

  def next_state(state, result, {:call, _, kind, _}),
    do: %{state | turns: state.turns ++ [{kind, result}]}

  def postcondition(state, {:call, _, :answer, _}, seen) do
    {_known, left} = conversations(state.turns)
    seen.status == "completed" and seen.thread not in left
  end

  def postcondition(state, {:call, _, :give_up, [_, queued]}, seen) do
    {known, left} = conversations(state.turns)
    # The given-up turn goes on where the MC knew the conversation, or opens one.
    left = if seen.wait_thread == known, do: left, else: [seen.wait_thread | left]

    seen.first == "failed" and
      if(queued, do: seen.second == "completed" and seen.queued_thread not in left, else: true)
  end

  # The conversation the MC last learnt and those given-up starts left behind.
  defp conversations(turns) do
    Enum.reduce(turns, {nil, []}, fn
      {:answer, %{thread: thread}}, {_known, left} ->
        {thread, left}

      {:give_up, seen}, {known, left} ->
        left = if seen.wait_thread == known, do: left, else: [seen.wait_thread | left]
        {seen[:queued_thread] || known, left}
    end)
  end

  # --- commands ------------------------------------------------------------------

  # The user sends "hello n", which Codex answers.
  def answer(n) do
    text = "hello #{n}"
    {:ok, _} = Orchestration.dispatch(message(text))
    run = await_run(text, &(&1["status"] in ~w(completed failed interrupted cancelled)))
    settle_runtime()
    %{status: run["status"], thread: turn_thread(text)}
  end

  # The start of "wait n" gives up while the runtime waits to claim its run, with
  # "hello n" queued behind it when `queued`; then Codex runs "wait n" anyway.
  def give_up(n, queued) do
    {wait, hello} = {"wait #{n}", "hello #{n}"}
    watch = Process.whereis(HalC2.Orchestration.TurnWatch)
    :ok = :sys.suspend(watch)
    :erlang.trace(watch, true, [:receive])
    test = self()
    spawn(fn -> send(test, {:sent, Orchestration.dispatch(message(wait))}) end)

    receive do
      {:trace, ^watch, :receive, {:"$gen_call", _, {:claim, _, _, _}}} -> :ok
    after
      @wait_ms -> :ok
    end

    :erlang.trace(watch, false, [:receive])
    first = await_run(wait, &(&1["status"] == "starting"))
    if queued, do: {:ok, _} = Orchestration.dispatch(message(hello))
    failure = Orchestration.TurnWriter.start_failure(nil, :closed)
    Orchestration.TurnWriter.abandon(@tid, first["id"], "failed", failure)
    :ok = :sys.resume(watch)

    receive do
      {:sent, _} -> :ok
    after
      @wait_ms -> :ok
    end

    # Codex took the prompt all the same, which the run's start records.
    first = await_run(wait, &(&1["startedAt"] != nil))

    second =
      if queued,
        do: await_run(hello, &(&1["status"] in ~w(completed failed interrupted cancelled))),
        else: %{}

    settle_runtime()

    %{
      first: first["status"],
      wait_thread: turn_thread(wait),
      second: second["status"],
      queued_thread: if(queued, do: turn_thread(hello))
    }
  end

  # --- the real side ---------------------------------------------------------------

  defp selection, do: %{"instanceId" => "codex", "model" => "gpt-5.4"}

  defp message(text),
    do: %{
      "type" => "message.dispatch",
      "threadId" => @tid,
      "messageId" => "message:#{text}",
      "text" => text,
      "attachments" => [],
      "modelSelection" => selection(),
      "dispatchMode" => %{"type" => "queue_after_active"}
    }

  # The conversation Codex ran the turn for `text` in, as the MC asked it to.
  defp turn_thread(text) do
    case File.read(Process.get(:log)) do
      {:ok, log} ->
        log
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.find_value(fn
          %{"method" => "turn/start", "params" => %{"threadId" => thread, "input" => input}} ->
            if Enum.any?(input, &String.ends_with?(&1["text"] || "", text)), do: thread

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  defp settle_runtime do
    case Registry.lookup(HalC2.Codex.Registry, @tid) do
      [{pid, _}] -> GenServer.call(pid, :settle)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  # The run of the message `text` once `done?` holds for it, or as it stands when it
  # never does: the postcondition then shows what it waited for.
  defp await_run(text, done?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms
    run = run(text)

    if run != nil and done?.(run) do
      run
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_run(text, done?, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> run || %{}
      end
    end
  end

  defp run(text) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))

    Enum.find(
      StreamState.list(state, "run"),
      &(&1["messageId"] == "message:#{text}" or &1["userMessageId"] == "message:#{text}")
    )
  end
end
