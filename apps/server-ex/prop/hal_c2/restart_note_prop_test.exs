defmodule HalC2.RestartNotePropTest do
  @moduledoc """
  A state machine over one thread whose turns finish with background work left running
  (a command, a subagent, a monitor, a monitor that runs for the life of the session, or
  a task the thread delegated),
  that work ending, the idle release stopping the thread's session, and the MC
  restarting (`Recovery.run/0`), as upstream #15604 asks:

  - a restart ends whatever of the finished latest turn's work was still running;
  - it asks to wake the thread about that work only when its session was not released
    before the stop (a released session's work was gone already, only its records left);
  - the next turn the thread starts hears what the restart ended, once, naming each
    piece of that work (the `<server_restart>` section `Handoff.plan/5` builds from the
    thread's `restartNote`), and the turn after it does not; a turn the restart's own
    continuation starts, whose message says so, consumes the note without repeating it;
  - a session-long monitor or a delegated task, which runs on in its own thread, is
    never named, and a restart leaves the task running;
  - a wake (`HalC2.Orchestration.Wake`) whose run had not reached its provider when the
    MC stopped is cancelled, and does not hide the turn before it: that turn's ended
    work is still named and woken for.

  The runs are written to the stream as the turn writer leaves them, with no provider
  behind them, and the MC takes no automatic actions, so the wake is read from what
  `Recovery.run/0` kept for `continue/0` rather than sent.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.{Handoff, Recovery}
  alias HalC2.StreamState

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @thread "t1"
  @provider_thread "provider-thread:claudeAgent:t1"
  @session "provider-session:claudeAgent:t1"
  @kinds [:command, :subagent, :monitor, :persistent, :delegated]

  property "a restart's note about ended background work reaches the next turn once",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("restart-note")
        Application.put_env(:hal_c2, :auto_actions, false)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell
        ])

        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :auto_actions)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: the ordinal of the thread's last run; last: that of its last turn; open: the
  # last turn's work still running, as the agent would hear it named (nil for a
  # session-long monitor); released: the session was stopped since; note: the work the
  # next turn hears the restart ended; wake: a wake run still starting.
  def initial_state, do: %{runs: 0, last: 0, open: [], released: false, note: nil, wake: nil}

  def command(state) do
    frequency(
      [
        {3, {:call, __MODULE__, :restart, []}}
      ] ++
        if(state.wake,
          do: [],
          else: [{4, {:call, __MODULE__, :turn, [state.runs + 1, work(), started_by(state)]}}]
        ) ++
        if(state.wake != nil or state.runs == 0,
          do: [],
          else: [{2, {:call, __MODULE__, :wake, [state.runs + 1]}}]
        ) ++
        if(state.runs == 0, do: [], else: [{2, {:call, __MODULE__, :release, []}}]) ++
        if(state.open == [], do: [], else: [{2, {:call, __MODULE__, :end_work, [state.last]}}])
    )
  end

  defp work, do: resize(3, list(oneof(@kinds)))

  # What starts the turn: the user, or, once a restart left a note, the continuation it
  # asked for (a continuation not sent leaves the note to the user's turn).
  defp started_by(%{note: nil}), do: :user
  defp started_by(_state), do: frequency([{2, :user}, {1, :continuation}])

  def precondition(state, {:call, _, :turn, [n, _, _]}),
    do: state.wake == nil and n == state.runs + 1

  def precondition(state, {:call, _, :wake, [n]}),
    do: state.wake == nil and state.runs > 0 and n == state.runs + 1

  def precondition(state, {:call, _, :release, _}), do: state.runs > 0
  def precondition(state, {:call, _, :end_work, [n]}), do: state.open != [] and n == state.last
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [n, kinds, _]}),
    do: %{state | runs: n, last: n, open: Enum.map(kinds, &named/1), released: false, note: nil}

  def next_state(state, _result, {:call, _, :wake, [n]}), do: %{state | runs: n, wake: n}

  def next_state(state, _result, {:call, _, :release, _}), do: %{state | released: true}
  def next_state(state, _result, {:call, _, :end_work, _}), do: %{state | open: []}

  def next_state(state, _result, {:call, _, :restart, _}) do
    case ended(state) do
      [] -> %{state | open: [], wake: nil}
      work -> %{state | open: [], note: work, wake: nil}
    end
  end

  # The work a restart ends that the agent hears named.
  defp ended(state), do: Enum.reject(state.open, &is_nil/1)

  def postcondition(state, {:call, _, :turn, [_, _, how]}, context) do
    case if(how == :continuation, do: nil, else: state.note) do
      nil ->
        context == nil or not String.contains?(context, "<server_restart>")

      work ->
        is_binary(context) and String.contains?(context, "<server_restart>") and
          Enum.all?(work, &String.contains?(context, &1))
    end
  end

  def postcondition(state, {:call, _, :restart, _}, %{
        woken: woken,
        note: note,
        running: running,
        wakes: wakes
      }) do
    work = ended(state)
    expected_note = if work == [], do: state.note, else: work

    running == [] and woken == (work != [] and not state.released) and
      Enum.all?(wakes, &(&1 == "cancelled")) and
      case expected_note do
        nil -> note == nil
        work -> is_binary(note) and Enum.all?(work, &String.contains?(note, &1))
      end and
      not String.contains?(note || "", "Keep the session")
  end

  def postcondition(_state, _call, _result), do: true

  # How the agent hears each kind named; a session-long monitor is not waited on, and a
  # delegated task is the caller's, not background work.
  defp named(:command), do: "the command `npm run build`"
  defp named(:subagent), do: ~s(the subagent "Survey the repo")
  defp named(:monitor), do: ~s(the monitor "Watch the dev log")
  defp named(:persistent), do: nil
  defp named(:delegated), do: nil

  # --- commands -------------------------------------------------------------------

  # Turn `n` starts, which hands over what the thread's context holds for it, and
  # finishes with `kinds` left running in the background. Returns the context. A
  # continuation's message says what the restart ended itself, so its run hears no note.
  def turn(n, kinds, how) do
    run = "run-#{n}"

    message =
      if how == :continuation,
        do: "message:restart-continuation:run-#{n - 1}",
        else: "message:user-#{n}"

    context =
      HalC2.Streams.transact(@thread, :thread, fn state ->
        provider_thread = StreamState.get(state, "provider-thread")[@provider_thread]

        ids = %{
          driver: "claudeAgent",
          run: run,
          message: message,
          thread: @thread,
          provider_thread: @provider_thread
        }

        plan = Handoff.plan(state, provider_thread, ids, n, at(n, 0))
        {plan.changes, plan.context}
      end)

    items =
      for {kind, i} <- Enum.with_index(kinds),
          id = "item-#{n}-#{i}",
          entity <- [{"turn-item", id, item(kind, id, run, n * 10 + i)} | task(kind, id)],
          do: entity

    commit(
      [
        {"run", run,
         %{
           "id" => run,
           "ordinal" => n,
           "status" => "completed",
           "providerThreadId" => @provider_thread,
           "startedAt" => at(n, 0),
           "completedAt" => at(n, 30),
           "updatedAt" => at(n, 30)
         }},
        {"provider-session", @session,
         %{"id" => @session, "providerThreadId" => @provider_thread, "status" => "ready"}}
      ] ++ items
    )

    context
  end

  # The provider woke the thread by itself (`HalC2.Orchestration.Wake`), and the wake's
  # run, `n`, is still starting: it has not reached the provider.
  def wake(n) do
    run = "run-#{n}"
    message = "message:wake-#{n}"

    commit([
      {"message", message,
       %{"id" => message, "role" => "user", "providerWake" => true, "runId" => run}},
      {"run", run,
       %{
         "id" => run,
         "ordinal" => n,
         "status" => "starting",
         "userMessageId" => message,
         "activeAttemptId" => "attempt-#{n}",
         "providerThreadId" => @provider_thread,
         "startedAt" => nil
       }},
      {"run-attempt", "attempt-#{n}",
       %{"id" => "attempt-#{n}", "runId" => run, "status" => "pending"}}
    ])
  end

  # The background work of turn `n` ends, as its provider reports.
  def end_work(n) do
    state = stream()

    commit(
      for item <- StreamState.list(state, "turn-item"),
          item["runId"] == "run-#{n}",
          item["status"] == "running",
          do: {"turn-item", item["id"], %{"status" => "completed"}}
    )
  end

  # The idle release stops the thread's session (`Orchestration.release_session/1`).
  def release do
    commit([{"provider-session", @session, %{"status" => "stopped"}}])
  end

  # The MC stops and boots again. Returns whether boot kept the thread to wake about
  # its ended work, the note its next turn hears, and the work still marked running.
  def restart do
    HalC2.Prop.restart_service(HalC2.Streams)
    HalC2.Streams.flush_shell(@thread)
    Recovery.run()

    woken =
      :persistent_term.get({Recovery, :background}, [])
      |> Enum.any?(&(elem(&1, 0) == @thread))

    :ok = Recovery.continue()
    state = stream()

    running =
      for item <- StreamState.list(state, "turn-item"),
          item["status"] == "running",
          not match?(%{"persistent" => true}, item["input"]),
          not String.starts_with?(item["nodeId"] || "", "task:"),
          do: item["id"]

    %{
      woken: woken,
      note: StreamState.get(state, "thread")[@thread]["restartNote"],
      running: running,
      wakes:
        for(
          %{"userMessageId" => "message:wake-" <> _} = run <- StreamState.list(state, "run"),
          do: run["status"]
        )
    }
  end

  # --- helpers --------------------------------------------------------------------

  defp setup do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @thread,
        "projectId" => "project-1",
        "title" => "Settled",
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    commit([
      {"provider-thread", @provider_thread,
       %{
         "id" => @provider_thread,
         "appThreadId" => @thread,
         "nativeThreadRef" => %{"driver" => "claudeAgent", "nativeId" => "native-1"}
       }}
    ])
  end

  defp item(kind, id, run, ordinal) do
    base = %{"id" => id, "runId" => run, "status" => "running", "ordinal" => ordinal}

    Map.merge(
      base,
      case kind do
        :command ->
          %{"type" => "command_execution", "input" => "npm run build"}

        :subagent ->
          %{"type" => "subagent", "title" => "Survey the repo"}

        :monitor ->
          %{
            "type" => "dynamic_tool",
            "toolName" => "Monitor",
            "input" => %{"description" => "Watch the dev log"}
          }

        :delegated ->
          %{"type" => "subagent", "nodeId" => "task:#{id}", "title" => "Delegated"}

        :persistent ->
          %{
            "type" => "dynamic_tool",
            "toolName" => "Monitor",
            "input" => %{"description" => "Keep the session", "persistent" => true}
          }
      end
    )
  end

  # The task a `:delegated` item is the caller's side of.
  defp task(:delegated, id),
    do: [
      {"subagent", "task:#{id}",
       %{"id" => "task:#{id}", "origin" => "app_owned", "status" => "running"}}
    ]

  defp task(_kind, _id), do: []

  defp at(ordinal, second),
    do: "2026-01-01T00:#{pad(ordinal)}:#{pad(second)}.000Z"

  defp pad(n), do: String.pad_leading("#{rem(n, 60)}", 2, "0")

  defp commit([]), do: :ok

  defp commit(entities) do
    {:ok, _} =
      HalC2.Streams.commit(
        @thread,
        :thread,
        for({kind, id, s} <- entities, do: {kind, id, %{"s" => s}})
      )

    :ok
  end

  defp stream, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@thread))
end
