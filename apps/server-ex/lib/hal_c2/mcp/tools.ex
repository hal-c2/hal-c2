defmodule HalC2.Mcp.Tools do
  @moduledoc """
  The tools of the `hal-c2` MCP server (`HalC2.Mcp`), each acting as the thread whose
  agent called it. Definitions come from `priv/mcp_tools.json`; only the tools
  implemented here and in the area modules (`HalC2.Mcp.Tools.Threads`, `Queue`,
  `Projects` and `PullRequests`), which share the access helpers below, are advertised.

  The access rules follow the Node server's: a caller sees only threads of its own
  project; changing another thread needs a caller that is itself running, and never
  gives the target broader runtime or interaction modes than the caller has.
  """

  alias HalC2.{Orchestration, StreamState}

  @implemented ~w(halc2_thread_list halc2_thread_read halc2_thread_send halc2_thread_wait halc2_thread_interrupt
                  halc2_thread_search halc2_environment_read halc2_environment_preferences_update
                  halc2_project_list halc2_project_read list_scheduled_tasks schedule_task
                  update_scheduled_task delete_scheduled_task run_scheduled_task_now
                  halc2_preview_list halc2_preview_close)

  @areas [
    HalC2.Mcp.Tools.Threads,
    HalC2.Mcp.Tools.Queue,
    HalC2.Mcp.Tools.Projects,
    HalC2.Mcp.Tools.PullRequests
  ]

  @delegation ~w(delegate_task task_status task_cancel)
  @preview HalC2.Mcp.Preview.names()
  @devices HalC2.Mcp.Devices.names()

  @runtime_ranks %{
    "approval-required" => 0,
    "auto-accept-edits" => 1,
    "auto" => 2,
    "full-access" => 3
  }
  @finished ~w(completed failed interrupted cancelled rolled_back)

  @doc "The advertised tools (MCP `tools/list`)."
  def list do
    names =
      @implemented ++ @delegation ++ @preview ++ @devices ++ Enum.flat_map(@areas, & &1.tools())

    for tool <- definitions(), tool["name"] in names do
      Map.take(tool, ["name", "description", "inputSchema"])
    end
  end

  defp definitions do
    case :persistent_term.get({__MODULE__, :definitions}, nil) do
      nil ->
        tools =
          Application.app_dir(:hal_c2, "priv/mcp_tools.json") |> File.read!() |> JSON.decode!()

        :persistent_term.put({__MODULE__, :definitions}, tools)
        tools

      tools ->
        tools
    end
  end

  @doc "Runs a tool: `{:ok, result}` or `{:error, code, message}` (`OrchestratorMcpFailure`)."
  # Delegated tasks belong to their caller thread (`HalC2.Orchestration.Delegation`).
  def call("delegate_task", args, caller) do
    with {:ok, me} <- caller_row(caller),
         do: HalC2.Orchestration.Delegation.delegate(me, caller.instance, args)
  end

  def call("task_status", %{"taskId" => id}, caller),
    do: HalC2.Orchestration.Delegation.task_status(caller.thread_id, id)

  def call("task_cancel", %{"taskId" => id}, caller),
    do: HalC2.Orchestration.Delegation.cancel(caller.thread_id, id)

  def call(name, args, caller) when name in @preview,
    do: HalC2.Mcp.Preview.call(name, args, caller)

  def call(name, args, caller) when name in @devices,
    do: HalC2.Mcp.Devices.call(name, args, caller)

  def call(name, args, caller) do
    area = if name in @implemented, do: __MODULE__, else: Enum.find(@areas, &(name in &1.tools()))

    if area do
      with {:ok, me} <- caller_row(caller), do: area.run(name, args, Map.put(caller, :row, me))
    else
      {:error, "capability_denied", "#{name} is not available on this node."}
    end
  end

  # --- threads ---------------------------------------------------------------------

  @doc """
  How long `halc2_thread_wait` waits for a requested `timeoutMs`: 10 minutes when none
  is given, at least 1 millisecond and at most 1 hour.
  """
  def wait_timeout(requested), do: min(max(parse_number(requested, 600_000), 1), 3_600_000)

  @doc false
  def run(name, args, caller)

  def run("halc2_thread_list", args, %{row: me}) do
    statuses = args["statuses"]
    title = args["titleContains"] && String.downcase(args["titleContains"])

    threads =
      project_threads(me["projectId"])
      |> Enum.filter(
        &(statuses in [nil, []] or (&1["activityRunStatus"] || &1["status"]) in statuses)
      )
      |> Enum.filter(
        &(title == nil or String.contains?(String.downcase(&1["title"] || ""), title))
      )
      |> Enum.filter(
        &(args["includeSubagents"] != false or
            get_in(&1, ["lineage", "relationshipToParent"]) != "subagent")
      )

    cursor = args["cursor"] || 0
    page = Enum.slice(threads, cursor, args["limit"] || 50)

    {:ok,
     %{
       "projectId" => me["projectId"],
       "currentThreadId" => me["id"],
       "threads" => Enum.map(page, &list_item/1),
       "nextCursor" => if(cursor + length(page) < length(threads), do: cursor + length(page)),
       "total" => length(threads)
     }}
  end

  def run("halc2_thread_read", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      state = stream(row["id"])
      view = args["view"] || "messages"
      after_position = args["afterPosition"] || -1
      limit = args["limit"] || 50
      max_chars = args["maxCharsPerItem"] || 20_000
      messages = StreamState.get(state, "message")

      items =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(
          &(view == "activity" or &1["type"] in ["user_message", "assistant_message"])
        )
        |> Enum.filter(&(args["itemId"] == nil or &1["id"] == args["itemId"]))
        |> Enum.with_index()

      page =
        items
        |> Enum.filter(fn {_, position} -> position > after_position end)
        |> Enum.take(limit)

      {:ok,
       %{
         "thread" => Map.put(list_item(row), "totalItems", length(items)),
         "recentRuns" =>
           state
           |> StreamState.list("run")
           |> Enum.sort_by(& &1["ordinal"], :desc)
           |> Enum.take(args["runLimit"] || 10)
           |> Enum.map(&run_summary/1),
         "items" =>
           Enum.map(page, fn {item, position} ->
             timeline_item(item, position, messages, max_chars, args["textOffset"] || 0)
           end),
         "nextPosition" =>
           case List.last(page) do
             {_, position} -> position
             nil -> nil
           end,
         "hasMore" => length(items) > after_position + 1 + length(page)
       }}
    end
  end

  def run("halc2_thread_send", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :ok <- live(caller),
         :ok <- no_escalation(me, row),
         :ok <-
           if(row["archivedAt"],
             do: {:error, "thread_not_sendable", "The thread is archived."},
             else: :ok
           ) do
      message_id = "message:mcp:" <> HalC2.Environment.uuid4()

      active = row["activeRunId"]

      # `auto` steers a running turn and starts one otherwise.
      mode =
        case {args["mode"] || "auto", active} do
          {"queue", _} -> %{"type" => "queue_after_active"}
          {"restart", _} -> %{"type" => "restart_active", "targetRunId" => active}
          {"auto", nil} -> %{"type" => "start_immediately"}
          _ -> %{"type" => "steer_active", "targetRunId" => active}
        end

      if mode["type"] in ["steer_active", "restart_active"] and row["activeRunId"] == nil do
        {:error, "thread_not_sendable", "The thread has no running turn to #{args["mode"]}."}
      else
        command = %{
          "type" => "message.dispatch",
          "commandId" => "command:mcp:" <> (args["clientRequestId"] || message_id),
          "threadId" => row["id"],
          "messageId" => message_id,
          "senderThreadId" => me["id"],
          "text" => args["message"],
          "attachments" => [],
          "dispatchMode" => mode,
          "createdBy" => "agent",
          "creationSource" => "mcp"
        }

        with {:ok, _} <- orchestration(Orchestration.dispatch(command)) do
          run = message_run(row["id"], message_id)

          {:ok,
           %{
             "threadId" => row["id"],
             "messageId" => message_id,
             "runId" => run && run["id"],
             "status" => (run && run["status"]) || "queued",
             "delivery" => mode["type"]
           }}
        end
      end
    end
  end

  def run("halc2_thread_wait", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      timeout = wait_timeout(args["timeoutMs"])
      {run, timed_out} = wait(row["id"], args["runId"], timeout)

      {:ok,
       %{
         "threadId" => row["id"],
         "runId" => run && run["id"],
         "status" => (run && run["status"]) || "idle",
         "timedOut" => timed_out
       }}
    end
  end

  def run("halc2_thread_interrupt", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :ok <- live(caller),
         {:ok, _} <-
           orchestration(
             Orchestration.dispatch(%{
               "type" => "run.interrupt",
               "commandId" =>
                 "command:mcp:" <> (args["clientRequestId"] || HalC2.Environment.uuid4()),
               "threadId" => row["id"],
               "runId" => args["runId"] || row["activeRunId"]
             })
           ) do
      {:ok,
       %{
         "threadId" => row["id"],
         "runId" => args["runId"] || row["activeRunId"],
         "interrupted" => true
       }}
    end
  end

  def run("halc2_thread_search", args, %{row: me}) do
    case HalC2.Search.threads(Map.take(args, ["query", "limit"])) do
      {:ok, %{"matches" => matches}} ->
        {:ok, %{"matches" => Enum.filter(matches, &(&1["projectId"] == me["projectId"]))}}

      {:error, message} ->
        {:error, "invalid_request", message}
    end
  end

  # --- environment and projects ------------------------------------------------------

  def run("halc2_environment_read", _args, %{row: me}) do
    environment = HalC2.Environment.descriptor()

    {:ok,
     %{
       "environmentId" => environment["environmentId"],
       "label" => environment["label"],
       "platform" => environment["platform"],
       "currentThreadId" => me["id"],
       "currentProjectId" => me["projectId"],
       "providers" =>
         for provider <- HalC2.Environment.providers(), provider["enabled"] != false do
           %{
             "providerInstanceId" => provider["instanceId"],
             "driver" => provider["driver"],
             "status" => provider["status"],
             "models" => for(model <- provider["models"] || [], do: model["slug"])
           }
         end
     }}
  end

  def run("halc2_environment_preferences_update", args, caller) do
    with :ok <- live(caller),
         :ok <-
           unrestricted(caller, "Preference updates require a live full-access/default thread.") do
      patch =
        Map.take(
          args,
          ~w(defaultThreadEnvMode newWorktreesStartFromOrigin enableProviderUpdateChecks backgroundActivity sourceControlWritingStyle)
        )

      {:ok, preferences(update_settings(patch))}
    end
  end

  def run("halc2_project_list", args, _caller) do
    projects =
      for {{node, _}, {"project", row}} <- HalC2.Shell.rows(),
          node == node() and row["deletedAt"] == nil,
          do: project(row)

    cursor = args["cursor"] || 0
    page = Enum.slice(projects, cursor, args["limit"] || 50)

    {:ok,
     %{
       "projects" => page,
       "nextCursor" => if(cursor + length(page) < length(projects), do: cursor + length(page)),
       "total" => length(projects)
     }}
  end

  def run("halc2_project_read", %{"projectId" => id}, _caller) do
    case project_row(id) do
      nil -> {:error, "invalid_request", "The project was not found."}
      row -> {:ok, %{"project" => project(row)}}
    end
  end

  # --- scheduled tasks ----------------------------------------------------------------

  def run("list_scheduled_tasks", _args, %{row: me}) do
    {:ok, %{"tasks" => tasks}} = HalC2.ScheduledTasks.list()
    {:ok, %{"tasks" => Enum.filter(tasks, &(&1["projectId"] == me["projectId"]))}}
  end

  def run("schedule_task", args, %{row: me} = caller) do
    with :ok <- live(caller) do
      input =
        %{
          "title" => args["title"] || String.slice(args["prompt"] || "", 0, 60),
          "prompt" => args["prompt"],
          "enabled" => args["enabled"] != false,
          "schedule" => args["schedule"],
          "projectId" => me["projectId"],
          "threadId" => if(args["bindToCurrentThread"] == false, do: nil, else: me["id"]),
          "workspaceStrategy" => %{"type" => "root"},
          "modelSelection" => me["modelSelection"],
          "runtimeMode" => me["runtimeMode"],
          "interactionMode" => me["interactionMode"],
          "createdBy" => "agent",
          "creationSource" => "mcp"
        }

      case HalC2.ScheduledTasks.upsert(input) do
        {:ok, %{"task" => task}} -> {:ok, %{"task" => task}}
        {:error, %{"message" => message}} -> {:error, "invalid_request", message}
      end
    end
  end

  def run("update_scheduled_task", %{"scheduledTaskId" => id} = args, %{row: me} = caller) do
    {:ok, %{"tasks" => tasks}} = HalC2.ScheduledTasks.list()

    with :ok <- live(caller),
         %{} = task <-
           Enum.find(tasks, &(&1["id"] == id and &1["projectId"] == me["projectId"])) ||
             {:error, "task_not_found",
              "Scheduled task #{id} was not found in the calling project."} do
      bind = args["bindToCurrentThread"]

      # Unbound runs launch a fresh worktree each time; bound ones post into the thread.
      input =
        Map.merge(task, %{
          "title" => args["title"] || task["title"],
          "prompt" => args["prompt"] || task["prompt"],
          "enabled" =>
            if(is_boolean(args["enabled"]), do: args["enabled"], else: task["enabled"]),
          "schedule" => schedule(args["schedule"]) || task["schedule"],
          "threadId" =>
            case bind do
              nil -> task["threadId"]
              true -> me["id"]
              false -> nil
            end,
          "workspaceStrategy" =>
            case bind do
              nil -> task["workspaceStrategy"]
              true -> %{"type" => "root"}
              false -> %{"type" => "worktree", "baseRef" => "main", "startFromOrigin" => true}
            end
        })

      case HalC2.ScheduledTasks.upsert(input) do
        {:ok, %{"task" => task}} -> {:ok, scheduled_task(task)}
        {:error, %{"message" => message}} -> {:error, "orchestration_error", message}
      end
    end
  end

  def run("delete_scheduled_task", %{"scheduledTaskId" => id}, %{row: me} = caller) do
    with :ok <- live(caller),
         :ok <- own_task(me, id) do
      {:ok, _} = HalC2.ScheduledTasks.delete(%{"id" => id})
      {:ok, %{"taskId" => id, "deleted" => true}}
    end
  end

  def run("run_scheduled_task_now", %{"taskId" => id}, %{row: me} = caller) do
    with :ok <- live(caller),
         :ok <- own_task(me, id) do
      case HalC2.ScheduledTasks.run_now(%{"id" => id}) do
        {:ok, %{"task" => task}} ->
          {:ok,
           Map.take(task, ~w(threadId lastRunStatus runCount nextRunAt)) |> Map.put("taskId", id)}

        {:error, %{"message" => message}} ->
          {:error, "orchestration_error", message}
      end
    end
  end

  # --- preview tabs ----------------------------------------------------------------------

  def run("halc2_preview_list", args, %{row: me}) do
    {:ok, result} = HalC2.Preview.list(%{"threadId" => me["id"]})
    cursor = args["cursor"] || 0
    stop = cursor + (args["limit"] || 20)

    {:ok,
     Map.merge(result, %{
       "sessions" => Enum.slice(result["sessions"], cursor, stop - cursor),
       "nextCursor" => if(stop < length(result["sessions"]), do: stop)
     })}
  end

  def run("halc2_preview_close", %{"tabId" => tab}, %{row: me}) do
    {:ok, _} = HalC2.Preview.close(%{"threadId" => me["id"], "tabId" => tab})
    {:ok, %{}}
  end

  # --- access ---------------------------------------------------------------------------
  # Shared by the area modules; each takes the caller (with its `row`) or its row.

  defp caller_row(%{thread_id: id}) do
    case HalC2.Shell.row(node(), id) do
      {"thread", %{"deletedAt" => nil} = row} -> {:ok, row}
      _ -> {:error, "thread_not_found", "The calling thread was not found."}
    end
  end

  @doc "A thread of the caller's project (the caller itself for nil), as its sidebar row."
  def project_thread(me, nil), do: {:ok, me}

  def project_thread(%{"projectId" => project}, id) do
    case HalC2.Shell.row(node(), id) do
      {"thread", %{"deletedAt" => nil, "projectId" => ^project} = row} ->
        {:ok, row}

      _ ->
        {:error, "thread_not_found", "The thread was not found in the calling project."}
    end
  end

  @doc """
  A thread the caller may change: of its project, with the caller running and the
  target's modes no broader than its own.
  """
  def writable(%{row: me} = caller, id) do
    with {:ok, row} <- project_thread(me, id),
         :ok <- live(caller),
         :ok <- no_escalation(me, row),
         do: {:ok, row}
  end

  @doc """
  Only a caller that is itself running may change things. Read from its stream:
  sidebar rows trail a run's end.
  """
  def live(%{row: me, instance: instance}) do
    running =
      stream(me["id"])
      |> StreamState.list("run")
      |> Enum.any?(&(&1["status"] in ~w(starting running waiting)))

    if me["archivedAt"] == nil and running and me["providerInstanceId"] in [nil, instance],
      do: :ok,
      else:
        {:error, "parent_not_active", "The calling provider no longer owns an active thread run."}
  end

  @doc "Environment-wide changes need an unarchived full-access/default caller."
  def unrestricted(%{row: me}, message) do
    if me["archivedAt"] == nil and me["runtimeMode"] == "full-access" and
         me["interactionMode"] == "default",
       do: :ok,
       else: {:error, "capability_denied", message}
  end

  @doc "Refuses a target whose runtime or interaction mode is broader than the caller's."
  def no_escalation(me, target) do
    cond do
      rank(target["runtimeMode"]) > rank(me["runtimeMode"]) ->
        {:error, "runtime_mode_escalation_denied",
         "Thread runtime mode #{target["runtimeMode"]} is broader than the caller's #{me["runtimeMode"]}."}

      target["interactionMode"] != "plan" and me["interactionMode"] == "plan" ->
        {:error, "interaction_mode_escalation_denied",
         "Thread interaction mode #{target["interactionMode"]} is broader than the caller's plan mode."}

      true ->
        :ok
    end
  end

  @doc "A requested mode (the caller's own for nil or `inherit`), unless broader than the caller's."
  def mode(:runtime, me, requested) when requested in [nil, "inherit"],
    do: {:ok, me["runtimeMode"]}

  def mode(:interaction, me, requested) when requested in [nil, "inherit"],
    do: {:ok, me["interactionMode"]}

  def mode(:runtime, me, requested) do
    if rank(requested) > rank(me["runtimeMode"]),
      do:
        {:error, "runtime_mode_escalation_denied",
         "Child runtime mode #{requested} is broader than parent mode #{me["runtimeMode"]}."},
      else: {:ok, requested}
  end

  def mode(:interaction, me, requested) do
    if requested != "plan" and me["interactionMode"] == "plan",
      do:
        {:error, "interaction_mode_escalation_denied",
         "Child interaction mode #{requested} is broader than parent mode plan."},
      else: {:ok, requested}
  end

  defp rank(mode), do: Map.get(@runtime_ranks, mode, 3)

  defp own_task(me, id) do
    {:ok, %{"tasks" => tasks}} = HalC2.ScheduledTasks.list()

    if Enum.any?(tasks, &(&1["id"] == id and &1["projectId"] == me["projectId"])),
      do: :ok,
      else: {:error, "invalid_request", "The task was not found in the calling project."}
  end

  # --- helpers --------------------------------------------------------------------------

  @doc "A fresh command id for a tool call."
  def command_id, do: "mcp:" <> HalC2.Environment.uuid4()

  @doc "A thread's own entity, current where its sidebar row may trail."
  def thread(id), do: StreamState.get(stream(id), "thread")[id]

  @doc "A project of this node that is not deleted, or nil. Project rows omit null fields."
  def project_row(id) do
    case HalC2.Shell.row(node(), id) do
      {"project", row} -> if row["deletedAt"] == nil, do: row
      _ -> nil
    end
  end

  @doc "A project's threads that are not deleted, most recently updated first."
  def project_threads(project_id) do
    for(
      {{node, _}, {"thread", row}} <- HalC2.Shell.rows(),
      node == node() and row["projectId"] == project_id and row["deletedAt"] == nil,
      do: row
    )
    |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
  end

  @doc "A thread as `halc2_thread_list` lists it."
  def list_item(row) do
    %{
      "threadId" => row["id"],
      "title" => row["title"],
      "status" => row["activityRunStatus"] || row["status"],
      "providerInstanceId" => row["providerInstanceId"],
      "model" => get_in(row, ["modelSelection", "model"]),
      "runtimeMode" => row["runtimeMode"],
      "interactionMode" => row["interactionMode"],
      "branch" => row["branch"],
      "worktreePath" => row["worktreePath"],
      "activeRunId" => row["activeRunId"],
      "latestRunId" => row["latestRunId"],
      "archived" => row["archivedAt"] != nil,
      "parentThreadId" => get_in(row, ["lineage", "parentThreadId"]),
      "updatedAt" => row["updatedAt"]
    }
  end

  defp run_summary(run),
    do: %{
      "runId" => run["id"],
      "ordinal" => run["ordinal"],
      "status" => run["status"],
      "requestedAt" => run["requestedAt"],
      "startedAt" => run["startedAt"],
      "completedAt" => run["completedAt"]
    }

  defp timeline_item(item, position, messages, max_chars, offset) do
    text =
      (item["messageId"] && get_in(messages, [item["messageId"], "text"])) || item["text"] ||
        item["title"] || item["markdown"] || ""

    rest = String.slice(text, offset, String.length(text))

    %{
      "position" => position,
      "itemId" => item["id"],
      "type" => item["type"],
      "runId" => item["runId"],
      "status" => item["status"],
      "text" => String.slice(rest, 0, max_chars),
      "truncated" => String.length(rest) > max_chars
    }
  end

  defp project(row),
    do: Map.take(row, ~w(id title workspaceRoot defaultModelSelection createdAt updatedAt))

  @doc "A thread's stream state."
  def stream(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  @doc "The run a message of the thread belongs to, or nil."
  def message_run(thread_id, message_id) do
    state = stream(thread_id)

    with %{"runId" => run_id} <- StreamState.get(state, "message")[message_id],
         do: StreamState.get(state, "run")[run_id],
         else: (_ -> nil)
  end

  # Waits for a run (the given one, or the latest) to finish, or for the timeout.
  defp wait(thread_id, run_id, timeout) do
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      wait_loop(thread_id, run_id, deadline)
    after
      HalC2.Streams.Server.unsubscribe(thread_id, self())
    end
  end

  defp wait_loop(thread_id, run_id, deadline) do
    runs = StreamState.list(stream(thread_id), "run")

    run =
      if run_id,
        do: Enum.find(runs, &(&1["id"] == run_id)),
        else: Enum.max_by(runs, & &1["ordinal"], fn -> nil end)

    left = deadline - System.monotonic_time(:millisecond)

    cond do
      run == nil or run["status"] in @finished ->
        {run, false}

      left <= 0 ->
        {run, true}

      true ->
        receive do
          {:halc2_stream, ^thread_id, _} -> wait_loop(thread_id, run_id, deadline)
        after
          min(left, 5_000) -> wait_loop(thread_id, run_id, deadline)
        end
    end
  end

  # The preferences agents may read and change, with the defaults clients fill in.
  defp preferences(settings) do
    style =
      Map.merge(
        %{
          "mode" => "repo_conventions",
          "customInstructions" => "",
          "followChangeRequestTemplates" => true
        },
        settings["sourceControlWritingStyle"] || %{}
      )

    text = style["customInstructions"]

    %{
      "defaultThreadEnvMode" => settings["defaultThreadEnvMode"],
      "newWorktreesStartFromOrigin" => Map.get(settings, "newWorktreesStartFromOrigin", true),
      "enableProviderUpdateChecks" => Map.get(settings, "enableProviderUpdateChecks", true),
      "backgroundActivity" => %{
        "profile" => get_in(settings, ["backgroundActivity", "profile"]) || "balanced"
      },
      "sourceControlWritingStyle" =>
        Map.merge(style, %{
          "customInstructions" => String.slice(text, 0, 4000),
          "truncated" => String.length(text) > 4000
        })
    }
  end

  # Merges a patch into the stored settings; a concurrent write makes it try again.
  defp update_settings(patch) do
    {settings, version} = HalC2.Settings.get()

    next =
      Enum.reduce(patch, settings, fn
        {key, value}, acc when key in ["backgroundActivity", "sourceControlWritingStyle"] ->
          Map.update(acc, key, value, &Map.merge(&1 || %{}, value))

        {key, value}, acc ->
          Map.put(acc, key, value)
      end)

    next =
      case get_in(patch, ["backgroundActivity", "profile"]) do
        nil -> next
        profile -> Map.put(next, "backgroundActivityProfile", profile)
      end

    case HalC2.Settings.put(next, version) do
      {:ok, _} -> next
      {:error, :stale} -> update_settings(patch)
    end
  end

  defp scheduled_task(task),
    do: %{
      "scheduledTaskId" => task["id"],
      "title" => task["title"],
      "prompt" => task["prompt"],
      "enabled" => task["enabled"],
      "projectId" => task["projectId"],
      "boundThreadId" => task["threadId"],
      "schedule" => task["schedule"],
      "nextRunAt" => task["nextRunAt"],
      "lastRunStatus" => task["lastRunStatus"]
    }

  # Providers that cannot pass objects send the schedule as JSON text.
  defp schedule(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = schedule} -> schedule
      _ -> nil
    end
  end

  defp schedule(schedule), do: schedule

  defp parse_number(value, _default) when is_number(value), do: round(value)
  defp parse_number(_value, default), do: default

  @doc "An orchestration result as a tool result."
  def orchestration({:ok, _} = ok), do: ok

  def orchestration({:error, message}) when is_binary(message),
    do: {:error, "orchestration_error", message}

  def orchestration({:error, other}), do: {:error, "orchestration_error", inspect(other)}
end
