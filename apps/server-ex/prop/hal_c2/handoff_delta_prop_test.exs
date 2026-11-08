defmodule HalC2.HandoffDeltaPropTest do
  @moduledoc """
  A state machine over one thread whose runs go to two provider threads (Claude and
  Codex), each run finishing as it was delivered (completed, or failed after the
  provider read it) or refused before the provider read it. A refused run hands its
  provider thread's `lastRunOrdinal` back, as Claude's `ThreadRuntime.unsent/2` does.

  The promise of `Handoff.plan/5`'s delta: the next run on a provider thread is handed
  every message it has not seen, that is each run after the last one it read, by the
  other provider thread or refused on its own (Upstream #16287), and none it read.

  The stream is kept in memory (`HalC2.StreamState`); the plan is a pure read of it.
  """

  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Handoff
  alias HalC2.StreamState

  @providers %{claude: "provider-thread:claudeAgent:t", codex: "provider-thread:codex:t"}

  property "a provider thread is handed the runs it never read, once",
    numtests: HalC2.Prop.numtests(200),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      Process.put(:stream, stream())
      {history, state, result} = run_commands(__MODULE__, cmds)

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: `{ordinal, provider, outcome}` newest first.
  def initial_state, do: %{runs: []}

  def command(state) do
    {:call, __MODULE__, :run,
     [length(state.runs) + 1, oneof([:claude, :codex]), oneof([:completed, :failed, :refused])]}
  end

  def precondition(state, {:call, _, :run, [n, _, _]}), do: n == length(state.runs) + 1

  def next_state(state, _result, {:call, _, :run, [n, provider, outcome]}),
    do: %{state | runs: [{n, provider, outcome} | state.runs]}

  def postcondition(state, {:call, _, :run, [_n, provider, _]}, context) do
    seen =
      Enum.find_value(state.runs, 0, fn {m, p, outcome} ->
        if p == provider and outcome != :refused, do: m
      end)

    expected =
      for {m, p, outcome} <- state.runs,
          m > seen,
          p != provider or outcome == :refused,
          do: m

    handed = for {m, _, _} <- state.runs, String.contains?(context || "", text(m)), do: m
    Enum.sort(handed) == Enum.sort(expected)
  end

  # --- commands -------------------------------------------------------------------

  # Run `n` starts on `provider`: its plan is read, then the run finishes as `outcome`.
  # Returns the context it was handed.
  def run(n, provider, outcome) do
    stream = Process.get(:stream)
    thread = @providers[provider]

    ids = %{
      driver: if(provider == :claude, do: "claudeAgent", else: "codex"),
      run: "run-#{n}",
      message: "message:user-#{n}",
      thread: "t",
      provider_thread: thread
    }

    plan =
      Handoff.plan(
        stream,
        StreamState.get(stream, "provider-thread")[thread],
        ids,
        n,
        at(n),
        %{text: text(n), attachments: []}
      )

    run = %{
      "id" => "run-#{n}",
      "ordinal" => n,
      "status" => if(outcome == :completed, do: "completed", else: "failed"),
      "providerThreadId" => thread,
      "userMessageId" => "message:user-#{n}",
      "startedAt" => at(n),
      "completedAt" => at(n)
    }

    message = %{
      "id" => "message:user-#{n}",
      "role" => "user",
      "runId" => "run-#{n}",
      "text" => text(n),
      "createdAt" => at(n)
    }

    # The plan's own changes (the handoff records) are bookkeeping; only the delivered
    # run moves where its provider thread has read to.
    seen =
      if outcome == :refused,
        do: [],
        else: [{"provider-thread", %{"id" => thread, "lastRunOrdinal" => n}}]

    Process.put(:stream, put(stream, [{"run", run}, {"message", message}] ++ seen))
    plan.context
  end

  # --- helpers --------------------------------------------------------------------

  defp stream do
    put(
      StreamState.new(),
      [{"thread", %{"id" => "t"}}] ++
        for {provider, id} <- @providers do
          {"provider-thread",
           %{
             "id" => id,
             "appThreadId" => "t",
             "lastRunOrdinal" => 0,
             "nativeThreadRef" => %{"driver" => "#{provider}", "nativeId" => "native-#{provider}"}
           }}
        end
    )
  end

  defp put(stream, entities) do
    Enum.reduce(entities, stream, fn {kind, entity}, stream ->
      StreamState.apply_event(stream, %{
        seq: stream.seq + 1,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => Map.merge(StreamState.get(stream, kind)[entity["id"]] || %{}, entity)}
      })
    end)
  end

  defp text(n), do: "message number #{n}."
  defp at(n), do: "2026-10-01T10:#{String.pad_leading("#{rem(n, 60)}", 2, "0")}:00Z"
end
