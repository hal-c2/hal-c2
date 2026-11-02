defmodule HalC2.SpaceSchedulePropTest do
  @moduledoc """
  One page's update (`HalC2.Space.Schedule` over `HalC2.ScheduledTasks`) against a model
  of the page, its task and the clock. The clock is the model's and ticks are sent by
  hand; a run goes to a fake standing in for the text generator, which writes, fails or
  crashes as its instruction says.

  The promises modelled: what the user wrote keeps its text and order whatever runs do;
  a page has at most one generated part, a run replaces its text where it stands and
  brings it back if it was deleted, and the user cannot edit it; a run that fails or
  crashes changes no block and no `writtenAt`; a page in the trash has no next run,
  refuses changes and runs, does not run when due, and on restore aims its next run
  afresh instead of running what it missed; a paused page never runs when due but can be
  run by hand; removing the update leaves what it wrote as an ordinary block; a site shows
  a run's text as that ordinary block, so removing the update does not put it behind; the
  page's `schedule` field shows the task after every command, including across restarts
  of the scheduler; and a page's task never appears among the listed tasks.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{ScheduledTasks, Space}
  alias HalC2.Space.{Blocks, Pages, Schedule, Sites}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @min_interval 60_000
  @start ~U[2026-06-01 00:00:00.000Z]
  @clock {__MODULE__, :clock}
  @writes {__MODULE__, :writes}

  property "a page's update follows the model and leaves the user's blocks alone",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
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
    home = HalC2.Prop.scratch_home("space-schedule")
    :persistent_term.put(@clock, DateTime.to_unix(@start, :millisecond))
    :persistent_term.put(@writes, :counters.new(1, []))

    Application.put_env(:hal_c2, :scheduled_tasks_clock, fn ->
      DateTime.from_unix!(:persistent_term.get(@clock), :millisecond)
    end)

    Application.put_env(:hal_c2, :scheduled_tasks_run_timeout_ms, 5_000)
    Application.put_env(:hal_c2, :scheduled_tasks_fire, &fire/2)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      ScheduledTasks
    ])

    {:ok, space} = Space.create("Prop")
    {:ok, page} = Space.create_page(space["id"], "Status")
    Process.put(:space, space["id"])
    Process.put(:page, page["id"])
    Process.put(:names, %{})
    {:ok, _} = ScheduledTasks.subscribe(self())
  end

  defp teardown do
    HalC2.Prop.stop_services()
    :persistent_term.erase(@clock)
    :persistent_term.erase(@writes)
    Application.delete_env(:hal_c2, :scheduled_tasks_clock)
    Application.delete_env(:hal_c2, :scheduled_tasks_fire)
    Application.delete_env(:hal_c2, :scheduled_tasks_run_timeout_ms)
  end

  # The generator: the instruction says how the run ends. Each write says a new thing.
  defp fire(%{"prompt" => prompt, "page" => page}, _key) do
    case prompt do
      "write" ->
        writes = :persistent_term.get(@writes)
        :counters.add(writes, 1, 1)
        text = "Result #{:counters.get(writes, 1)}"
        Schedule.write(page["spaceId"], page["pageId"], text)

      "fail" ->
        {:error, "no"}

      "crash" ->
        exit(:crashed)
    end
  end

  # --- model ------------------------------------------------------------------

  # blocks: the page in order, each {:hand, name, text}, {:kept, text} (written by an
  # update since removed), or :generated, whose text is generated. task: nil or
  # %{prompt, every, enabled, next (ms or nil), status}. writes counts the writes so
  # far, which name the fake's text. site: nil or what `published/1` said at publishing.
  def initial_state do
    %{
      now: DateTime.to_unix(@start, :millisecond),
      trashed: false,
      blocks: [],
      generated: nil,
      written: false,
      task: nil,
      writes: 0,
      site: nil
    }
  end

  def command(s) do
    hand = for {:hand, name, _} <- s.blocks, do: name

    frequency(
      [
        {4, {:call, __MODULE__, :set, [prompt(), every()]}},
        {3, {:call, __MODULE__, :set_enabled, [boolean()]}},
        {5, {:call, __MODULE__, :run_now, []}},
        {1, {:call, __MODULE__, :remove, []}},
        {6, {:call, __MODULE__, :advance, [delta(s)]}},
        {2, {:call, __MODULE__, :restart_after, [oneof([0, 5_000, 7_200_000])]}},
        {2, {:call, __MODULE__, :trash, []}},
        {3, {:call, __MODULE__, :restore, []}},
        {2, {:call, __MODULE__, :add_block, [elements(~w(h1 h2 h3))]}},
        {2, {:call, __MODULE__, :edit_generated, []}},
        {1, {:call, __MODULE__, :delete_generated, []}},
        {1, {:call, __MODULE__, :move_generated_first, []}},
        {2, {:call, __MODULE__, :publish, []}}
      ] ++ if(hand == [], do: [], else: [{2, {:call, __MODULE__, :edit_block, [elements(hand)]}}])
    )
  end

  defp prompt, do: frequency([{6, "write"}, {2, "fail"}, {1, "crash"}])
  defp every, do: frequency([{4, oneof([60_000, 3_600_000])}, {1, 59_999}])

  defp delta(%{task: %{enabled: true, next: next}, now: now}) when next != nil,
    do: frequency([{3, max(next - now, 1)}, {2, oneof([1_000, 61_000, 3_600_000])}])

  defp delta(_s), do: oneof([1_000, 61_000, 3_600_000])

  def precondition(s, {:call, _, :trash, []}), do: not s.trashed
  def precondition(s, {:call, _, :restore, []}), do: s.trashed

  def precondition(s, {:call, _, :add_block, [name]}),
    do: not Enum.any?(s.blocks, &match?({:hand, ^name, _}, &1))

  def precondition(s, {:call, _, :edit_block, [name]}),
    do: Enum.any?(s.blocks, &match?({:hand, ^name, _}, &1))

  def precondition(s, {:call, _, cmd, []})
      when cmd in [:edit_generated, :delete_generated, :move_generated_first],
      do: :generated in s.blocks

  def precondition(_s, _call), do: true

  def next_state(s, _result, {:call, _, cmd, args}), do: elem(step(s, cmd, args), 1)

  def postcondition(s, {:call, _, cmd, args}, {reply, seen, listed}) do
    {expected, after_step} = step(s, cmd, args)
    reply == expected and seen == view(after_step) and listed == []
  end

  # Each command's outcome (:ok or :error) and the model after it.
  defp step(s, :set, [prompt, every]) do
    cond do
      s.trashed or every < @min_interval ->
        {:error, s}

      true ->
        task = s.task
        enabled = if task, do: task.enabled, else: true

        next =
          cond do
            not enabled -> nil
            task && task.every == every && task.next -> task.next
            true -> s.now + every
          end

        status = if task, do: task.status, else: "never"

        {:ok,
         %{
           s
           | task: %{prompt: prompt, every: every, enabled: enabled, next: next, status: status}
         }}
    end
  end

  defp step(%{task: task} = s, :set_enabled, [enabled]) do
    if s.trashed or task == nil do
      {:error, s}
    else
      next =
        cond do
          not enabled -> nil
          task.enabled and task.next -> task.next
          true -> s.now + task.every
        end

      {:ok, %{s | task: %{task | enabled: enabled, next: next}}}
    end
  end

  defp step(s, :run_now, []) do
    if s.trashed or s.task == nil, do: {:error, s}, else: {:ok, ran(s)}
  end

  defp step(s, :remove, []) do
    if s.trashed or s.task == nil do
      {:error, s}
    else
      blocks =
        Enum.map(s.blocks, fn
          :generated -> {:kept, s.generated}
          block -> block
        end)

      {:ok, %{s | task: nil, blocks: blocks, generated: nil, written: false}}
    end
  end

  defp step(s, :advance, [delta]), do: {:ok, due(%{s | now: s.now + delta})}
  defp step(s, :restart_after, [delta]), do: {:ok, due(%{s | now: s.now + delta})}

  defp step(s, :trash, []) do
    {:ok, %{s | trashed: true, task: s.task && %{s.task | next: nil}, site: nil}}
  end

  # What it missed does not run: its next run is aimed from now.
  defp step(s, :restore, []) do
    task = s.task && %{s.task | next: if(s.task.enabled, do: s.now + s.task.every)}
    {:ok, %{s | trashed: false, task: task}}
  end

  defp step(s, :add_block, [name]) do
    if s.trashed, do: {:error, s}, else: {:ok, %{s | blocks: s.blocks ++ [{:hand, name, name}]}}
  end

  defp step(s, :edit_block, [name]) do
    if s.trashed do
      {:error, s}
    else
      blocks =
        Enum.map(s.blocks, fn
          {:hand, ^name, text} -> {:hand, name, text <> "+"}
          block -> block
        end)

      {:ok, %{s | blocks: blocks}}
    end
  end

  defp step(s, :edit_generated, []), do: {:error, s}

  defp step(s, :delete_generated, []) do
    if s.trashed, do: {:error, s}, else: {:ok, %{s | blocks: s.blocks -- [:generated]}}
  end

  defp step(s, :move_generated_first, []) do
    if s.trashed,
      do: {:error, s},
      else: {:ok, %{s | blocks: [:generated | s.blocks -- [:generated]]}}
  end

  defp step(s, :publish, []) do
    if s.trashed, do: {:error, s}, else: {:ok, %{s | site: published(s)}}
  end

  defp due(%{task: %{enabled: true, next: next}, trashed: false, now: now} = s)
       when next != nil and next <= now do
    s = ran(s)
    %{s | task: %{s.task | next: now + s.task.every}}
  end

  defp due(s), do: s

  defp ran(%{task: %{prompt: "write"} = task} = s) do
    writes = s.writes + 1
    blocks = if :generated in s.blocks, do: s.blocks, else: s.blocks ++ [:generated]

    %{
      s
      | writes: writes,
        generated: "Result #{writes}",
        blocks: blocks,
        written: true,
        task: %{task | status: "succeeded"}
    }
  end

  defp ran(%{task: task} = s), do: %{s | task: %{task | status: "failed"}}

  # What a client reads from the Space's stream.
  defp view(s) do
    blocks =
      Enum.map(s.blocks, fn
        {:hand, _name, text} -> {"paragraph", text}
        {:kept, text} -> {"paragraph", text}
        :generated -> {"generated", s.generated}
      end)

    task =
      s.task &&
        {s.task.prompt, s.task.every, s.task.enabled, s.task.next && iso(s.task.next),
         s.task.status}

    site = s.site && {s.site, s.site != published(s)}

    {s.trashed, s.written, task, blocks, site}
  end

  # What publishing now would show.
  defp published(s) do
    Enum.map(s.blocks, fn
      {:hand, _name, text} -> {"paragraph", text}
      {:kept, text} -> {"paragraph", text}
      :generated -> {"paragraph", s.generated}
    end)
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # --- system under test --------------------------------------------------------

  def set(prompt, every) do
    cadence = %{"type" => "interval", "everyMs" => every}
    act(fn -> Schedule.set(space(), page(), prompt, cadence) end)
  end

  def set_enabled(enabled), do: act(fn -> Schedule.set_enabled(space(), page(), enabled) end)
  def run_now, do: act(fn -> Schedule.run_now(space(), page()) end)
  def remove, do: act(fn -> Schedule.remove(space(), page()) end)

  def advance(delta) do
    act(fn ->
      :persistent_term.put(@clock, :persistent_term.get(@clock) + delta)
      send(ScheduledTasks, :tick)
      {:ok, nil}
    end)
  end

  # The scheduler stops, the clock moves while it is down, and it starts again.
  def restart_after(delta) do
    act(fn ->
      sup = Process.get({HalC2.Prop, :services})
      :ok = Supervisor.terminate_child(sup, ScheduledTasks)
      :persistent_term.put(@clock, :persistent_term.get(@clock) + delta)
      {:ok, _} = Supervisor.restart_child(sup, ScheduledTasks)
      {:ok, _} = ScheduledTasks.subscribe(self())
      send(ScheduledTasks, :tick)
      {:ok, nil}
    end)
  end

  def trash, do: act(fn -> Space.trash_page(space(), page()) end)
  def restore, do: act(fn -> Space.restore_page(space(), page()) end)

  def add_block(name) do
    act(fn ->
      with {:ok, block} <-
             Space.insert_block(space(), page(), %{"kind" => "paragraph", "text" => name}) do
        Process.put(:names, Map.put(Process.get(:names), name, block["id"]))
        {:ok, block}
      end
    end)
  end

  def edit_block(name) do
    act(fn ->
      id = Map.fetch!(Process.get(:names), name)
      block = Enum.find(blocks(), &(&1["id"] == id))
      Space.update_block(space(), id, block["text"] <> "+")
    end)
  end

  def edit_generated do
    act(fn -> Space.update_block(space(), generated_id(), "By hand") end)
  end

  def delete_generated, do: act(fn -> Space.delete_block(space(), generated_id()) end)
  def move_generated_first, do: act(fn -> Space.move_block(space(), generated_id(), nil) end)

  def publish do
    act(fn -> Space.publish_page(space(), page(), %{"baseUrl" => "http://mc.test:1"}) end)
  end

  # Runs one command, waits for any run it started, and reads the page back.
  defp act(fun) do
    flush()
    reply = fun.()
    :sys.get_state(ScheduledTasks)
    settle()
    {:ok, %{"tasks" => listed}} = ScheduledTasks.list()
    {elem(reply, 0), seen(), listed}
  end

  defp seen do
    {:ok, state} = Space.state(space())
    page = Pages.get(state, page())
    blocks = for block <- Blocks.of_page(state, page()), do: {block["kind"], block["text"]}

    task =
      case page["schedule"] do
        nil ->
          nil

        shown ->
          {shown["instruction"], shown["cadence"]["everyMs"], shown["enabled"],
           shown["nextRunAt"], shown["lastRunStatus"]}
      end

    site =
      case Sites.of_page(state, page()) do
        nil -> nil
        site -> {for(b <- site["snapshot"]["blocks"], do: {b["kind"], b["text"]}), site["behind"]}
      end

    {page["trashedAt"] != nil, page["writtenAt"] != nil, task, blocks, site}
  end

  defp blocks do
    {:ok, state} = Space.state(space())
    Blocks.of_page(state, page())
  end

  defp generated_id, do: Enum.find(blocks(), &(&1["kind"] == "generated"))["id"]
  defp space, do: Process.get(:space)
  defp page, do: Process.get(:page)

  # Waits, on the scheduler's own notifications, until no run is in flight.
  defp settle do
    if Enum.any?(ScheduledTasks.page_tasks(), &(&1["lastRunStatus"] == "running")) do
      receive do
        {:hal_c2_scheduled_tasks, _node, _tasks} -> settle()
      after
        10_000 -> :timeout
      end
    else
      :ok
    end
  end

  defp flush do
    receive do
      {:hal_c2_scheduled_tasks, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
