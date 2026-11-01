defmodule HalC2.SpaceScheduleStallPropTest do
  @moduledoc """
  Page tasks in two Spaces against a model of each page and its task, with a Space's
  stream that may not answer while the scheduler reconciles it or boots. The promises
  modelled: a task is held exactly when the scheduler last read its page in the trash, a
  held task has no next run, a reconcile of one Space leaves the other's debt alone, a
  stream that does not answer holds up only its own Space and is not waited on again by
  a later change, and once the streams answer one tick settles every task and shows it on
  its page, whatever went unanswered before.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{ScheduledTasks, Space, Streams}
  alias HalC2.Space.{Pages, Schedule}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @cadence %{"type" => "interval", "everyMs" => 7_200_000}

  property "every task settles on its page's fate once the streams answer",
    numtests: HalC2.Prop.numtests(25),
    max_size: 15 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp setup do
    home = HalC2.Prop.scratch_home("space-schedule-stall")
    # Long enough that a stream that answers is not taken for one that does not.
    Application.put_env(:hal_c2, :scheduled_tasks_pages_timeout_ms, 1_000)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      ScheduledTasks
    ])

    pages =
      for index <- 0..1, into: %{} do
        {:ok, space} = Space.create("Prop #{index}")
        {:ok, page} = Space.create_page(space["id"], "Status")
        {:ok, _} = Schedule.set(space["id"], page["id"], "Summarise", @cadence)
        {index, {space["id"], page["id"]}}
      end

    Process.put(:pages, pages)
  end

  defp teardown do
    HalC2.Prop.stop_services()
    Application.delete_env(:hal_c2, :scheduled_tasks_pages_timeout_ms)
  end

  # --- model ------------------------------------------------------------------

  # By Space: whether its page is in the trash, and whether its task is held.
  def initial_state, do: Map.new(0..1, &{&1, %{trashed: false, held: false}})

  def command(s) do
    index = oneof([0, 1])

    frequency([
      {4, let(i <- index, do: {:call, __MODULE__, :flip, [i, s[i].trashed, boolean()]})},
      {2, {:call, __MODULE__, :reconcile, [index]}},
      {2, {:call, __MODULE__, :restart_stalled, [index]}},
      {2, {:call, __MODULE__, :tick_stalled, [index]}},
      {2, {:call, __MODULE__, :edit_stalled, [index]}},
      {2, {:call, __MODULE__, :edit_beside_stalled, [index]}},
      {3, {:call, __MODULE__, :tick, []}}
    ])
  end

  def precondition(s, {:call, _, :flip, [i, trashed, _answered]}), do: s[i].trashed == trashed
  def precondition(s, {:call, _, :edit_stalled, [i]}), do: not s[i].held
  def precondition(_s, _call), do: true

  def next_state(s, _result, {:call, _, name, args}), do: step(s, name, args)

  def postcondition(s, {:call, _, name, args}, observed), do: observed == step(s, name, args)

  defp step(s, :flip, [i, _trashed, answered]) do
    trashed = not s[i].trashed
    held = if answered, do: trashed, else: s[i].held
    Map.put(s, i, %{trashed: trashed, held: held})
  end

  defp step(s, :reconcile, [i]), do: Map.put(s, i, %{s[i] | held: s[i].trashed})
  defp step(s, :restart_stalled, [i]), do: settled(s, i)
  defp step(s, :tick_stalled, [i]), do: settled(s, i)
  defp step(s, :edit_stalled, [_i]), do: s
  defp step(s, :edit_beside_stalled, [_i]), do: s
  defp step(s, :tick, []), do: settled(s, nil)

  # Every Space whose stream answers holds its page's fate; the `stalled` one keeps its own.
  defp settled(s, stalled) do
    Map.new(s, fn
      {^stalled, page} -> {stalled, page}
      {i, page} -> {i, %{page | held: page.trashed}}
    end)
  end

  # --- commands -----------------------------------------------------------------

  # A trash or restore commits, and only then does its reconcile meet the stream.
  def flip(i, trashed, answered) do
    {space, page} = page(i)
    decide = if trashed, do: &Pages.restore(&1, page), else: &Pages.trash(&1, page)
    {:ok, _} = Space.transact(space, decide)

    if answered,
      do: :ok = ScheduledTasks.reconcile_pages(space),
      else: stalled(i, fn -> :ok = ScheduledTasks.reconcile_pages(space) end)

    observed()
  end

  def reconcile(i) do
    {space, _page} = page(i)
    :ok = ScheduledTasks.reconcile_pages(space)
    observed()
  end

  def restart_stalled(i) do
    stalled(i, fn ->
      HalC2.Prop.restart_service(ScheduledTasks)
      # Past the boot's reconcile, before the stream answers again.
      :sys.get_state(ScheduledTasks, 10_000)
    end)

    observed()
  end

  def tick_stalled(i) do
    stalled(i, fn ->
      send(ScheduledTasks, :tick)
      :sys.get_state(ScheduledTasks, 10_000)
    end)

    observed()
  end

  # A change the stream cannot show, and it stops before reading the write: the task has
  # the change, its page does not, and nothing but a tick will bring it.
  def edit_stalled(i) do
    {space, page} = page(i)
    stream = Streams.ensure(Space.stream_id(space))
    :sys.suspend(stream)

    {:ok, _} = ScheduledTasks.put_page_task(page_task(space, page))

    ref = Process.monitor(stream)
    Process.exit(stream, :kill)

    receive do
      {:DOWN, ^ref, :process, _, :killed} -> observed()
    end
  end

  # A change in the Space beside a stopped stream that has already been waited on. The
  # limit outlasts the call, so waiting on that stream again would raise here.
  def edit_beside_stalled(i) do
    {space, page} = page(i)
    other = 1 - i
    {other_space, other_page} = page(other)

    stalled(i, fn ->
      {:ok, _} = ScheduledTasks.put_page_task(page_task(space, page))
      Application.put_env(:hal_c2, :scheduled_tasks_pages_timeout_ms, 60_000)
      {:ok, _} = ScheduledTasks.put_page_task(page_task(other_space, other_page))
      Application.put_env(:hal_c2, :scheduled_tasks_pages_timeout_ms, 1_000)
      true = shown?(other)
    end)

    observed()
  end

  def tick do
    send(ScheduledTasks, :tick)
    observed = observed()
    true = Enum.all?(Map.keys(observed), &shown?/1)
    observed
  end

  defp stalled(i, fun) do
    {space, _page} = page(i)
    stream = Streams.ensure(Space.stream_id(space))
    :sys.suspend(stream)
    fun.()
    :sys.resume(stream)
  end

  defp page(i), do: Process.get(:pages)[i]

  # Each says something new, so its page has something new to show.
  defp page_task(space, page) do
    %{
      "id" => "page:" <> page,
      "title" => "Page update",
      "page" => %{"spaceId" => space, "pageId" => page},
      "prompt" => "Summarise #{System.unique_integer([:positive])}",
      "schedule" => @cadence
    }
  end

  # What the Space and the scheduler hold, in the model's terms. A held task with a next
  # run, or a free one without, raises here.
  defp observed do
    tasks = ScheduledTasks.page_tasks()

    for {i, {_space, page}} <- Process.get(:pages), into: %{} do
      task = Enum.find(tasks, &(&1["page"]["pageId"] == page))
      held = task["held"] == true
      true = held == is_nil(task["nextRunAt"])
      {i, %{trashed: trashed?(i), held: held}}
    end
  end

  # Whether the page shows its task as the scheduler holds it.
  defp shown?(i) do
    {space, page} = page(i)
    {:ok, state} = Space.state(space)
    task = Enum.find(ScheduledTasks.page_tasks(), &(&1["page"]["pageId"] == page))
    Pages.get(state, page)["schedule"] == Schedule.view(task)
  end

  defp trashed?(i) do
    {space, page} = page(i)
    {:ok, state} = Space.state(space)
    not Pages.live?(state, Pages.get(state, page))
  end
end
