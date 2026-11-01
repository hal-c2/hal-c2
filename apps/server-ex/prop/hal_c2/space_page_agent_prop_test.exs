defmodule HalC2.SpacePageAgentPropTest do
  @moduledoc """
  A state machine over the agents asked from the pages of one Space
  (`HalC2.Space.PageAgent`): asks, valid and blank; edits by the agent; runs ending as
  completed, failed or interrupted; stops; dismissals; a page trashed, restored and
  deleted for good; reports from a thread an earlier ask started; launches and reports a
  crash lost, and the reconciliation at the next start; threads deleted, moving, moved
  away and kept; and the streams restarting. The thread is a fake one written straight
  to its stream, so no provider is needed; what a run ended as is what the entity reads.

  After each command the test reads the Space's stream back and checks it against the
  model:

  - a page has at most one agent, and an ask while it is at work is refused and writes
    nothing, as is one on a page in the trash;
  - an agent ends only by its own thread ending or a stop: a report from a thread an
    earlier ask started, or one with its run still going, writes nothing;
  - an agent ended says what its run ended as, and whether its thread edited the page;
  - nothing can leave an agent working once its thread has nothing left to do: a deleted
    or moved thread settles it with the reason, a move given up reports what it held
    back, and the reconciliation settles every lost launch and report, but never a run
    still going, a thread moving or one about to continue;
  - a queued run held for the user is not work: it does not keep the page working or
    decide how the agent ended, and neither does one the user cancelled;
  - background work its run left keeps an agent working until it ends, unless a stop was
    asked for: that waits for runs only;
  - a run interrupted without a stop says why;
  - a stop marks an agent stopping, whatever its run then ends as it says stopped, and
    a page with none refuses; on one that has ended it changes nothing;
  - the reconciliation finishes a stop a crash cut short: a run the restart put back in the
    queue is cancelled, and a thread said to be about to go on is no exception;
  - a dismissal is refused while the agent is at work;
  - deleting a page for good takes its agent with it.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Patch, Space, StreamState, Streams}
  alias HalC2.Space.PageAgent

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @pages ~w(p1 p2)
  @active ~w(running stopping)
  @background_item "background-command"
  @ended %{"completed" => "completed", "failed" => "failed", "interrupted" => "stopped"}

  property "the agents of a Space's pages follow the model",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("space-page-agent")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams
        ])

        test = self()
        Application.put_env(:hal_c2, :page_agent_launch, &fake_thread(&1, test))
        {:ok, space} = Space.create("Prop")
        Process.put(:space, space["id"])
        Process.put(:names, %{})
        Process.put(:threads, %{})
        {history, state, result} = run_commands(__MODULE__, cmds)
        Application.delete_env(:hal_c2, :page_agent_launch)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # pages: name => %{trashed, blocks, asks, agent}; an agent is nil or %{status, edited,
  # wrote, said, run, moving}: it wrote as it edits, and says edited once it ends; said is
  # whether it gave a reason; run is what its run is (nil before a launch that never
  # came); moving is whether its thread is in a move. asks counts this page's threads, so
  # a report can name an old one.
  def initial_state, do: %{pages: %{}}

  def command(s) do
    pages = Map.keys(s.pages)

    frequency(
      [{2, {:call, __MODULE__, :create_page, [elements(@pages)]}}] ++
        if(pages == [],
          do: [],
          else: [
            {5,
             {:call, __MODULE__, :ask, [elements(pages), elements(["tidy", "@agent tidy", " "])]}},
            {1, {:call, __MODULE__, :ask_lost, [elements(pages)]}},
            {4, {:call, __MODULE__, :lose_report, [elements(pages), elements(Map.keys(@ended))]}},
            {2, {:call, __MODULE__, :hold_message, [elements(pages)]}},
            {3, {:call, __MODULE__, :cancel_message, [elements(pages)]}},
            {3, {:call, __MODULE__, :requeue_run, [elements(pages)]}},
            {3, {:call, __MODULE__, :leave_background, [elements(pages)]}},
            {3, {:call, __MODULE__, :end_background, [elements(pages)]}},
            {1, {:call, __MODULE__, :delete_thread, [elements(pages)]}},
            {4, {:call, __MODULE__, :begin_move, [elements(pages)]}},
            {4, {:call, __MODULE__, :give_up_move, [elements(pages)]}},
            {4, {:call, __MODULE__, :move_away, [elements(pages)]}},
            {1, {:call, __MODULE__, :reconcile_continuing, [elements(pages)]}},
            {2,
             {:call, __MODULE__, :continuation_fails,
              [elements(pages), elements([:refused, :crashed, :crashed_again_later])]}},
            {3, {:call, __MODULE__, :edit, [elements(pages)]}},
            {4, {:call, __MODULE__, :end_run, [elements(pages), elements(Map.keys(@ended))]}},
            {2, {:call, __MODULE__, :report_running, [elements(pages)]}},
            {2, {:call, __MODULE__, :report_old, [elements(pages)]}},
            {3, {:call, __MODULE__, :stop, [elements(pages)]}},
            {3, {:call, __MODULE__, :dismiss, [elements(pages)]}},
            {1, {:call, __MODULE__, :trash, [elements(pages)]}},
            {1, {:call, __MODULE__, :restore, [elements(pages)]}},
            {1, {:call, __MODULE__, :delete, [elements(pages)]}}
          ]
        ) ++
        [{1, {:call, __MODULE__, :restart, []}}, {2, {:call, __MODULE__, :reconcile, []}}]
    )
  end

  def precondition(s, {:call, _, :create_page, [name]}), do: not Map.has_key?(s.pages, name)
  def precondition(_s, {:call, _, cmd, []}) when cmd in [:restart, :reconcile], do: true

  def precondition(s, {:call, _, :edit, [name]}),
    do: going?(s, name) and not s.pages[name].trashed

  def precondition(s, {:call, _, cmd, [name | _]})
      when cmd in [:end_run, :report_running, :lose_report, :continuation_fails],
      do: going?(s, name)

  def precondition(s, {:call, _, :reconcile_continuing, [name]}), do: active?(s, name)

  # Stands in for what a real thread could be doing, so it needs one that exists.
  def precondition(s, {:call, _, :delete_thread, [name]}),
    do: active?(s, name) and s.pages[name].agent.run != nil

  # A held run is the latest, and nothing counts as background behind one that has not
  # settled (`HalC2.Projection.BackgroundWork`), so the two are not combined here.
  def precondition(s, {:call, _, cmd, [name]}) when cmd in [:hold_message, :leave_background] do
    active?(s, name) and s.pages[name].agent.run != nil and
      not s.pages[name].agent.held and not s.pages[name].agent.background
  end

  def precondition(s, {:call, _, :cancel_message, [name]}),
    do: active?(s, name) and s.pages[name].agent.run != nil

  # What a restart does to a run its provider never got; only one being stopped is left
  # like this here, as nothing in the model starts the run again.
  def precondition(s, {:call, _, :requeue_run, [name]}),
    do: going?(s, name) and s.pages[name].agent.status == "stopping"

  def precondition(s, {:call, _, :end_background, [name]}),
    do: active?(s, name) and s.pages[name].agent.background

  def precondition(s, {:call, _, :begin_move, [name]}) do
    active?(s, name) and s.pages[name].agent.run not in [nil, "running", "requeued"] and
      not s.pages[name].agent.moving
  end

  def precondition(s, {:call, _, cmd, [name]}) when cmd in [:give_up_move, :move_away],
    do: active?(s, name) and s.pages[name].agent.moving

  def precondition(s, {:call, _, :report_old, [name]}),
    do: Map.has_key?(s.pages, name) and s.pages[name].asks > 1

  def precondition(s, {:call, _, _, [name | _]}), do: Map.has_key?(s.pages, name)

  defp active?(s, name),
    do: match?(%{agent: %{status: status}} when status in @active, s.pages[name])

  defp going?(s, name), do: active?(s, name) and s.pages[name].agent.run == "running"

  def next_state(s, _result, {:call, _, cmd, args}), do: elem(step(s, cmd, args), 1)

  def postcondition(s, {:call, _, cmd, args}, {reply, events, snapshot}) do
    {expected, next, writes} = step(s, cmd, args)
    reply == expected and writes in [nil, min(events, 1)] and snapshot == snapshot(next)
  end

  # What a command replies, the model after it, and whether it writes (0 or 1, however
  # many events a change takes); nil for the page's own commands, which
  # `HalC2.SpacePropTest` keeps count of.
  defp step(s, :create_page, [name]),
    do: {:ok, put(s, name, %{trashed: false, blocks: 0, asks: 0, agent: nil}), nil}

  defp step(s, :ask, [name, request]) do
    page = s.pages[name]

    cond do
      String.trim(String.replace(request, "@agent", "")) == "" -> {:invalid, s, 0}
      page.trashed -> {:trashed, s, 0}
      active?(s, name) -> {:invalid, s, 0}
      true -> {:ok, put(s, name, %{page | asks: page.asks + 1, agent: agent("running")}), 1}
    end
  end

  defp step(s, :ask_lost, [name]) do
    page = s.pages[name]

    cond do
      page.trashed -> {:trashed, s, 0}
      active?(s, name) -> {:invalid, s, 0}
      true -> {:ok, put(s, name, %{page | asks: page.asks + 1, agent: agent(nil)}), 1}
    end
  end

  defp step(s, :edit, [name]) do
    page = s.pages[name]

    {:ok, put(s, name, %{page | blocks: page.blocks + 1, agent: %{page.agent | wrote: true}}),
     nil}
  end

  defp step(s, :end_run, [name, ended]) do
    page = s.pages[name]
    settle_if_over(put(s, name, %{page | agent: %{page.agent | run: ended}}), name)
  end

  defp step(s, :lose_report, [name, ended]) do
    page = s.pages[name]
    {:ok, put(s, name, %{page | agent: %{page.agent | run: ended}}), 0}
  end

  # A try that will be retried says nothing yet: the thread may still go on.
  defp step(s, :continuation_fails, [name, :crashed_again_later]),
    do: step(s, :lose_report, [name, "interrupted"])

  defp step(s, :continuation_fails, [name, _how]), do: step(s, :end_run, [name, "interrupted"])

  defp step(s, :hold_message, [name]), do: {:ok, update_agent(s, name, %{held: true}), 0}

  defp step(s, :cancel_message, _), do: {:ok, s, 0}
  defp step(s, :requeue_run, [name]), do: {:ok, update_agent(s, name, %{run: "requeued"}), 0}

  defp step(s, :leave_background, [name]),
    do: {:ok, update_agent(s, name, %{background: true}), 0}

  defp step(s, :end_background, [name]),
    do: settle_if_over(update_agent(s, name, %{background: false}), name)

  defp step(s, :delete_thread, [name]), do: {:ok, settle(s, name, "stopped", true), 1}

  defp step(s, :begin_move, [name]) do
    page = s.pages[name]
    {:ok, put(s, name, %{page | agent: %{page.agent | moving: true}}), 0}
  end

  defp step(s, :give_up_move, [name]) do
    page = s.pages[name]
    settle_if_over(put(s, name, %{page | agent: %{page.agent | moving: false}}), name)
  end

  defp step(s, :move_away, [name]), do: {:ok, settle(s, name, "stopped", true), 1}

  defp step(s, :report_running, _), do: {:ok, s, 0}
  defp step(s, :report_old, _), do: {:ok, s, 0}

  defp step(s, :reconcile, []), do: reconcile(s, nil)
  defp step(s, :reconcile_continuing, [name]), do: reconcile(s, name)

  # A fake run goes on until `end_run` ends it, as one a provider is slow to stop would. A
  # stop of an agent with nothing left to do settles it at once.
  defp step(s, :stop, [name]) do
    case s.pages[name] do
      %{agent: nil} ->
        {:not_found, s, 0}

      %{agent: %{status: "running"} = agent} = page ->
        stopping = %{agent | status: "stopping"}
        marked = put(s, name, %{page | agent: stopping})
        {:ok, if(over?(stopping), do: settle(marked, name, "stopped", false), else: marked), 1}

      %{agent: %{status: "stopping"} = agent} ->
        if stops_now?(agent),
          do: {:ok, settle(s, name, "stopped", false), 1},
          else: {:ok, s, 0}

      _ ->
        {:ok, s, 0}
    end
  end

  defp step(s, :dismiss, [name]) do
    case s.pages[name] do
      %{agent: nil} -> {:not_found, s, 0}
      %{agent: %{status: status}} when status in @active -> {:invalid, s, 0}
      page -> {:ok, put(s, name, %{page | agent: nil}), 1}
    end
  end

  defp step(s, :trash, [name]) do
    page = s.pages[name]
    if page.trashed, do: {:trashed, s, 0}, else: {:ok, put(s, name, %{page | trashed: true}), nil}
  end

  defp step(s, :restore, [name]) do
    page = s.pages[name]

    if page.trashed,
      do: {:ok, put(s, name, %{page | trashed: false}), nil},
      else: {:invalid, s, 0}
  end

  defp step(s, :delete, [name]) do
    page = s.pages[name]

    if page.trashed,
      do: {:ok, %{s | pages: Map.delete(s.pages, name)}, nil},
      else: {:invalid, s, 0}
  end

  defp step(s, :restart, []), do: {:ok, s, 0}

  # A thread about to go on is left, whatever else settles, unless it was asked to stop.
  defp reconcile(s, continuing) do
    next =
      for {name, _} <- s.pages,
          active?(s, name),
          name != continuing or s.pages[name].agent.status == "stopping",
          reduce: s do
        acc -> if stops_now?(acc.pages[name].agent), do: run_over(acc, name), else: acc
      end

    {:ok, next, if(next == s, do: 0, else: 1)}
  end

  defp agent(run) do
    %{
      status: "running",
      edited: false,
      wrote: false,
      said: false,
      run: run,
      moving: false,
      held: false,
      background: false
    }
  end

  defp update_agent(s, name, fields) do
    page = s.pages[name]
    put(s, name, %{page | agent: Map.merge(page.agent, fields)})
  end

  # The Space's stream only hears of this if the agent settled.
  defp settle_if_over(s, name) do
    if over?(s.pages[name].agent), do: {:ok, run_over(s, name), 1}, else: {:ok, s, 0}
  end

  defp put(s, name, page), do: %{s | pages: Map.put(s.pages, name, page)}

  # A stop waits for runs only: what they left in the background can go on for good.
  defp over?(%{run: run, moving: moving, background: background, status: status}) do
    run not in ["running", "requeued"] and not moving and
      (not background or status == "stopping")
  end

  # Over once what can still be stopped has been: a stop cancels a run in the queue.
  defp stops_now?(%{run: "requeued", status: "stopping"}), do: true
  defp stops_now?(agent), do: over?(agent)

  # What its run ended as: a lost launch fails with a reason, as a failed run does.
  defp run_over(s, name) do
    case s.pages[name].agent.run do
      nil -> settle(s, name, "failed", true)
      ended -> settle(s, name, @ended[ended], ended in ["failed", "interrupted"])
    end
  end

  # A stop asked for says stopped, and needs no reason.
  defp settle(s, name, status, said) do
    page = s.pages[name]
    agent = page.agent
    stopping? = agent.status == "stopping"

    settled = %{
      agent
      | status: if(stopping?, do: "stopped", else: status),
        said: said and not stopping?,
        edited: agent.wrote
    }

    put(s, name, %{page | agent: settled})
  end

  defp snapshot(s) do
    for {name, %{agent: %{} = agent}} <- s.pages,
        into: %{},
        do: {name, {agent.status, agent.edited, agent.said}}
  end

  # --- commands -------------------------------------------------------------------

  def create_page(name) do
    act(fn space ->
      {:ok, page} = Space.create_page(space, name)
      Process.put(:names, Map.put(Process.get(:names), name, page["id"]))
      :ok
    end)
  end

  def ask(name, request) do
    act(fn space ->
      case PageAgent.ask(space, id(name), request, &nowhere/0) do
        {:ok, %{"threadId" => thread}} ->
          receive do
            {:launched, ^thread} -> :ok
          after
            5_000 -> flunk("the thread was never launched")
          end

          Process.put(
            :threads,
            Map.update(Process.get(:threads), name, [thread], &[thread | &1])
          )

          :ok

        {:error, reason, _} ->
          reason
      end
    end)
  end

  # An ask whose launch dies with the MC: no thread is ever written.
  def ask_lost(name) do
    act(fn space ->
      test = self()
      Application.put_env(:hal_c2, :page_agent_launch, &lost_launch(&1, test))

      reply =
        case PageAgent.ask(space, id(name), "tidy", &nowhere/0) do
          {:ok, %{"threadId" => thread}} ->
            receive do
              {:launched, ^thread} -> :ok
            after
              5_000 -> flunk("the launch never ran")
            end

            Process.put(
              :threads,
              Map.update(Process.get(:threads), name, [thread], &[thread | &1])
            )

            :ok

          {:error, reason, _} ->
            reason
        end

      Application.put_env(:hal_c2, :page_agent_launch, &fake_thread(&1, test))
      reply
    end)
  end

  def edit(name) do
    act(fn space ->
      author = Space.agent(thread(name))
      spec = %{"kind" => "paragraph", "text" => "edit"}
      {:ok, _} = Space.insert_block(space, id(name), spec, :last, author)
      :ok
    end)
  end

  def end_run(name, ended) do
    act(fn _space ->
      thread = thread(name)

      Streams.transact(thread, :thread, fn state ->
        run = StreamState.get(state, "run")[run_id(thread)]
        {[{"run", run["id"], Patch.diff(run, %{run | "status" => ended})}], :ok}
      end)

      PageAgent.report(thread)
    end)
  end

  # The run ends and nothing reports it.
  def lose_report(name, ended) do
    act(fn _space ->
      thread = thread(name)

      Streams.transact(thread, :thread, fn state ->
        run = StreamState.get(state, "run")[run_id(thread)]
        {[{"run", run["id"], Patch.diff(run, %{run | "status" => ended})}], :ok}
      end)
    end)
  end

  # The restart ended the run, and the continuation it promised does not start.
  def continuation_fails(name, how) do
    act(fn _space ->
      thread = thread(name)

      Streams.transact(thread, :thread, fn state ->
        run = StreamState.get(state, "run")[run_id(thread)]
        {[{"run", run["id"], Patch.diff(run, %{run | "status" => "interrupted"})}], :ok}
      end)

      # No clause of `dispatch/1` takes a command with no type, so it raises.
      {command, will_retry} =
        case how do
          :refused -> {%{"type" => "prop.unknown"}, true}
          :crashed -> {%{}, false}
          :crashed_again_later -> {%{}, true}
        end

      effect = %{
        "type" => "provider-runtime.continue",
        "threadId" => thread,
        "args" => %{"command" => command}
      }

      try do
        HalC2.Orchestration.execute_effect(effect, nil, will_retry)
      rescue
        FunctionClauseError -> :raised
      end

      :ok
    end)
  end

  # A message waiting for the user to resume the queue, behind whatever the thread did.
  def hold_message(name) do
    act(fn _space ->
      thread = thread(name)
      id = "held-" <> Integer.to_string(System.unique_integer([:positive]))

      run = %{
        "id" => id,
        "threadId" => thread,
        "ordinal" => 1_000_000,
        "status" => "queued",
        "queueHeld" => true,
        "createdAt" => HalC2.Orchestration.Entities.now()
      }

      Streams.transact(thread, :thread, fn _ -> {[{"run", id, Patch.diff(nil, run)}], :ok} end)
    end)
  end

  # A message queued behind the run and taken back: the highest ordinal, never started.
  def cancel_message(name) do
    act(fn _space ->
      thread = thread(name)
      id = "cancelled-" <> Integer.to_string(System.unique_integer([:positive]))

      run = %{
        "id" => id,
        "threadId" => thread,
        "ordinal" => 2_000_000,
        "status" => "cancelled",
        "queuePosition" => nil,
        "createdAt" => HalC2.Orchestration.Entities.now()
      }

      Streams.transact(thread, :thread, fn _ -> {[{"run", id, Patch.diff(nil, run)}], :ok} end)
    end)
  end

  # As `HalC2.Orchestration.Recovery` does to a run its provider never got.
  def requeue_run(name) do
    act(fn _space ->
      thread = thread(name)

      Streams.transact(thread, :thread, fn state ->
        run = StreamState.get(state, "run")[run_id(thread)]

        queued =
          Map.merge(run, %{"status" => "queued", "queuePosition" => 0, "queueHeld" => false})

        {[{"run", run["id"], Patch.diff(run, queued)}], :ok}
      end)
    end)
  end

  # A command still going, on the thread's run, as a dev server left behind is.
  def leave_background(name) do
    act(fn _space ->
      thread = thread(name)

      item = %{
        "id" => @background_item,
        "threadId" => thread,
        "runId" => run_id(thread),
        "ordinal" => 1_000,
        "type" => "command_execution",
        "status" => "running"
      }

      Streams.transact(thread, :thread, fn _ ->
        {[{"turn-item", @background_item, Patch.diff(nil, item)}], :ok}
      end)
    end)
  end

  def end_background(name) do
    act(fn _space ->
      thread = thread(name)

      Streams.transact(thread, :thread, fn state ->
        item = StreamState.get(state, "turn-item")[@background_item]

        {[{"turn-item", @background_item, Patch.diff(item, %{item | "status" => "completed"})}],
         :ok}
      end)

      PageAgent.report(thread)
    end)
  end

  def delete_thread(name) do
    act(fn _space ->
      change_thread(name, &Map.put(&1, "deletedAt", HalC2.Orchestration.Entities.now()))
      PageAgent.report(thread(name))
    end)
  end

  def begin_move(name) do
    act(fn _space ->
      change_thread(name, &Map.put(&1, "moving", %{"id" => "move", "label" => "desktop"}))
      PageAgent.report(thread(name))
    end)
  end

  def give_up_move(name) do
    act(fn _space ->
      change_thread(name, &Map.delete(&1, "moving"))
      PageAgent.report(thread(name))
    end)
  end

  # As the forwarding record: everything but the thread goes.
  def move_away(name) do
    act(fn _space ->
      thread = thread(name)

      Streams.transact(thread, :thread, fn state ->
        others =
          for {kind, id, _} <- StreamState.rows(state),
              {kind, id} != {"thread", thread},
              do: {kind, id, Patch.delete()}

        row = StreamState.get(state, "thread")[thread]

        moved =
          row
          |> Map.delete("moving")
          |> Map.put("movedTo", %{"label" => "desktop", "mc" => "desktop@host"})

        {others ++ [{"thread", thread, Patch.diff(row, moved)}], :ok}
      end)

      PageAgent.report(thread)
    end)
  end

  def reconcile, do: act(fn _ -> PageAgent.reconcile() end)
  def reconcile_continuing(name), do: act(fn _ -> PageAgent.reconcile([thread(name)]) end)

  def report_running(name), do: act(fn _ -> PageAgent.report(thread(name)) end)
  def report_old(name), do: act(fn _ -> PageAgent.report(List.last(threads(name))) end)

  def stop(name), do: act(fn space -> status(PageAgent.stop(space, id(name))) end)
  def dismiss(name), do: act(fn space -> status(PageAgent.dismiss(space, id(name))) end)
  def trash(name), do: act(fn space -> status(Space.trash_page(space, id(name))) end)
  def restore(name), do: act(fn space -> status(Space.restore_page(space, id(name))) end)

  def delete(name) do
    act(fn space ->
      reply = status(Space.delete_page(space, id(name)))

      if reply == :ok do
        Process.put(:names, Map.delete(Process.get(:names), name))
        Process.put(:threads, Map.delete(Process.get(:threads), name))
      end

      reply
    end)
  end

  def restart do
    act(fn _ -> HalC2.Prop.restart_service(HalC2.Streams) end)
  end

  # --- helpers --------------------------------------------------------------------

  # Runs `fun` and reports what it replied, the events it wrote and what the page says.
  defp act(fun) do
    space = Process.get(:space)
    stream = Space.stream_id(space)
    before = Streams.sequence(stream)
    reply = fun.(space)
    {reply, Streams.sequence(stream) - before, agents(stream)}
  end

  defp agents(stream) do
    names = Map.new(Process.get(:names), fn {name, id} -> {id, name} end)

    for agent <- StreamState.list(Streams.state(stream), "pageAgent"), into: %{} do
      {names[agent["pageId"]], {agent["status"], agent["edited"], agent["error"] != nil}}
    end
  end

  defp status({:ok, _}), do: :ok
  defp status({:error, reason, _}), do: reason

  defp id(name), do: Process.get(:names)[name]
  defp threads(name), do: Process.get(:threads)[name]
  defp thread(name), do: hd(threads(name))
  defp run_id(thread), do: "run-" <> thread

  defp change_thread(name, fun) do
    thread = thread(name)

    Streams.transact(thread, :thread, fn state ->
      row = StreamState.get(state, "thread")[thread]
      {[{"thread", thread, Patch.diff(row, fun.(row))}], :ok}
    end)
  end

  defp nowhere, do: {:ok, %{project_id: nil, model: nil, runtime_mode: nil}}

  defp lost_launch(input, test) do
    send(test, {:launched, input["threadId"]})
    {:ok, %{}}
  end

  # A launch that writes the thread with one run going, in place of a provider.
  defp fake_thread(input, test) do
    thread_id = input["threadId"]
    at = HalC2.Orchestration.Entities.now()

    thread = %{
      "id" => thread_id,
      "projectId" => input["projectId"],
      "spacePage" => input["spacePage"],
      "deletedAt" => nil
    }

    run = %{
      "id" => run_id(thread_id),
      "threadId" => thread_id,
      "ordinal" => 1,
      "status" => "running",
      "createdAt" => at
    }

    Streams.transact(thread_id, :thread, fn _ ->
      {[
         {"thread", thread_id, Patch.diff(nil, thread)},
         {"run", run["id"], Patch.diff(nil, run)}
       ], :ok}
    end)

    send(test, {:launched, thread_id})
    {:ok, %{"threadId" => thread_id}}
  end
end
