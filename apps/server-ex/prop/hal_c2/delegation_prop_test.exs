defmodule HalC2.DelegationPropTest do
  @moduledoc """
  A state machine over one delegated task: how its child thread's runs start, queue,
  end (with an answer or without a word) and are rolled back, the background commands
  a run leaves running and their end, how each end is reported to the caller (at once,
  late, never, or again, and retried when a thread it reads fails), the checks for a quiet child (Grok's background work ending,
  the periodic check), and the MC restarting (`Delegation.reconcile/2` at boot), also
  when the restart interrupts the child's working run and nothing continues it
  (`Recovery`).

  The child's runs are written to its stream as the turn writer leaves them, with no
  provider behind them; the caller has a turn running, so the result message a report
  delivers waits in its queue and starts nothing. After each command the test reads the
  task back and checks what the caller is promised:

  - the task, its node and its turn item agree on how it ended;
  - once settled the task never changes, and its result reaches the caller at most once;
  - it is never settled while its child has a run active or queued, or a background
    command of a run not rolled back still running (hal-c2/hal-c2#508);
  - it ended as and when the child's last run not rolled back did, never when a report
    got through or the MC started, with the child's last answer in such a run;
  - a report, a check for a quiet child, or a restart settles it once the child is
    quiet, and a background command ending on a provider that wakes itself does not;
  - a delegation without a task prompt is refused, whatever the task is doing, and
    starts nothing;
  - a child whose worktree is still being prepared is working, and a task whose child
    fails or is cancelled while preparing settles as that, with why, though no turn
    ever ran in it;
  - a task that ended with its delivery still pending waits on a wake already with
    the caller for its run, never stranded with none in flight, and every wake
    names each of its tasks once, with the worst of their endings as its outcome.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Delegation
  alias HalC2.StreamState

  @moduletag timeout: :infinity
  @moduletag capture_log: true

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
        Application.delete_env(:hal_c2, :delegation_hook)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: the child's runs in ordinal order, %{id, status, ended_as}, `ended_as` how
  # the run ended before any rollback; held: runs whose end is yet to be reported;
  # commands: background commands, %{id, run, open}.
  def initial_state, do: %{runs: [], held: [], commands: []}

  def command(state) do
    running = for %{status: "running"} = run <- state.runs, do: run.id
    preparing = for %{status: "preparing"} = run <- state.runs, do: run.id
    queued = for %{status: "queued"} = run <- state.runs, do: run.id
    ended = for %{status: s} = run <- state.runs, s in @ended, do: run.id
    reported = for %{ended_as: s} = run <- state.runs, s != nil, do: [run.id, s]
    held = for [id, _] = args <- reported, id in state.held, do: args
    open = for %{open: true} = command <- state.commands, do: command.id

    frequency(
      [
        {1, {:call, __MODULE__, :restart, []}},
        {1, {:call, __MODULE__, :delegate_blank, [blank_task()]}},
        {1, {:call, __MODULE__, :check, []}}
      ] ++
        if(running == [], do: [], else: [{1, {:call, __MODULE__, :restart_unresumed, []}}]) ++
        if(working?(state),
          do: [],
          else: [
            {4, {:call, __MODULE__, :start, [next(state)]}},
            {1, {:call, __MODULE__, :start_preparing, [next(state)]}}
          ]
        ) ++
        if(preparing == [],
          do: [],
          else: [
            {3, {:call, __MODULE__, :prepare_end, [hd(preparing), oneof(~w(failed cancelled))]}}
          ]
        ) ++
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
              [
                hd(running),
                oneof(@ended),
                frequency([{3, :at_once}, {2, :late}, {1, :lost}]),
                frequency([{3, true}, {1, false}])
              ]}},
            {2,
             {:call, __MODULE__, :background, ["bg-#{length(state.commands) + 1}", hd(running)]}}
          ]
        ) ++
        if(open == [],
          do: [],
          else: [
            {3, {:call, __MODULE__, :end_background, [oneof(open), oneof([:wakes, :quiet])]}}
          ]
        ) ++
        if(held == [],
          do: [],
          else: [
            {3, let([id, s] <- oneof(held), do: {:call, __MODULE__, :report, [id, s, busy()]})}
          ]
        ) ++
        if(reported == [],
          do: [],
          else: [
            {1,
             let([id, s] <- oneof(reported), do: {:call, __MODULE__, :report, [id, s, busy()]})}
          ]
        ) ++
        if(ended == [], do: [], else: [{2, {:call, __MODULE__, :roll_back, [oneof(ended)]}}])
    )
  end

  # What an agent that mislabels or forgets the prompt sends as `delegate_task`'s input.
  defp blank_task do
    oneof([
      %{"prompt" => "Write the migration"},
      %{"title" => "Migration"},
      %{"task" => ""},
      %{"task" => " \n "},
      %{"task" => nil},
      %{"task" => 7}
    ])
  end

  # The thread whose check fails once in a report, before or after the task settles.
  defp busy, do: frequency([{3, nil}, {1, @child}, {1, @parent}])

  defp next(state), do: "run-#{length(state.runs) + 1}"

  defp working?(state), do: Enum.any?(state.runs, &(&1.status in ~w(preparing running queued)))

  def precondition(state, {:call, _, call, _}) when call in [:start, :start_preparing],
    do: not working?(state)

  def precondition(state, {:call, _, :queue, _}),
    do: Enum.any?(state.runs, &(&1.status == "running"))

  def precondition(state, {:call, _, :background, [id, run]}),
    do:
      Enum.any?(state.runs, &(&1.id == run and &1.status == "running")) and
        not Enum.any?(state.commands, &(&1.id == id))

  def precondition(state, {:call, _, :end_background, [id, _]}),
    do: Enum.any?(state.commands, &(&1.id == id and &1.open))

  def precondition(state, {:call, _, call, [id | _]})
      when call in [:cancel_queued, :finish, :roll_back, :report, :prepare_end] do
    case Enum.find(state.runs, &(&1.id == id)) do
      nil -> false
      run -> allowed?(call, run, state)
    end
  end

  def precondition(_state, _call), do: true

  defp allowed?(:cancel_queued, run, _), do: run.status == "queued"
  defp allowed?(:finish, run, _), do: run.status == "running"
  defp allowed?(:prepare_end, run, _), do: run.status == "preparing"
  defp allowed?(:roll_back, run, _), do: run.status in @ended
  defp allowed?(:report, run, _), do: run.ended_as != nil

  def next_state(state, _result, {:call, _, :start, [id]}),
    do: %{state | runs: state.runs ++ [%{id: id, status: "running", ended_as: nil}]}

  def next_state(state, _result, {:call, _, :start_preparing, [id]}),
    do: %{state | runs: state.runs ++ [%{id: id, status: "preparing", ended_as: nil}]}

  # Never reported again: its end is how the preparation ended, not a turn's answer.
  def next_state(state, _result, {:call, _, :prepare_end, [id, status]}),
    do: update(state, id, &%{&1 | status: status})

  def next_state(state, _result, {:call, _, :queue, [id]}),
    do: %{state | runs: state.runs ++ [%{id: id, status: "queued", ended_as: nil}]}

  def next_state(state, _result, {:call, _, :cancel_queued, [id]}),
    do: update(state, id, &%{&1 | status: "cancelled"})

  def next_state(state, _result, {:call, _, :finish, [id, status, how, _said]}) do
    state = update(state, id, &%{&1 | status: status, ended_as: status})
    if how == :late, do: %{state | held: [id | state.held]}, else: state
  end

  def next_state(state, _result, {:call, _, :report, [id, _, _]}),
    do: %{state | held: List.delete(state.held, id)}

  def next_state(state, _result, {:call, _, :roll_back, [id]}),
    do: update(state, id, &%{&1 | status: "rolled_back"})

  def next_state(state, _result, {:call, _, :background, [id, run]}),
    do: %{state | commands: state.commands ++ [%{id: id, run: run, open: true}]}

  def next_state(state, _result, {:call, _, :end_background, [id, _]}),
    do: %{
      state
      | commands: Enum.map(state.commands, &if(&1.id == id, do: %{&1 | open: false}, else: &1))
    }

  def next_state(state, _result, {:call, _, :restart, []}), do: state

  def next_state(state, _result, {:call, _, :check, []}), do: state

  def next_state(state, _result, {:call, _, :delegate_blank, _}), do: state

  def next_state(state, _result, {:call, _, :restart_unresumed, []}) do
    runs =
      for run <- state.runs do
        if run.status == "running",
          do: %{run | status: "interrupted", ended_as: "interrupted"},
          else: run
      end

    %{state | runs: runs, commands: Enum.map(state.commands, &%{&1 | open: false})}
  end

  defp update(state, id, fun),
    do: %{state | runs: Enum.map(state.runs, &if(&1.id == id, do: fun.(&1), else: &1))}

  # Every command returns the task before and after it, and the child's stream after.
  def postcondition(_state, {:call, _, call, args}, {before, task, child}) do
    agree?(task) and kept?(before, task) and never_owing?(before, task, child) and
      as_ended?(before, task, child) and delivered_once?() and pending_has_wake?() and
      wakes_agree?() and
      expected?(call, args, before, task, child)
  end

  # A task that ended with its delivery still pending is waiting on a wake already
  # with the caller (queued or running) for the run that started it; it is never
  # stranded pending with nothing in flight, which through the caller's owed work
  # would keep the caller from ever settling.
  defp pending_has_wake? do
    state = stream(@parent)
    messages = StreamState.get(state, "message")
    runs = StreamState.get(state, "run")

    Enum.all?(StreamState.list(state, "subagent"), fn task ->
      task["status"] not in @ended or
        get_in(task, ["completionDelivery", "state"]) != "pending" or
        Enum.any?(Map.values(messages), fn message ->
          get_in(message, ["delegatedCompletion", "parentRunId"]) == task["runId"] and
            (runs[message["runId"]] || %{})["status"] in ~w(queued preparing starting running waiting)
        end)
    end)
  end

  # Every wake names each of its tasks once, no task is in two wakes that ran or
  # wait, and a wake's outcome is the worst of its tasks' endings.
  defp wakes_agree? do
    state = stream(@parent)
    runs = StreamState.get(state, "run")
    tasks = StreamState.get(state, "subagent")

    wakes =
      for message <- StreamState.list(state, "message"),
          ids = get_in(message, ["delegatedCompletion", "taskIds"]),
          ids != nil,
          (runs[message["runId"]] || %{})["status"] != "cancelled" do
        {message, ids}
      end

    named = Enum.flat_map(wakes, fn {_message, ids} -> ids end)

    length(named) == length(Enum.uniq(named)) and
      Enum.all?(wakes, fn {message, ids} ->
        ids == Enum.uniq(ids) and
          message["notification"]["outcome"] ==
            worst(Enum.map(ids, &(tasks[&1] || %{})["status"]))
      end)
  end

  defp worst(statuses) do
    cond do
      "failed" in statuses -> "failed"
      Enum.any?(statuses, &(&1 in ["cancelled", "interrupted"])) -> "cancelled"
      true -> "completed"
    end
  end

  defp agree?(%{"subagent" => s, "node" => n, "item" => i}),
    do: s["status"] == n["status"] and n["status"] == i["status"]

  defp kept?(before, task), do: not settled?(before) or before == task

  # Settled only once the child is quiet: nothing running, queued, or owed.
  defp never_owing?(before, task, child),
    do: settled?(before) or not settled?(task) or quiet?(child)

  # As the child's last run not rolled back ended, with its last answer in such a
  # run, or what a run that left no answer says for itself.
  defp as_ended?(before, task, child) do
    settled?(before) or not settled?(task) or
      (task["subagent"]["status"] == ended_as(child) and
         task["subagent"]["completedAt"] == ended_at(child) and
         task["subagent"]["result"] ==
           (prepared(child) || last_answer(child) || no_answer(ended_as(child))))
  end

  defp no_answer("completed"), do: "Child task completed without an assistant result."
  defp no_answer("interrupted"), do: "Child task ended with status interrupted."
  defp no_answer(_status), do: nil

  defp delivered_once? do
    results =
      for message <- StreamState.list(stream(@parent), "message"),
          message["text"] =~ "<delegated_task_result",
          do: message

    # The one result names its worker and carries the same answer the caller reads.
    length(results) <= 1 and
      Enum.all?(results, fn %{"notification" => notification, "text" => text} ->
        notification["workerThreadId"] == @child and
          is_binary(notification["detail"]) and text =~ notification["detail"]
      end)
  end

  # What checks for a quiet child settles an unsettled task once it is quiet; the rest
  # settles nothing. A background command ending on a provider that wakes itself is no
  # reason to check: its wake run, queued after, ends and reports.
  defp expected?(call, args, before, task, child) do
    checks =
      case {call, args} do
        {:finish, [_, _, :at_once, _]} -> true
        {:end_background, [_, :quiet]} -> true
        {call, _} -> call in [:report, :check, :prepare_end, :restart, :restart_unresumed]
      end

    cond do
      settled?(before) -> true
      checks -> settled?(task) == (runs(child) != [] and quiet?(child))
      true -> not settled?(task)
    end
  end

  defp settled?(task), do: task["subagent"]["status"] in @ended

  defp runs(child), do: StreamState.list(child, "run") |> Enum.sort_by(& &1["ordinal"])

  # Runs not rolled back, but for one boot held in the queue and that never started.
  defp kept_runs(child),
    do:
      Enum.reject(
        runs(child),
        &(&1["status"] == "rolled_back" or HalC2.Projection.Shell.held_never_started?(&1))
      )

  defp quiet?(child),
    do:
      not Enum.any?(runs(child), &(&1["status"] in ~w(preparing running queued))) and
        not owing?(child)

  # A background command still running, of a run not rolled back, after a latest run
  # that was not.
  defp owing?(child) do
    rolled_back = for %{"status" => "rolled_back", "id" => id} <- runs(child), do: id

    List.last(runs(child))["status"] != "rolled_back" and
      Enum.any?(
        StreamState.list(child, "turn-item"),
        &(&1["type"] == "command_execution" and &1["status"] == "running" and
            &1["runId"] not in rolled_back)
      )
  end

  defp ended_as(child), do: (List.last(kept_runs(child)) || %{})["status"] || "cancelled"

  defp ended_at(child) do
    run = List.last(kept_runs(child)) || List.last(runs(child))
    run["completedAt"] || run["updatedAt"]
  end

  defp last_answer(child) do
    messages = StreamState.get(child, "message")

    kept_runs(child)
    |> Enum.map(&messages["answer-#{&1["id"]}"])
    |> Enum.reject(&is_nil/1)
    |> List.last(%{})
    |> Map.get("text")
  end

  # Why a child whose last run never started ended, as its preparation items say.
  defp prepared(child) do
    items = StreamState.get(child, "turn-item")
    id = (List.last(kept_runs(child)) || %{})["id"]

    cond do
      items["turn-item:workspace-preparation-failure:#{id}"] ->
        "Workspace preparation failed: no space left"

      items["turn-item:workspace-preparation:#{id}"]["status"] == "cancelled" ->
        "Workspace preparation was cancelled."

      true ->
        nil
    end
  end

  # --- the real side ----------------------------------------------------------------

  # The caller, with a turn running, and the task it delegated to a child thread.
  defp setup do
    Application.put_env(:hal_c2, :delegation_hook, {__MODULE__, :hook, []})

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

  # A delegation without a task prompt is refused and starts nothing (hal-c2/hal-c2#258).
  def delegate_blank(input) do
    observe(fn ->
      tasks = fn -> Enum.map(StreamState.list(stream(@parent), "subagent"), & &1["id"]) end
      before = tasks.()

      assert {:error, "invalid_task", _} =
               Delegation.delegate(%{"id" => @parent}, "codex", input)

      assert tasks.() == before
    end)
  end

  def start(id), do: observe(fn -> commit(@child, [{"run", id, run(id, "running")}]) end)

  # A run waiting on its worktree, with the "Preparing workspace" item the MC gives it.
  def start_preparing(id) do
    observe(fn ->
      commit(@child, [
        {"run", id, run(id, "preparing")},
        {"turn-item", "turn-item:workspace-preparation:#{id}",
         %{
           "id" => "turn-item:workspace-preparation:#{id}",
           "ordinal" => item_ordinal(),
           "type" => "command_execution",
           "runId" => id,
           "input" => "Preparing workspace",
           "status" => "running"
         }}
      ])
    end)
  end

  # The worktree setup fails or is cancelled. The report to the caller comes from a
  # process of its own; its hook names it, and its exit is the receipt that it is done.
  def prepare_end(id, status) do
    observe(fn ->
      Application.put_env(:hal_c2, :delegation_hook, {__MODULE__, :reporting, [self()]})
      failure = if status == "failed", do: %{"message" => "no space left"}
      :ok = HalC2.Orchestration.fail_prepared(@child, id, status, failure)
      assert_receive {:reporter, reporter}, 5_000
      ref = Process.monitor(reporter)
      assert_receive {:DOWN, ^ref, _, _, _}, 5_000
      Application.delete_env(:hal_c2, :delegation_hook)
    end)
  end

  def reporting(pid, :reporting, _id), do: send(pid, {:reporter, self()})
  def reporting(_pid, _stage, _id), do: :ok

  def queue(id), do: observe(fn -> commit(@child, [{"run", id, run(id, "queued")}]) end)

  def cancel_queued(id),
    do: observe(fn -> commit(@child, [{"run", id, ended(id, "cancelled")}]) end)

  # The run ends with its answer, or without a word (a turn that only handled a
  # monitor's update); its end is reported to the caller at once, later (`report/1`),
  # or never, as a crash between the two would lose it.
  def finish(id, status, how, said) do
    observe(fn ->
      answer =
        if said,
          do: [
            {"message", "answer-#{id}",
             %{"id" => "answer-#{id}", "runId" => id, "role" => "assistant", "text" => answer(id)}}
          ],
          else: []

      commit(@child, answer ++ [{"run", id, ended(id, status)}])

      if how == :at_once, do: Delegation.finished(@child, id, status)
    end)
  end

  # The end of run `id`, reported as it ended (`status`), whatever happened to it since.
  # With `busy`, the check of that thread exits the first time, as one restarting
  # under it would: the child's before its task can settle, the caller's (checked once the task ended)
  # after (`Delegation.report/5` retries).
  def report(id, status, busy) do
    observe(fn ->
      Process.put(:busy, busy)
      assert Delegation.report(@child, id, status, 1, 0) == :ok
      Process.delete(:busy)
    end)
  end

  # `Delegation`'s test hook: the check of the thread `report/3` names exits, once.
  def hook(:settling, id) do
    if Process.get(:busy) == id do
      Process.delete(:busy)
      exit(:busy)
    end
  end

  def hook(_stage, _id), do: :ok

  # Run `run` starts a command that keeps running in the background.
  def background(id, run) do
    observe(fn ->
      commit(@child, [
        {"turn-item", id,
         %{
           "id" => id,
           "ordinal" => item_ordinal(),
           "type" => "command_execution",
           "runId" => run,
           "input" => "npm run dev",
           "status" => "running"
         }}
      ])
    end)
  end

  # The command ends. A provider that wakes itself for it (Codex, Claude) starts a run
  # about it, which this model starts as any other; one that does not (Grok) checks
  # whether the child is quiet now.
  def end_background(id, how) do
    observe(fn ->
      commit(@child, [{"turn-item", id, %{"status" => "completed"}}])
      if how == :quiet, do: Delegation.settle_if_quiet(@child)
    end)
  end

  # The periodic check for a child no provider process drives.
  def check, do: observe(fn -> Delegation.settle_if_quiet(@child) end)

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
    {before, task(), stream(@child)}
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

  # Turn items are numbered, as the MC numbers them (`Orchestration.next_ordinal/1`).
  defp item_ordinal, do: HalC2.Orchestration.next_ordinal(stream(@child))

  defp stream(id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
end
