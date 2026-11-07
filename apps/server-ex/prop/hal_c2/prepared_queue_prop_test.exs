defmodule HalC2.PreparedQueuePropTest do
  @moduledoc """
  A thread's first run waits for its worktree (`Orchestration.fail_prepared/5`,
  `retry_prepared/2`), with the user's messages queued behind it. A run that ends
  without its worktree (`hold_queue: true`) holds the queue, and a message the user
  queues meanwhile is held too, so none runs in the project's own checkout. A retry
  is taken only while every other run is still queued, and frees the queue to follow
  it again. No run starts while the first one waits or ended this way.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @thread "t1"

  property "a prepared run's end holds the queue behind it and its retry frees it",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("prepared-queue")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch
        ])

        {:ok, _} =
          Orchestration.dispatch(%{
            "type" => "thread.create",
            "threadId" => @thread,
            "projectId" => "project-1",
            "title" => "Cart totals",
            "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
            "runtimeMode" => "full-access",
            "interactionMode" => "default"
          })

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # first: the message whose run waits for the worktree, once sent;
  # runs: msg -> %{status, held}, the queued ones the user's follow-ups.
  def initial_state, do: %{first: nil, runs: %{}, next: 1}

  def command(%{first: nil, next: next}),
    do: {:call, __MODULE__, :prepare, ["m#{next}"]}

  def command(%{first: first, next: next}) do
    frequency([
      {4, {:call, __MODULE__, :follow_up, ["m#{next}"]}},
      {2, {:call, __MODULE__, :fail, [first, boolean()]}},
      {1, {:call, __MODULE__, :cancel, [first]}},
      {2, {:call, __MODULE__, :retry, [first]}}
    ])
  end

  def precondition(%{first: first}, {:call, _, :prepare, _}), do: first == nil

  # Only while nothing could start it: a run is waiting, or the queue is held.
  def precondition(state, {:call, _, :follow_up, _}),
    do: preparing?(state) or held?(state)

  # Without a hold, the queue would start in the project's checkout; the MC never
  # ends a run that way with messages queued (`WorktreeSetup.failed/4`).
  def precondition(state, {:call, _, :fail, [_, false]}), do: queued(state) == []
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :prepare, [msg]}),
    do: %{state | first: msg, next: state.next + 1, runs: %{msg => %{status: "preparing"}}}

  def next_state(state, _result, {:call, _, :follow_up, [msg]}),
    do: %{
      state
      | next: state.next + 1,
        runs: Map.put(state.runs, msg, %{status: "queued", held: held?(state)})
    }

  def next_state(state, _result, {:call, _, :fail, [first, hold]}),
    do: ended(state, first, "failed", hold)

  def next_state(state, _result, {:call, _, :cancel, [first]}),
    do: ended(state, first, "cancelled", true)

  def next_state(state, _result, {:call, _, :retry, [first]}) do
    if retryable?(state) do
      runs =
        Map.new(state.runs, fn
          {^first, run} -> {first, %{run | status: "preparing"}}
          {msg, run} -> {msg, %{run | held: false}}
        end)

      %{state | runs: runs}
    else
      state
    end
  end

  def postcondition(state, {:call, _, kind, _} = call, result)
      when kind in [:prepare, :follow_up],
      do: match?({:ok, _}, result) and matches?(next_state(state, result, call))

  def postcondition(state, {:call, _, kind, _} = call, result) when kind in [:fail, :cancel] do
    expected = if preparing?(state), do: :ok, else: :error
    elem_or(result) == expected and matches?(next_state(state, result, call))
  end

  def postcondition(state, {:call, _, :retry, _} = call, result) do
    expected = if retryable?(state), do: :ok, else: :error
    elem_or(result) == expected and matches?(next_state(state, result, call))
  end

  defp ended(state, first, status, hold) do
    if preparing?(state) do
      runs =
        Map.new(state.runs, fn
          {^first, run} -> {first, %{run | status: status}}
          {msg, %{status: "queued"} = run} -> {msg, %{run | held: run.held or hold}}
          other -> other
        end)

      %{state | runs: runs}
    else
      state
    end
  end

  defp preparing?(%{first: first, runs: runs}), do: runs[first][:status] == "preparing"
  defp held?(state), do: Enum.any?(queued(state), & &1.held)
  defp queued(state), do: for({_, %{status: "queued"} = run} <- state.runs, do: run)

  defp retryable?(%{first: first, runs: runs} = state),
    do: runs[first][:status] == "failed" and length(queued(state)) == map_size(runs) - 1

  defp elem_or(:ok), do: :ok
  defp elem_or({:ok, _}), do: :ok
  defp elem_or({:error, _}), do: :error

  # The thread's runs, by their message, are the model's: none started, and the
  # queued ones held exactly when the model holds them.
  defp matches?(%{runs: expected}) do
    actual =
      for run <- StreamState.list(stream(), "run"), into: %{} do
        shown =
          if run["status"] == "queued",
            do: %{status: "queued", held: run["queueHeld"] == true},
            else: %{status: run["status"]}

        {run["userMessageId"], shown}
      end

    actual == Map.new(expected, fn {msg, run} -> {msg, Map.take(run, [:status, :held])} end)
  end

  # --- commands -------------------------------------------------------------------

  # The first message, as a new worktree thread records it with the thread
  # (`Orchestration.launch_thread/2`): decided, its run left to `HalC2.WorktreeSetup`.
  def prepare(msg) do
    command = message(msg, "defer_start")
    HalC2.Streams.transact(@thread, :thread, &Orchestration.decide_dispatch(&1, @thread, command))
  end

  def follow_up(msg), do: Orchestration.dispatch(message(msg, "queue_after_active"))

  def fail(msg, hold) do
    Orchestration.fail_prepared(@thread, run_id(msg), "failed", %{"message" => "no worktree"},
      hold_queue: hold
    )
  end

  def cancel(msg),
    do: Orchestration.fail_prepared(@thread, run_id(msg), "cancelled", nil, hold_queue: true)

  def retry(msg), do: Orchestration.retry_prepared(@thread, run_id(msg))

  defp message(msg, mode) do
    %{
      "type" => "message.dispatch",
      "threadId" => @thread,
      "messageId" => msg,
      "text" => "Show #{msg}",
      "attachments" => [],
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "dispatchMode" => %{"type" => mode}
    }
  end

  defp run_id(msg),
    do:
      Enum.find_value(
        StreamState.list(stream(), "run"),
        &(&1["userMessageId"] == msg && &1["id"])
      )

  defp stream, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@thread))
end
