defmodule HalC2.Projection.BackgroundWork do
  @moduledoc """
  Work that outlives a thread's settled turn.

  Tasks come from the provider thread roster (Claude background tasks) and from
  still-active command, dynamic tool and subagent turn items, deduplicated by native
  task id. Nothing is pending while a foreground run is active or the latest run has
  not settled; a rolled-back latest run abandons everything.

  `derive/1` is everything still running, which keeps the provider process and the
  thread's files alive. Only some of it holds the thread Working (the sidebar's
  Waiting pill, settlement, a delegated task's end): `holding/1`. A command or a
  monitor is as often a dev server or its watchdog as a wait, and only the agent
  knows which, so one holds only when the agent marked it as work it waits on
  (`"awaited"`, `hal_c2_background_wait`); subagents and other tasks always hold.
  """

  import HalC2.Projection.JS, only: [get: 2, json: 1, trim: 1]

  @background_types ~w(command_execution dynamic_tool subagent)
  @active_statuses ~w(pending running waiting)
  @interruptible ~w(preparing starting running)
  # `waiting` is a successful turn before checkpoint capture; `rolled_back` is not settled.
  @settled ~w(cancelled completed failed interrupted waiting)
  # Commands and monitors, as items and as roster task types: they hold only when awaited.
  @unless_awaited ~w(command_execution dynamic_tool local_bash monitor command)

  @type task :: %{required(String.t()) => String.t()}

  @doc """
  Options: `:latest_run`, `:provider_threads`, `:turn_items`, and optionally
  `:active_provider_thread_id` (only that thread's roster counts), `:runs` (to drop
  items of rolled-back runs and detect an active run) and `:has_active_run`.
  """
  @spec derive(keyword) :: [task]
  def derive(opts) do
    runs = Keyword.get(opts, :runs)

    has_active_run =
      Keyword.get_lazy(opts, :has_active_run, fn ->
        Enum.any?(runs || [], &(get(&1, "status") in @interruptible))
      end)

    latest_run = Keyword.get(opts, :latest_run)

    if has_active_run or latest_run == nil or get(latest_run, "status") not in @settled do
      []
    else
      rolled_back =
        for run <- runs || [],
            get(run, "status") == "rolled_back",
            into: MapSet.new(),
            do: get(run, "id")

      provider_threads =
        case Keyword.get(opts, :active_provider_thread_id) do
          nil -> Keyword.fetch!(opts, :provider_threads)
          id -> Enum.filter(Keyword.fetch!(opts, :provider_threads), &(get(&1, "id") == id))
        end

      roster =
        for thread <- provider_threads,
            task <- get(thread, "pendingBackgroundTasks") || [],
            get(task, "taskId") != "",
            do: roster_task(task)

      items =
        for item <- Keyword.fetch!(opts, :turn_items),
            pending_item?(item, rolled_back),
            do: item_task(item)

      Enum.uniq_by(roster ++ items, & &1["taskId"])
    end
  end

  @doc "The tasks of `derive/1` that hold the thread Working."
  @spec holding([task]) :: [task]
  def holding(tasks), do: Enum.filter(tasks, &holds?/1)

  defp holds?(task),
    do: task["awaited"] == true or task["taskType"] not in @unless_awaited

  defp roster_task(task) do
    description = if d = get(task, "description"), do: trim(d)

    Map.take(task, ["taskId", "taskType"])
    |> json()
    |> put_present("description", if(description != "", do: description))
    |> put_present("awaited", if(get(task, "awaited") == true, do: true))
  end

  defp pending_item?(item, rolled_back) do
    get(item, "type") in @background_types and get(item, "status") in @active_statuses and
      not persistent_monitor?(item) and
      not (get(item, "runId") != nil and MapSet.member?(rolled_back, get(item, "runId")))
  end

  # Grok monitors run for the life of the session and never finish.
  defp persistent_monitor?(item),
    do:
      get(item, "type") == "dynamic_tool" and match?(%{"persistent" => true}, get(item, "input"))

  defp item_task(item) do
    %{"taskId" => native_task_id(item), "taskType" => get(item, "type")}
    |> put_present("description", description(item))
    |> put_present("awaited", if(get(item, "awaited") == true, do: true))
  end

  defp native_task_id(item) do
    case get(get(item, "nativeItemRef"), "nativeId") do
      id when is_binary(id) and id != "" -> id
      _ -> get(item, "id")
    end
  end

  defp description(item) do
    type = get(item, "type")

    cond do
      non_blank(get(item, "title")) ->
        non_blank(get(item, "title"))

      type == "command_execution" and is_binary(get(item, "input")) ->
        non_blank(get(item, "input"))

      type == "dynamic_tool" and non_blank(get(item, "toolName")) ->
        non_blank(get(item, "toolName"))

      type == "subagent" and is_binary(get(item, "prompt")) ->
        non_blank(get(item, "prompt"))

      true ->
        nil
    end
  end

  defp non_blank(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_blank(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
