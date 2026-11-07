defmodule HalC2.DelegationPropTest do
  @moduledoc """
  A state machine over one delegated task: how its child thread's runs start, queue,
  end (with an answer or without a word) and are rolled back, the background commands
  a run leaves running and their end, how each end is reported to the caller (at once,
  late, never, or again, and retried when a thread it reads fails), the checks for a quiet child (Grok's background work ending,
  the periodic check), and the MC restarting (`Delegation.reconcile/2` at boot), also
  when the restart interrupts the child's working run and nothing continues it
  (`Recovery`), or ends the background command the child's finished turn waited on, or
  asks the child to continue and that continuation is later sent (also while a check
  reads the child) or given up on.

  The child's runs are written to its stream as the turn writer leaves them, with no
  provider behind them; the caller has a turn running, so the result message a report
  delivers waits in its queue and starts nothing. After each command the test reads the
  task back and checks what the caller is promised:

  - the task, its node and its turn item agree on how it ended;
  - once settled the task never changes, and its result reaches the caller at most once;
  - it is never settled while its child has a run active or queued, a background
    command of a run not rolled back still running (hal-c2/hal-c2#508), or a restart's
    continuation still to be sent (upstream #15323); a monitor left running unmarked
    never holds it (upstream #27468);
  - it ended as and when the child's last run not rolled back did, never when a report
    got through or the MC started, with the child's last answer in such a run; a run
    that ended to wait on background work a restart ended was interrupted (upstream
    #19291);
  - a report, a check for a quiet child, or a restart settles it once the child is
    quiet, and a background command ending on a provider that wakes itself does not;
  - a delegation without a task prompt is refused, whatever the task is doing, and
    starts nothing;
  - a child whose worktree is still being prepared is working, and a task whose child
    fails or is cancelled while preparing settles as that, with why, though no turn
    ever ran in it;
  - a task that ended with its delivery still pending waits on a wake already with
    the caller for its run, never stranded with none in flight, and every wake
    names each of its tasks once, with the worst of their endings as its outcome;
  - cancelling a task that has not ended cancels it, disposes of its delivery and
    leaves the child nothing queued, whatever the child was doing (also nothing at
    all); cancelling one that ended is refused and changes nothing;
  - the user stopping a child that never started a run cancels its task, which wakes
    no one;
  - an interrupt of the caller's run that is not the user's Stop (an agent's
    `hal_c2_thread_interrupt`, a scheduled prompt's clean-up) leaves the task and its
    child as they were: only its result stops waking that run;
  - the child carries a pull request from the start, and a settled task's result
    names it for the caller to watch (upstream #19801), also when a handover
    (`hand_over_pull_requests/1`, as `HalC2.PullRequests.Wakes` calls it on PR news
    for a quiet child) tombstoned the child's link and gave the caller its copy
    before the task settled.
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
  # commands: background commands, %{id, run, open}; monitors: monitors left running
  # unmarked, which never owe; continuing: the run a restart interrupted and asked
  # the child to continue, while that continuation is unsent.
  def initial_state, do: %{runs: [], held: [], commands: [], monitors: [], continuing: nil}

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
        {1, {:call, __MODULE__, :check, []}},
        {2, {:call, __MODULE__, :hand_over, []}},
        {1, {:call, __MODULE__, :cancel, []}},
        {1, {:call, __MODULE__, :interrupt_caller, []}}
      ] ++
        if(state.runs == [], do: [{1, {:call, __MODULE__, :stop_child, []}}], else: []) ++
        if(running == [],
          do: [],
          else: [
            {1, {:call, __MODULE__, :restart_unresumed, []}},
            {1, {:call, __MODULE__, :restart_continued, [hd(running)]}}
          ]
        ) ++
        if(waiting?(state),
          do: [{3, {:call, __MODULE__, :restart_waiting, []}}],
          else: []
        ) ++
        if(state.continuing == nil,
          do: [],
          else: [
            {3, {:call, __MODULE__, :send_continuation, [state.continuing, next(state)]}},
            {2,
             {:call, __MODULE__, :check_while_sent,
              [state.continuing, next(state), oneof([:continuations, :continued])]}},
            {1, {:call, __MODULE__, :abandon_continuation, [state.continuing]}}
          ]
        ) ++
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
                frequency([{3, "completed"}, {1, oneof(@ended)}]),
                frequency([{3, :at_once}, {2, :late}, {1, :lost}]),
                frequency([{3, true}, {1, false}])
              ]}},
            {3,
             {:call, __MODULE__, :background, ["bg-#{length(state.commands) + 1}", hd(running)]}},
            {2, {:call, __MODULE__, :monitor, ["mon-#{length(state.monitors) + 1}", hd(running)]}}
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

  # The child's turn ended (completed) with a background command of it still running.
  defp waiting?(state) do
    latest = List.last(state.runs)

    not working?(state) and latest != nil and latest.status == "completed" and
      Enum.any?(state.commands, &(&1.open and &1.run == latest.id))
  end

  defp working?(state),
    do:
      state.continuing != nil or
        Enum.any?(state.runs, &(&1.status in ~w(preparing running queued)))

  def precondition(state, {:call, _, call, _}) when call in [:start, :start_preparing],
    do: not working?(state)

  def precondition(state, {:call, _, :restart_waiting, _}), do: waiting?(state)

  def precondition(state, {:call, _, :queue, _}),
    do: Enum.any?(state.runs, &(&1.status == "running"))

  def precondition(state, {:call, _, :background, [id, run]}),
    do:
      Enum.any?(state.runs, &(&1.id == run and &1.status == "running")) and
        not Enum.any?(state.commands, &(&1.id == id))

  def precondition(state, {:call, _, :monitor, [id, run]}),
    do:
      Enum.any?(state.runs, &(&1.id == run and &1.status == "running")) and
        id not in state.monitors

  def precondition(state, {:call, _, :restart_continued, [id]}),
    do:
      state.continuing == nil and Enum.any?(state.runs, &(&1.id == id and &1.status == "running"))

  def precondition(state, {:call, _, call, [id | _]})
      when call in [:send_continuation, :check_while_sent, :abandon_continuation],
      do: state.continuing == id

  def precondition(state, {:call, _, :end_background, [id, _]}),
    do: Enum.any?(state.commands, &(&1.id == id and &1.open))

  def precondition(state, {:call, _, call, [id | _]})
      when call in [:cancel_queued, :finish, :roll_back, :report, :prepare_end] do
    case Enum.find(state.runs, &(&1.id == id)) do
      nil -> false
      run -> allowed?(call, run, state)
    end
  end

  def precondition(state, {:call, _, :stop_child, []}), do: state.runs == []

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

  def next_state(state, _result, {:call, _, :monitor, [id, _run]}),
    do: %{state | monitors: state.monitors ++ [id]}

  def next_state(state, _result, {:call, _, :end_background, [id, _]}),
    do: %{
      state
      | commands: Enum.map(state.commands, &if(&1.id == id, do: %{&1 | open: false}, else: &1))
    }

  def next_state(state, _result, {:call, _, :restart, []}), do: state

  def next_state(state, _result, {:call, _, :check, []}), do: state

  def next_state(state, _result, {:call, _, :hand_over, []}), do: state

  # The cancel cancels what the child queued and asks its turn to stop, which with no
  # provider behind these runs stays running. A cancel refused (the task had ended)
  # cancels nothing; the model takes the queue as cancelled all the same, which no
  # check reads once the task has settled.
  def next_state(state, _result, {:call, _, :cancel, []}) do
    runs =
      for run <- state.runs,
          do: if(run.status == "queued", do: %{run | status: "cancelled"}, else: run)

    %{state | runs: runs}
  end

  def next_state(state, _result, {:call, _, :stop_child, []}), do: state

  def next_state(state, _result, {:call, _, :interrupt_caller, []}), do: state

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

  def next_state(state, _result, {:call, _, :restart_waiting, []}),
    do: next_state(state, nil, {:call, __MODULE__, :restart_unresumed, []})

  def next_state(state, _result, {:call, _, :restart_continued, [id]}) do
    state = next_state(state, nil, {:call, __MODULE__, :restart_unresumed, []})
    %{state | continuing: id}
  end

  def next_state(state, _result, {:call, _, :send_continuation, [_, id]}),
    do: %{
      state
      | continuing: nil,
        runs: state.runs ++ [%{id: id, status: "running", ended_as: nil}]
    }

  def next_state(state, _result, {:call, _, :check_while_sent, [interrupted, id, _]}),
    do: next_state(state, nil, {:call, __MODULE__, :send_continuation, [interrupted, id]})

  def next_state(state, _result, {:call, _, :abandon_continuation, _}),
    do: %{state | continuing: nil}

  defp update(state, id, fun),
    do: %{state | runs: Enum.map(state.runs, &if(&1.id == id, do: fun.(&1), else: &1))}

  # A cancel ends the task at once, child working or not, and no result wakes the
  # caller; nothing the child queued is left to start. One that ended stays as it was.
  # (Its running turn is the provider's to stop, and these runs have none behind them.)
  def postcondition(_state, {:call, _, call, []}, {before, task, child})
      when call in [:cancel, :stop_child] do
    agree?(task) and delivered_once?() and pending_has_wake?() and wakes_agree?() and
      if settled?(before),
        do: before == task,
        else:
          task["subagent"]["status"] == "cancelled" and
            task["subagent"]["completionDelivery"]["state"] == "disposed" and
            not Enum.any?(runs(child), &(&1["status"] == "queued"))
  end

  # Nothing of the task changes but its delivery, which the interrupted run no longer
  # waits on. A cancel cascading from it would show here, or in the checks of the
  # commands after it (the task settled while its child works).
  def postcondition(_state, {:call, _, :interrupt_caller, []}, {before, task, _child}) do
    unwaited = fn task ->
      update_in(task, ["subagent"], &Map.drop(&1, ["completionDelivery", "updatedAt"]))
    end

    agree?(task) and delivered_once?() and pending_has_wake?() and wakes_agree?() and
      unwaited.(before) == unwaited.(task)
  end

  # Every command returns the task before and after it, and the child's stream after.
  def postcondition(state, {:call, _, call, args} = command, {before, task, child}) do
    # A continuation still to be sent is work, however quiet the child's runs are.
    continuing = next_state(state, nil, command).continuing != nil
    quiet = not continuing and quiet?(child)

    agree?(task) and kept?(before, task) and never_owing?(before, task, quiet) and
      as_ended?(before, task, child) and delivered_once?() and pending_has_wake?() and
      wakes_agree?() and
      expected?(call, args, before, task, child, quiet)
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
  defp never_owing?(before, task, quiet),
    do: settled?(before) or not settled?(task) or quiet

  # As the child's last run not rolled back ended, with its last answer in such a
  # run, or what a run that left no answer says for itself. The result also names
  # the pull request the child carries (setup), handed to the caller to watch,
  # whether the child still shows it or a handover already tombstoned its link
  # and left the caller its copy.
  defp as_ended?(before, task, child) do
    settled?(before) or not settled?(task) or
      (task["subagent"]["status"] == ended_as(child) and
         task["subagent"]["completedAt"] == ended_at(child) and
         task["subagent"]["result"] ==
           "#{prepared(child) || last_answer(child) || no_answer(ended_as(child))}" <>
             "\n\nPull requests handed to you to watch: acme/app#7 at abc123 (checks pending).")
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
  defp expected?(call, args, before, task, child, quiet) do
    checks =
      case {call, args} do
        {:finish, [_, _, :at_once, _]} ->
          true

        {:end_background, [_, :quiet]} ->
          true

        {call, _} ->
          call in [
            :report,
            :check,
            :prepare_end,
            :restart,
            :restart_unresumed,
            :restart_waiting,
            :restart_continued,
            :check_while_sent,
            :abandon_continuation
          ]
      end

    cond do
      settled?(before) -> true
      checks -> settled?(task) == (runs(child) != [] and quiet)
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

  # A run that ended to wait on background work a restart ended was interrupted.
  defp ended_as(child) do
    case List.last(kept_runs(child)) do
      %{"status" => "completed", "id" => id} ->
        cut? =
          Enum.any?(
            StreamState.list(child, "turn-item"),
            &(&1["runId"] == id and &1["status"] == "interrupted" and
                &1["statusDetail"] =~ "because the server restarted")
          )

        if cut?, do: "interrupted", else: "completed"

      run ->
        (run || %{})["status"] || "cancelled"
    end
  end

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

    # The child opened a pull request its caller is to watch once the task ends.
    commit(@child, [
      {"thread", @child,
       %{
         "id" => @child,
         "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => @parent},
         "pullRequests" => [
           %{
             "host" => "github.com",
             "repository" => "acme/app",
             "number" => 7,
             "url" => "https://github.com/acme/app/pull/7",
             "source" => "agent",
             "snapshot" => %{"headSha" => "abc123", "checksState" => "pending"}
           }
         ]
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

  # A check racing the continuation (`check_while_sent/3`): it is sent, and its effect
  # gone, at the stage of the check that names it.
  def hook(stage, @child) when stage in [:continuations, :continued] do
    case Process.get(:sending) do
      {^stage, interrupted, id} ->
        Process.delete(:sending)
        sent(interrupted, id)

      _ ->
        :ok
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

  # A monitor left running that the child never marked as work it waits on: it
  # runs until stopped, so it is never owed and the task still settles
  # (upstream #27468). The model's `owing?/1` counts only commands, as here.
  def monitor(id, run) do
    observe(fn ->
      commit(@child, [
        {"turn-item", id,
         %{
           "id" => id,
           "ordinal" => item_ordinal(),
           "type" => "dynamic_tool",
           "toolName" => "Monitor",
           "runId" => run,
           "input" => %{"command" => "tail -f log/dev.log"},
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

  # `task_cancel`, refused only for a task that ended.
  def cancel do
    observe(fn ->
      ended = settled?(task())
      result = Delegation.cancel(@parent, @task)

      if ended,
        do: assert(match?({:error, "task_not_cancellable", _}, result)),
        else: assert(match?({:ok, %{"status" => "cancelled"}}, result))
    end)
  end

  # The user presses Stop on the child thread.
  def stop_child do
    observe(fn ->
      HalC2.Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @child})
    end)
  end

  # An agent's `hal_c2_thread_interrupt` of the caller's turn, not the user's Stop.
  def interrupt_caller do
    observe(fn ->
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => @parent,
        "runId" => "parent-run"
      })
    end)
  end

  # The periodic check for a child no provider process drives.
  def check, do: observe(fn -> Delegation.settle_if_quiet(@child) end)

  # PR news for the child (`HalC2.PullRequests.Wakes`): a quiet child's links are
  # handed to its caller then, settle or not, which tombstones the child's link.
  def hand_over, do: observe(fn -> Delegation.hand_over_pull_requests(@child) end)

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

  # The child's turn had ended to wait on its background command when the MC stopped:
  # boot ends the command, and nothing continues the child.
  def restart_waiting, do: restart_unresumed()

  # Boot interrupts the child's working run and asks it to continue: the continuation's
  # effect waits in the outbox (`Recovery.continue/0`), and the boot checks the caller's
  # tasks then (`Delegation.reconcile(parent, false)`).
  def restart_continued(id) do
    observe(fn ->
      commit(@parent, [{"run", "parent-run", %{"status" => "completed"}}])
      HalC2.Prop.restart_service(HalC2.Streams)
      interrupt = ended(id, "interrupted")

      items =
        for item <- StreamState.list(stream(@child), "turn-item"),
            item["status"] == "running",
            do: {"turn-item", item["id"], %{"status" => "interrupted"}}

      commit(@child, [{"run", id, interrupt} | items])
      put_continuation(id, "pending")
      Delegation.reconcile(@parent, false)
    end)
  end

  # The continuation is sent: its message and the run it starts are in, then its
  # effect is done and gone, as the outbox leaves it.
  def send_continuation(interrupted, id), do: observe(fn -> sent(interrupted, id) end)

  # The periodic check runs as the continuation is sent: after its first read of the
  # child, before it reads the child's continuations (`:continuations`) or between that
  # and its newer read of the child (`:continued`).
  def check_while_sent(interrupted, id, stage) do
    observe(fn ->
      Process.put(:sending, {stage, interrupted, id})
      Delegation.settle_if_quiet(@child)
      # The check reaches that stage only when the child looked quiet first.
      if Process.delete(:sending), do: sent(interrupted, id)
    end)
  end

  defp sent(interrupted, id) do
    message = "message:restart-continuation:#{interrupted}"

    commit(@child, [
      {"message", message,
       %{"id" => message, "runId" => id, "role" => "user", "text" => "Continue"}},
      {"run", id, run(id, "running")}
    ])

    :ok = HalC2.Store.delete_meta(continuation_key(interrupted))
  end

  # Its tries run out: the effect is kept as failed and the periodic check settles.
  def abandon_continuation(interrupted) do
    observe(fn ->
      put_continuation(interrupted, "failed")
      Delegation.settle_if_quiet(@child)
    end)
  end

  defp put_continuation(interrupted, status) do
    record = %{
      "id" => "effect-continue-#{interrupted}",
      "threadId" => @child,
      "type" => "provider-runtime.continue",
      "lane" => "provider",
      "status" => status,
      "createdAt" => "2026-01-01T01:00:00.000Z",
      "args" => %{"command" => %{"messageId" => "message:restart-continuation:#{interrupted}"}}
    }

    :ok = HalC2.Store.put_meta(continuation_key(interrupted), JSON.encode!(record))
  end

  defp continuation_key(interrupted),
    do: "effect:#{@child}:effect-continue-#{interrupted}"

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
