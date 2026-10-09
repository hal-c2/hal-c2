defmodule HalC2.DelegationPropTest do
  @moduledoc """
  A state machine over one delegated task: how its child thread's runs start, queue,
  end and are rolled back, how each end is reported to the caller (at once, late, never,
  or again), and the MC restarting (`Delegation.reconcile/2` at boot), also when the
  restart interrupts the child's working run and nothing continues it (`Recovery`).

  The child's runs are written to its stream as the turn writer leaves them, with no
  provider behind them; the caller has a turn running, so the result message a report
  delivers waits in its queue and starts nothing. After each command the test reads the
  task back and checks what the caller is promised:

  - the task, its node and its turn item agree on how it ended;
  - once settled the task never changes, and its result reaches the caller at most once;
  - it ended when a child run did, never when a report got through or the MC started,
    with that run's answer;
  - a report of a run that ended settles the task as that run ended;
  - a restart, or a report of a run since rolled back, settles it only once the child
    has nothing running or queued, and a restart always does then.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Delegation
  alias HalC2.StreamState

  @moduletag timeout: :infinity

  @parent "parent"
  @child "child"
  @task "node:subagent:task"
  @ended ~w(completed failed interrupted cancelled)

  property "a delegated task settles once, as and when its child's work ended",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("delegation")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch
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

  # runs: the child's runs in ordinal order, %{id, status, ended_as}, `ended_as` how
  # the run ended before any rollback; held: runs whose end is yet to be reported.
  def initial_state, do: %{runs: [], held: []}

  def command(state) do
    running = for %{status: "running"} = run <- state.runs, do: run.id
    queued = for %{status: "queued"} = run <- state.runs, do: run.id
    ended = for %{status: s} = run <- state.runs, s in @ended, do: run.id
    reported = for %{ended_as: s} = run <- state.runs, s != nil, do: [run.id, s]
    held = for [id, _] = args <- reported, id in state.held, do: args

    frequency(
      [{1, {:call, __MODULE__, :restart, []}}] ++
        if(running == [], do: [], else: [{1, {:call, __MODULE__, :restart_unresumed, []}}]) ++
        if(working?(state), do: [], else: [{4, {:call, __MODULE__, :start, [next(state)]}}]) ++
        if(running != [] and queued == [],
          do: [{1, {:call, __MODULE__, :queue, [next(state)]}}],
          else: []
        ) ++
        if(queued == [], do: [], else: [{1, {:call, __MODULE__, :cancel_queued, [hd(queued)]}}]) ++
        if(running == [],
          do: [],
          else: [
            {5,
             {:call, __MODULE__, :finish,
              [hd(running), oneof(@ended), frequency([{3, :at_once}, {2, :late}, {1, :lost}])]}}
          ]
        ) ++
        if(held == [],
          do: [],
          else: [{3, let([id, s] <- oneof(held), do: {:call, __MODULE__, :report, [id, s]})}]
        ) ++
        if(reported == [],
          do: [],
          else: [{1, let([id, s] <- oneof(reported), do: {:call, __MODULE__, :report, [id, s]})}]
        ) ++
        if(ended == [], do: [], else: [{2, {:call, __MODULE__, :roll_back, [oneof(ended)]}}])
    )
  end

  defp next(state), do: "run-#{length(state.runs) + 1}"

  defp working?(state), do: Enum.any?(state.runs, &(&1.status in ~w(running queued)))

  def precondition(state, {:call, _, :start, _}), do: not working?(state)

  def precondition(state, {:call, _, :queue, _}),
    do: Enum.any?(state.runs, &(&1.status == "running"))

  def precondition(state, {:call, _, call, [id | _]})
      when call in [:cancel_queued, :finish, :roll_back, :report] do
    case Enum.find(state.runs, &(&1.id == id)) do
      nil -> false
      run -> allowed?(call, run, state)
    end
  end

  def precondition(_state, _call), do: true

  defp allowed?(:cancel_queued, run, _), do: run.status == "queued"
  defp allowed?(:finish, run, _), do: run.status == "running"
  defp allowed?(:roll_back, run, _), do: run.status in @ended
  defp allowed?(:report, run, _), do: run.ended_as != nil

  def next_state(state, _result, {:call, _, :start, [id]}),
    do: %{state | runs: state.runs ++ [%{id: id, status: "running", ended_as: nil}]}

  def next_state(state, _result, {:call, _, :queue, [id]}),
    do: %{state | runs: state.runs ++ [%{id: id, status: "queued", ended_as: nil}]}

  def next_state(state, _result, {:call, _, :cancel_queued, [id]}),
    do: update(state, id, &%{&1 | status: "cancelled"})

  def next_state(state, _result, {:call, _, :finish, [id, status, how]}) do
    state = update(state, id, &%{&1 | status: status, ended_as: status})
    if how == :late, do: %{state | held: [id | state.held]}, else: state
  end

  def next_state(state, _result, {:call, _, :report, [id, _]}),
    do: %{state | held: List.delete(state.held, id)}

  def next_state(state, _result, {:call, _, :roll_back, [id]}),
    do: update(state, id, &%{&1 | status: "rolled_back"})

  def next_state(state, _result, {:call, _, :restart, []}), do: state

  def next_state(state, _result, {:call, _, :restart_unresumed, []}) do
    runs =
      for run <- state.runs do
        if run.status == "running",
          do: %{run | status: "interrupted", ended_as: "interrupted"},
          else: run
      end

    %{state | runs: runs}
  end

  defp update(state, id, fun),
    do: %{state | runs: Enum.map(state.runs, &if(&1.id == id, do: fun.(&1), else: &1))}

  # Every command returns the task before and after it, and the child's runs after.
  def postcondition(state, {:call, _, call, args}, {before, task, runs}) do
    agree?(task) and kept?(before, task) and when_ended?(before, task, runs) and
      delivered_once?() and expected?(state, call, args, before, task, runs)
  end

  defp agree?(%{"subagent" => s, "node" => n, "item" => i}),
    do: s["status"] == n["status"] and n["status"] == i["status"]

  defp kept?(before, task), do: not settled?(before) or before == task

  defp when_ended?(before, task, runs) do
    settled?(before) or not settled?(task) or
      Enum.any?(runs, fn run ->
        run["completedAt"] == task["subagent"]["completedAt"] and
          task["subagent"]["result"] in [nil, answered(run["id"])]
      end)
  end

  defp delivered_once? do
    results =
      for message <- StreamState.list(stream(@parent), "message"),
          message["text"] =~ "<delegated_task_result",
          do: message

    length(results) <= 1
  end

  # A report of an ended run settles an unsettled task as that run ended.
  defp expected?(_state, :finish, [id, status, :at_once], before, task, _runs),
    do: settled?(before) or ended_as?(task, id, status)

  defp expected?(state, :report, [id, _], before, task, runs) do
    run = Enum.find(state.runs, &(&1.id == id))

    cond do
      settled?(before) -> true
      run.status != "rolled_back" -> ended_as?(task, id, run.ended_as)
      true -> not settled?(task) or not busy?(runs)
    end
  end

  # A restart settles a task whose child has stopped, and only then.
  defp expected?(_state, call, [], before, task, runs)
       when call in [:restart, :restart_unresumed] do
    cond do
      settled?(before) -> true
      runs == [] -> not settled?(task)
      busy?(runs) -> not settled?(task)
      true -> settled?(task)
    end
  end

  defp expected?(_state, _call, _args, before, task, _runs),
    do: settled?(before) or not settled?(task)

  defp ended_as?(task, id, status) do
    run = StreamState.get(stream(@child), "run")[id]

    task["subagent"]["status"] == status and
      task["subagent"]["completedAt"] == run["completedAt"] and
      task["subagent"]["result"] == answered(id)
  end

  # What the run said before it ended: nothing for one boot interrupted.
  defp answered(id),
    do: if(StreamState.get(stream(@child), "message")["answer-#{id}"], do: answer(id))

  defp settled?(task), do: task["subagent"]["status"] in @ended

  defp busy?(runs), do: Enum.any?(runs, &(&1["status"] in ~w(running queued)))

  # --- the real side ----------------------------------------------------------------

  # The caller, with a turn running, and the task it delegated to a child thread.
  defp setup do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @parent,
        "projectId" => "project-1",
        "title" => "Caller",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    open = %{"status" => "running", "completedAt" => nil}

    commit(@parent, [
      {"run", "parent-run", %{"id" => "parent-run", "ordinal" => 1, "status" => "running"}},
      {"subagent", @task,
       Map.merge(open, %{
         "id" => @task,
         "origin" => "app_owned",
         "runId" => "parent-run",
         "childThreadId" => @child,
         "title" => "Task",
         "completionWake" => "always",
         "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil}
       })},
      {"node", @task, Map.put(open, "id", @task)},
      {"turn-item", "turn-item:subagent:#{@task}",
       Map.merge(open, %{
         "id" => "turn-item:subagent:#{@task}",
         "type" => "subagent",
         "runId" => "parent-run",
         "nodeId" => @task,
         "ordinal" => 0
       })}
    ])

    commit(@child, [
      {"thread", @child,
       %{
         "id" => @child,
         "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => @parent}
       }}
    ])
  end

  def start(id), do: observe(fn -> commit(@child, [{"run", id, run(id, "running")}]) end)

  def queue(id), do: observe(fn -> commit(@child, [{"run", id, run(id, "queued")}]) end)

  def cancel_queued(id),
    do: observe(fn -> commit(@child, [{"run", id, ended(id, "cancelled")}]) end)

  # The run ends with its answer; its end is reported to the caller at once, later
  # (`report/1`), or never, as a crash between the two would lose it.
  def finish(id, status, how) do
    observe(fn ->
      commit(@child, [
        {"message", "answer-#{id}",
         %{"id" => "answer-#{id}", "runId" => id, "role" => "assistant", "text" => answer(id)}},
        {"run", id, ended(id, status)}
      ])

      if how == :at_once, do: Delegation.finished(@child, id, status)
    end)
  end

  # The end of run `id`, reported as it ended (`status`), whatever happened to it since.
  def report(id, status), do: observe(fn -> Delegation.finished(@child, id, status) end)

  def roll_back(id),
    do: observe(fn -> commit(@child, [{"run", id, %{"status" => "rolled_back"}}]) end)

  def restart do
    observe(fn ->
      HalC2.Prop.restart_service(HalC2.Streams)
      Delegation.reconcile(@parent)
    end)
  end

  # Boot interrupts the child's working run, and the project does not continue it. The
  # caller's turn is over by then: boot would interrupt its turn item, which the task
  # outlives.
  def restart_unresumed do
    observe(fn ->
      commit(@parent, [{"run", "parent-run", %{"status" => "completed"}}])
      HalC2.Prop.restart_service(HalC2.Streams)
      for id <- [@parent, @child], do: HalC2.Streams.flush_shell(id)
      HalC2.Orchestration.Recovery.run()
      HalC2.Orchestration.Recovery.continue()
    end)
  end

  defp observe(fun) do
    before = task()
    fun.()
    {before, task(), StreamState.list(stream(@child), "run")}
  end

  defp task do
    state = stream(@parent)

    %{
      "subagent" => StreamState.get(state, "subagent")[@task],
      "node" => StreamState.get(state, "node")[@task],
      "item" => StreamState.get(state, "turn-item")["turn-item:subagent:#{@task}"]
    }
  end

  defp run(id, status) do
    ordinal = id |> String.trim_leading("run-") |> String.to_integer()
    %{"id" => id, "ordinal" => ordinal, "status" => status, "updatedAt" => at(ordinal, 0)}
  end

  # A run's end is a time of its own, so the task's tells which run it was.
  defp ended(id, status) do
    run = run(id, status)
    end_at = at(run["ordinal"], 30)
    Map.merge(run, %{"completedAt" => end_at, "updatedAt" => end_at})
  end

  defp at(ordinal, second),
    do: "2026-01-01T00:#{pad(ordinal)}:#{pad(second)}.000Z"

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  defp answer(id), do: "answer of #{id}"

  defp commit(id, entities) do
    {:ok, _} =
      HalC2.Streams.commit(
        id,
        :thread,
        for({kind, eid, s} <- entities, do: {kind, eid, %{"s" => s}})
      )
  end

  defp stream(id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
end
