defmodule HalC2.DelegationWakesPropTest do
  @moduledoc """
  A state machine over the wakes of one caller whose turn delegated several tasks
  (`HalC2.Orchestration.Delegation`): the tasks end at any point, the caller's turns
  (its own, the user's, and the wakes) start, queue and end, and each end of a caller
  turn reports back (`Delegation.finished/3`) and starts the queue
  (`Orchestration.start_next/1`) in either order, as the turn writer's two processes
  may. `delegation_prop_test.exs` holds how one task settles; this holds how the
  results of many reach the caller (hal-c2/hal-c2#892).

  No provider is behind the caller: a turn the MC starts waits until the test ends it.
  After each command the test reads the caller back and checks what it is promised:

  - every task that ended is delivered, or waits on a wake for its turn already with
    the caller; none is dropped, however many wakes came before;
  - no task is named by two wakes, and every wake names its tasks once;
  - a wake runs as a turn of its own, never joining the turn it found working: the
    caller is on Codex or on Claude, and Claude would cancel its pending tools for a
    message mid-turn (Upstream #15892);

  and once the commands are done and the caller has worked through its queue, every
  task that ended was named by exactly one wake, and that wake ran to its end.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Delegation
  alias HalC2.StreamState

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @parent "parent"
  @tasks ~w(t1 t2 t3 t4)
  @active ~w(preparing starting running waiting)
  @models %{"codex" => "gpt-5.4", "claudeAgent" => "claude-sonnet-4-6"}

  for {instance, caller} <- [{"codex", "a Codex caller"}, {"claudeAgent", "a Claude caller"}] do
    property "every delegated result reaches #{caller} in exactly one wake that ran",
      numtests: HalC2.Prop.numtests(100),
      max_size: 30 do
      forall cmds <- commands(__MODULE__) do
        trap_exit do
          Process.put(:caller_instance, unquote(instance))
          run(cmds)
        end
      end
    end
  end

  defp run(cmds) do
    home = HalC2.Prop.scratch_home("delegation-wakes")

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      __MODULE__.Provider
    ])

    setup()
    {history, state, result} = run_commands(__MODULE__, cmds)
    drained = result == :ok and drained?(state)
    HalC2.Prop.stop_services()

    drained
    |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
    |> aggregate(command_names(cmds))
  end

  # Stands in for the effects runner: a turn the MC starts is taken and never driven,
  # so it stays active until `end_turn/1` ends it.
  defmodule Provider do
    use GenServer

    def start_link(_),
      do: GenServer.start_link(__MODULE__, nil, name: HalC2.Orchestration.Effects)

    def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, :ok, state}
  end

  # --- model ----------------------------------------------------------------------

  # ended: the tasks that ended, in order.
  def initial_state, do: %{ended: []}

  def command(state) do
    working = @tasks -- state.ended

    frequency(
      [
        {3, {:call, __MODULE__, :end_turn, [oneof([:report_first, :queue_first])]}},
        {2, {:call, __MODULE__, :start_next, []}},
        {1, {:call, __MODULE__, :user_turn, []}}
      ] ++
        if(working == [], do: [], else: [{4, {:call, __MODULE__, :finish, [oneof(working)]}}])
    )
  end

  def precondition(state, {:call, _, :finish, [task]}), do: task not in state.ended
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :finish, [task]}),
    do: %{state | ended: state.ended ++ [task]}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, call, args}, _result) do
    ended = if call == :finish, do: state.ended ++ args, else: state.ended
    caller = stream(@parent)

    ended?(caller, ended) and never_dropped?(caller) and wakes_agree?(caller) and
      own_turns?(caller)
  end

  # Each wake the caller is working on, or worked on, started that turn itself.
  defp own_turns?(caller) do
    runs = StreamState.get(caller, "run")

    Enum.all?(wakes(caller), fn {message, _ids} ->
      run = message["runId"] && runs[message["runId"]]
      run == nil or run["userMessageId"] == message["id"]
    end)
  end

  # The tasks that ended in the MC are those the model ended.
  defp ended?(caller, ended) do
    for(
      task <- StreamState.list(caller, "subagent"),
      task["status"] == "completed",
      do: task["id"]
    )
    |> Enum.sort() == Enum.sort(ended)
  end

  # Every ended task is delivered, by a wake naming it, or pending on a wake for its
  # turn that is with the caller now; never acknowledged to no one or disposed.
  defp never_dropped?(caller) do
    named = caller |> wakes() |> Enum.flat_map(fn {_message, ids} -> ids end)
    in_flight = in_flight(caller)

    Enum.all?(StreamState.list(caller, "subagent"), fn task ->
      case {task["status"], task["completionDelivery"]["state"]} do
        {"running", "pending"} -> true
        {"completed", "delivered"} -> task["id"] in named
        {"completed", "pending"} -> task["runId"] in in_flight and task["id"] not in named
        _ -> false
      end
    end)
  end

  # No task in two wakes, none named twice in one.
  defp wakes_agree?(caller) do
    named = caller |> wakes() |> Enum.flat_map(fn {_message, ids} -> ids end)
    length(named) == length(Enum.uniq(named))
  end

  # With the commands done, the caller works through what it has: each turn ends and
  # the next starts, until nothing is left. Every task that ended was then named by
  # one wake, which ran to its end.
  defp drained?(state) do
    drain(length(@tasks) * 2 + 20)
    caller = stream(@parent)
    runs = StreamState.get(caller, "run")
    wakes = wakes(caller)

    Enum.all?(state.ended, fn task ->
      case Enum.filter(wakes, fn {_message, ids} -> task in ids end) do
        [{message, _ids}] -> runs[message["runId"]]["status"] == "completed"
        _ -> false
      end
    end) and
      Enum.all?(StreamState.list(caller, "subagent"), fn task ->
        task["status"] != "completed" or task["completionDelivery"]["state"] == "delivered"
      end)
  end

  defp drain(0), do: :ok

  defp drain(steps) do
    runs = StreamState.list(stream(@parent), "run")

    cond do
      Enum.any?(runs, &(&1["status"] in @active)) ->
        end_turn(:report_first)
        drain(steps - 1)

      Enum.any?(runs, &(&1["status"] == "queued")) ->
        start_next()
        drain(steps - 1)

      true ->
        :ok
    end
  end

  # The wakes the caller was sent: a message naming the tasks it carries, with its run.
  defp wakes(caller) do
    for message <- StreamState.list(caller, "message"),
        ids = get_in(message, ["delegatedCompletion", "taskIds"]),
        ids != nil,
        do: {message, ids}
  end

  # The caller's turns a wake is with now: the turn that started each active wake.
  defp in_flight(caller) do
    runs = StreamState.get(caller, "run")

    for {message, _ids} <- wakes(caller),
        (runs[message["runId"]] || %{})["status"] in @active,
        do: message["delegatedCompletion"]["parentRunId"]
  end

  # --- the real side ----------------------------------------------------------------

  # The caller, with its turn running, and the tasks it delegated, each to a child
  # thread of its own with a run working.
  defp setup do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @parent,
        "projectId" => "project-1",
        "title" => "Caller",
        "modelSelection" => selection(),
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    open = %{"status" => "running", "completedAt" => nil}

    commit(
      @parent,
      [
        {"run", "parent-run",
         %{
           "id" => "parent-run",
           "ordinal" => 1,
           "status" => "running",
           "providerInstanceId" => selection()["instanceId"]
         }}
      ] ++
        Enum.flat_map(@tasks, fn task ->
          [
            {"subagent", task,
             Map.merge(open, %{
               "id" => task,
               "origin" => "app_owned",
               "runId" => "parent-run",
               "childThreadId" => child(task),
               "title" => task,
               "completionWake" => "always",
               "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil}
             })},
            {"node", task, Map.put(open, "id", task)}
          ]
        end)
    )

    for task <- @tasks do
      commit(child(task), [
        {"thread", child(task),
         %{
           "id" => child(task),
           "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => @parent}
         }},
        {"run", "run-1", %{"id" => "run-1", "ordinal" => 1, "status" => "running"}}
      ])
    end
  end

  # The task's child answers and its run ends, which reports to the caller at once.
  def finish(task) do
    commit(child(task), [
      {"message", "answer",
       %{"id" => "answer", "runId" => "run-1", "role" => "assistant", "text" => "#{task} done"}},
      {"run", "run-1", %{"status" => "completed", "completedAt" => "2026-01-01T00:00:00.000Z"}}
    ])

    Delegation.finished(child(task), "run-1", "completed")
  end

  # The caller's active turn ends, if it has one. As the turn writer does, the end
  # reports to delegation and starts the next queued turn, from two processes, so
  # either may come first.
  def end_turn(order) do
    case Enum.find(StreamState.list(stream(@parent), "run"), &(&1["status"] in @active)) do
      nil ->
        :ok

      run ->
        commit(@parent, [
          {"run", run["id"],
           %{"status" => "completed", "completedAt" => "2026-01-01T00:00:00.000Z"}}
        ])

        report = fn -> Delegation.finished(@parent, run["id"], "completed") end
        queue = fn -> HalC2.Orchestration.start_next(@parent) end
        steps = if order == :report_first, do: [report, queue], else: [queue, report]
        Enum.each(steps, & &1.())
    end

    :ok
  end

  # The queue starts its next turn, if the caller is idle and one waits.
  def start_next do
    HalC2.Orchestration.start_next(@parent)
    :ok
  end

  # The user sends the caller a message: it starts a turn, or waits behind the one
  # working.
  def user_turn do
    id = System.unique_integer([:positive])

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-user-#{id}",
        "threadId" => @parent,
        "messageId" => "msg-user-#{id}",
        "text" => "carry on",
        "attachments" => [],
        "modelSelection" => selection(),
        "dispatchMode" => %{"type" => "queue_after_active"},
        "createdBy" => "user",
        "creationSource" => "web"
      })

    :ok
  end

  defp child(task), do: "child-#{task}"

  # The caller's provider, picked for the run.
  defp selection do
    instance = Process.get(:caller_instance, "codex")
    %{"instanceId" => instance, "model" => @models[instance]}
  end

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
