defmodule HalC2.ContinuationDeliveryPropTest do
  @moduledoc """
  A state machine over one thread whose turn a restart cut off, with the continuation
  `Recovery.continue/0` asked of it recorded but not yet run, while the thread is
  archived and unarchived, set to another provider and back, sent a newer message, and
  its project's `continueThreadsAfterServerUpdate` turned off and on:

  - when the continuation's effect runs (`Recovery.deliverable?/2`), it is sent only if
    the thread is still not archived, on the provider the turn ran on, with nothing
    newer sent, and its project still continues threads;
  - except that one whose message is in already (a retry after it was sent) always
    goes on, so the retry finds it sent rather than reporting it dropped.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Recovery

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @thread "t1"
  @run "run-1"
  @message "message:restart-continuation:run-1"

  property "a continuation is sent only if it is still wanted when it runs",
    numtests: HalC2.Prop.numtests(100),
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
  # continuing threads and nothing sent since.
  def initial_state,
    do: %{archived: false, provider: "claudeAgent", setting: true, newer: 0, sent: false}

  def command(state) do
    oneof(
      [
        {:call, __MODULE__, :archive, [not state.archived]},
        {:call, __MODULE__, :provider, [oneof(["claudeAgent", "codex"])]},
        {:call, __MODULE__, :setting, [boolean()]},
        {:call, __MODULE__, :deliver, []}
      ] ++
        if(state.sent,
          do: [],
          else: [
            {:call, __MODULE__, :newer, [state.newer + 2]},
            {:call, __MODULE__, :sent, [state.newer + 2]}
          ]
        )
    )
  end

  def precondition(state, {:call, _, :newer, [n]}), do: not state.sent and n == state.newer + 2
  def precondition(state, {:call, _, :sent, [n]}), do: not state.sent and n == state.newer + 2
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :archive, [archived]}),
    do: %{state | archived: archived}

  def next_state(state, _result, {:call, _, :provider, [provider]}),
    do: %{state | provider: provider}

  def next_state(state, _result, {:call, _, :setting, [on]}), do: %{state | setting: on}
  def next_state(state, _result, {:call, _, :newer, [n]}), do: %{state | newer: n}
  def next_state(state, _result, {:call, _, :sent, [n]}), do: %{state | newer: n, sent: true}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :deliver, _}, deliverable),
    do: deliverable == (state.sent or wanted?(state))

  def postcondition(_state, _call, _result), do: true

  defp wanted?(state),
    do:
      not state.archived and state.provider == "claudeAgent" and state.setting and
        state.newer == 0

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

  # The user sends a message, which runs after the cut-off turn.
  def newer(n), do: commit([run("run-#{n}", n, "completed")])

  # The continuation's own message went in, and its run started; the effect then runs
  # again, as after a crash before it was marked done.
  def sent(n) do
    commit([
      run("run-#{n}", n, "running"),
      {"message", @message,
       %{
         "id" => @message,
         "role" => "user",
         "text" => "Continue where you left off.",
         "runId" => "run-#{n}",
         "createdAt" => at(n)
       }}
    ])
  end

  def deliver, do: Recovery.deliverable?(@thread, @run)

  # --- helpers --------------------------------------------------------------------

  defp setup do
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

    commit([run(@run, 1, "interrupted")])
  end

  defp run(id, ordinal, status),
    do:
      {"run", id,
       %{
         "id" => id,
         "ordinal" => ordinal,
         "status" => status,
         "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "m"},
         "startedAt" => at(ordinal),
         "updatedAt" => at(ordinal)
       }}

  defp patch_thread(fields), do: commit([{"thread", @thread, fields}])

  defp at(n), do: "2026-01-01T00:#{String.pad_leading("#{rem(n, 60)}", 2, "0")}:00.000Z"

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
