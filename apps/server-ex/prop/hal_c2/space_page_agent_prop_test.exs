defmodule HalC2.SpacePageAgentPropTest do
  @moduledoc """
  A state machine over the agents asked from the pages of one Space
  (`HalC2.Space.PageAgent`): asks, valid and blank; edits by the agent; runs ending as
  completed, failed or interrupted; stops; dismissals; a page trashed, restored and
  deleted for good; reports from a thread an earlier ask started; and the streams
  restarting. The thread is a fake one written straight to its stream, so no provider
  is needed; what a run ended as is what the entity reads.

  After each command the test reads the Space's stream back and checks it against the
  model:

  - a page has at most one agent, and an ask while it is at work is refused and writes
    nothing, as is one on a page in the trash;
  - an agent ends only by its own thread ending or a stop: a report from a thread an
    earlier ask started, or one with its run still going, writes nothing;
  - an agent ended says what its run ended as, and whether its thread edited the page;
  - a stop marks an agent stopping, whatever its run then ends as it says stopped, and
    a page with none refuses; on one that has ended it changes nothing;
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
  # wrote}: it wrote as it edits, and says edited once it ends. asks counts this page's
  # threads, so a report can name an old one.
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
        [{1, {:call, __MODULE__, :restart, []}}]
    )
  end

  def precondition(s, {:call, _, :create_page, [name]}), do: not Map.has_key?(s.pages, name)
  def precondition(_s, {:call, _, :restart, []}), do: true

  def precondition(s, {:call, _, :edit, [name]}),
    do: active?(s, name) and not s.pages[name].trashed

  def precondition(s, {:call, _, cmd, [name | _]}) when cmd in [:end_run, :report_running],
    do: active?(s, name)

  def precondition(s, {:call, _, :report_old, [name]}),
    do: Map.has_key?(s.pages, name) and s.pages[name].asks > 1

  def precondition(s, {:call, _, _, [name | _]}), do: Map.has_key?(s.pages, name)

  defp active?(s, name),
    do: match?(%{agent: %{status: status}} when status in @active, s.pages[name])

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
      true -> {:ok, put(s, name, %{page | asks: page.asks + 1, agent: agent()}), 1}
    end
  end

  defp step(s, :edit, [name]) do
    page = s.pages[name]

    {:ok, put(s, name, %{page | blocks: page.blocks + 1, agent: %{page.agent | wrote: true}}),
     nil}
  end

  defp step(s, :end_run, [name, ended]) do
    page = s.pages[name]
    agent = page.agent
    status = if agent.status == "stopping", do: "stopped", else: @ended[ended]
    {:ok, put(s, name, %{page | agent: %{agent | status: status, edited: agent.wrote}}), 1}
  end

  defp step(s, :report_running, _), do: {:ok, s, 0}
  defp step(s, :report_old, _), do: {:ok, s, 0}

  # A fake run goes on until `end_run` ends it, as one a provider is slow to stop would.
  defp step(s, :stop, [name]) do
    case s.pages[name] do
      %{agent: nil} ->
        {:not_found, s, 0}

      %{agent: %{status: "running"} = agent} = page ->
        {:ok, put(s, name, %{page | agent: %{agent | status: "stopping"}}), 1}

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

  defp agent, do: %{status: "running", edited: false, wrote: false}
  defp put(s, name, page), do: %{s | pages: Map.put(s.pages, name, page)}

  defp snapshot(s) do
    for {name, %{agent: %{} = agent}} <- s.pages,
        into: %{},
        do: {name, {agent.status, agent.edited}}
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
      {names[agent["pageId"]], {agent["status"], agent["edited"]}}
    end
  end

  defp status({:ok, _}), do: :ok
  defp status({:error, reason, _}), do: reason

  defp id(name), do: Process.get(:names)[name]
  defp threads(name), do: Process.get(:threads)[name]
  defp thread(name), do: hd(threads(name))
  defp run_id(thread), do: "run-" <> thread

  defp nowhere, do: {:ok, %{project_id: nil, model: nil, runtime_mode: nil}}

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
