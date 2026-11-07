defmodule HalC2.ContinuationDeliveryPropTest do
  @moduledoc """
  A state machine over one thread whose turn a restart cut off, with the continuation
  `Recovery.continue/0` asked of it recorded but not yet run, while the thread is
  archived and unarchived, set to another provider and back, sent a newer message, and
  its project's `continueThreadsAfterServerUpdate` turned off and on:

  - when the continuation's effect runs (`Recovery.deliverable?/2`), it is sent only if
    the thread is still not archived, on the provider the turn ran on, with nothing
    newer sent, and its project still continues threads;
  - and only if the thread is not settled or snoozed, and the cut-off turn was not
    waiting on the user (a request still open, or one the restart closed) and had not
    been answered already (its provider turn had ended), as upstream #18461 asks;
  - and only if it would not be the fourth continuation in a row with nothing from the
    user between them (upstream #18461), where a continued run that worked longer than
    five minutes before it was cut off breaks the row (upstream #20306);
  - except that one whose message is in already (a retry after it was sent) always
    goes on, so the retry finds it sent rather than reporting it dropped.

  The turn cut off is extended by `cut/2`: the user's turn, or a continuation of the
  last one, each cut off after a minute or after ten.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Recovery

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @thread "t1"

  property "a continuation is sent only if it is still wanted when it runs, and not in a loop",
    numtests: HalC2.Prop.numtests(300),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("continuation-delivery")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Settings
        ])

        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # The thread starts on the cut-off turn's provider, unarchived, with its project
  # continuing threads and nothing sent since. runs: the ordinal of the thread's last
  # run; current: that of the run cut off; chain: the quick continuations in a row that
  # led to it; asked: what the cut-off run asked the user (nil, `:open` or `:closed`, as
  # the restart closed it); ended: its provider turn had ended.
  def initial_state,
    do: %{
      archived: false,
      settled: false,
      snoozed: false,
      asked: nil,
      ended: false,
      provider: "claudeAgent",
      setting: true,
      runs: 1,
      current: 1,
      chain: 0,
      newer: false,
      sent: false
    }

  # Cuts come often, and mostly as quick continuations, so rows of them reach the limit.
  def command(state) do
    frequency(
      [
        {1, {:call, __MODULE__, :archive, [not state.archived]}},
        {1, {:call, __MODULE__, :provider, [oneof(["claudeAgent", "codex"])]}},
        {1, {:call, __MODULE__, :setting, [boolean()]}},
        {1, {:call, __MODULE__, :settle, [boolean()]}},
        {1, {:call, __MODULE__, :snooze, [boolean()]}},
        {1,
         {:call, __MODULE__, :ask, [state.current, oneof([:open, :closed, :answered, :older])]}},
        {1, {:call, __MODULE__, :end_turn, [state.current]}},
        {3, {:call, __MODULE__, :deliver, [state.current]}}
      ] ++
        if(state.sent or state.newer,
          do: [],
          else: [
            {1, {:call, __MODULE__, :newer, [state.runs + 1]}},
            {1, {:call, __MODULE__, :sent, [state.runs + 1, state.current]}},
            {6,
             {:call, __MODULE__, :cut,
              [
                state.runs + 1,
                frequency([{1, :user}, {4, {:continues, state.current}}]),
                frequency([{3, true}, {1, false}])
              ]}}
          ]
        )
    )
  end

  def precondition(state, {:call, _, :deliver, [n]}), do: n == state.current
  def precondition(state, {:call, _, :ask, [n, _]}), do: n == state.current
  def precondition(state, {:call, _, :end_turn, [n]}), do: n == state.current

  def precondition(state, {:call, _, :newer, [n]}),
    do: not (state.sent or state.newer) and n == state.runs + 1

  def precondition(state, {:call, _, :sent, [n, current]}),
    do: not (state.sent or state.newer) and n == state.runs + 1 and current == state.current

  def precondition(state, {:call, _, :cut, [n, how, _]}),
    do:
      not (state.sent or state.newer) and n == state.runs + 1 and
        how in [:user, {:continues, state.current}]

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :archive, [archived]}),
    do: %{state | archived: archived}

  def next_state(state, _result, {:call, _, :provider, [provider]}),
    do: %{state | provider: provider}

  def next_state(state, _result, {:call, _, :setting, [on]}), do: %{state | setting: on}
  def next_state(state, _result, {:call, _, :settle, [on]}), do: %{state | settled: on}
  def next_state(state, _result, {:call, _, :snooze, [on]}), do: %{state | snoozed: on}
  def next_state(state, _result, {:call, _, :end_turn, _}), do: %{state | ended: true}

  # A request answered, or one an earlier restart closed, does not count; the first that
  # does stays.
  def next_state(state, _result, {:call, _, :ask, [_, how]}),
    do: %{state | asked: state.asked || if(how in [:open, :closed], do: how)}

  def next_state(state, _result, {:call, _, :newer, [n]}), do: %{state | runs: n, newer: true}
  def next_state(state, _result, {:call, _, :sent, [n, _]}), do: %{state | runs: n, sent: true}

  def next_state(state, _result, {:call, _, :cut, [n, how, quick]}) do
    chain = if how != :user and quick, do: state.chain + 1, else: 0
    %{state | runs: n, current: n, chain: chain, asked: nil, ended: false}
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :deliver, _}, deliverable),
    do: deliverable == (state.sent or wanted?(state))

  def postcondition(_state, _call, _result), do: true

  defp wanted?(state),
    do:
      not state.archived and state.provider == "claudeAgent" and state.setting and
        not state.settled and not state.snoozed and state.asked == nil and not state.ended and
        not state.newer and state.chain < 3

  # --- commands -------------------------------------------------------------------

  def archive(true), do: patch_thread(%{"archivedAt" => "2026-01-01T01:00:00.000Z"})
  def archive(false), do: patch_thread(%{"archivedAt" => nil})

  def provider(instance),
    do: patch_thread(%{"modelSelection" => %{"instanceId" => instance, "model" => "m"}})

  def setting(on) do
    {_, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(%{"continueThreadsAfterServerUpdate" => on}, version)
    :ok
  end

  def settle(true), do: patch_thread(%{"settledOverride" => "settled"})
  def settle(false), do: patch_thread(%{"settledOverride" => "active"})

  def snooze(true),
    do:
      patch_thread(%{
        "snoozedUntil" => DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.to_iso8601()
      })

  def snooze(false), do: patch_thread(%{"snoozedUntil" => nil})

  # The cut-off run `n` asked the user something, under its root node: a request still
  # open, one the restart closed as it ended the run, one the user answered, or one an
  # earlier restart closed.
  def ask(n, how) do
    id = "runtime-request:#{n}:#{System.unique_integer([:positive])}"

    ended =
      HalC2.Streams.state(@thread)
      |> HalC2.StreamState.fetch("run", "run-#{n}")
      |> Map.fetch!("completedAt")

    {status, resolved} =
      case how do
        :open -> {"pending", nil}
        :closed -> {"expired", ended}
        :answered -> {"resolved", ended}
        :older -> {"expired", at(n, 0)}
      end

    commit([
      {"runtime-request", id,
       %{
         "id" => id,
         "nodeId" => "node-#{n}",
         "kind" => "approval",
         "status" => status,
         "resolvedAt" => resolved
       }}
    ])
  end

  # The cut-off run `n`'s provider turn had ended before the restart.
  def end_turn(n),
    do: commit([{"provider-turn", "provider-turn-#{n}", %{"status" => "completed"}}])

  # The user sends a message, which runs after the cut-off turn.
  def newer(n), do: commit([run(n, "completed", "msg-#{n}", 1)])

  # The continuation's own message went in, and its run started; the effect then runs
  # again, as after a crash before it was marked done.
  def sent(n, current) do
    message = continuation(current)

    commit([
      run(n, "running", message, nil),
      {"message", message,
       %{
         "id" => message,
         "role" => "user",
         "text" => "Continue where you left off.",
         "runId" => "run-#{n}",
         "createdAt" => at(n, 0)
       }}
    ])
  end

  # Run `n` is the user's turn, or the continuation of the turn cut off before it, and is
  # cut off in turn, a minute or ten minutes after it starts.
  def cut(n, how, quick) do
    message = if how == :user, do: "msg-#{n}", else: continuation(elem(how, 1))
    commit([run(n, "interrupted", message, if(quick, do: 1, else: 10)) | turn(n)])
  end

  def deliver(n), do: Recovery.deliverable?(@thread, "run-#{n}")

  # --- helpers --------------------------------------------------------------------

  defp setup do
    # The model has no update that asked for continuations: pin the boot's answer
    # (`HalC2.Upgrade.continue_threads?/0`, a persistent term other properties in
    # this VM can leave set) to none, or `deliverable?/2` ignores the setting.
    :persistent_term.erase({HalC2.Upgrade, :continue_threads})
    setting(true)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @thread,
        "projectId" => "project-1",
        "title" => "Cut off",
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "m"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    commit([run(1, "interrupted", "msg-1", 1) | turn(1)])
  end

  # The root node, attempt and provider turn of run `n`, which the restart interrupted.
  defp turn(n),
    do: [
      {"node", "node-#{n}",
       %{"id" => "node-#{n}", "runId" => "run-#{n}", "status" => "interrupted"}},
      {"run-attempt", "attempt-#{n}",
       %{"id" => "attempt-#{n}", "runId" => "run-#{n}", "providerTurnId" => "provider-turn-#{n}"}},
      {"provider-turn", "provider-turn-#{n}",
       %{"id" => "provider-turn-#{n}", "runId" => "run-#{n}", "status" => "interrupted"}}
    ]

  defp continuation(n), do: "message:restart-continuation:run-#{n}"

  # Run `n`, which `message` started, ended `minutes` after it started (nil: still runs).
  defp run(n, status, message, minutes),
    do:
      {"run", "run-#{n}",
       %{
         "id" => "run-#{n}",
         "ordinal" => n,
         "status" => status,
         "userMessageId" => message,
         "rootNodeId" => "node-#{n}",
         "activeAttemptId" => "attempt-#{n}",
         "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "m"},
         "requestedAt" => at(n, 0),
         "startedAt" => at(n, 0),
         "completedAt" => minutes && at(n, minutes),
         "updatedAt" => at(n, minutes || 0)
       }}

  defp patch_thread(fields), do: commit([{"thread", @thread, fields}])

  # Each run starts twenty minutes after the one before it.
  defp at(n, minutes),
    do:
      ~U[2026-01-01 00:00:00.000Z]
      |> DateTime.add((n * 20 + minutes) * 60, :second)
      |> DateTime.to_iso8601()

  defp commit(entities) do
    {:ok, _} =
      HalC2.Streams.commit(
        @thread,
        :thread,
        for({kind, id, s} <- entities, do: {kind, id, %{"s" => s}})
      )

    :ok
  end
end
