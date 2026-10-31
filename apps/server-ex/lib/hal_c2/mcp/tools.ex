defmodule HalC2.Mcp.Tools do
  @moduledoc """
  The tools of the `hal-c2` MCP server (`HalC2.Mcp`), each acting as the thread whose
  agent called it. Definitions come from `priv/mcp_tools.json` and, for moving threads
  between machines, `priv/mcp_mc_tools.json`; only the tools implemented here and in the
  area modules (`HalC2.Mcp.Tools.Threads`, `Queue`, `Projects` and `PullRequests`), which
  share the access helpers below, are advertised.

  The access rules: a caller sees only threads of its own
  project; changing another thread needs a caller that is itself running, and never
  gives the target broader runtime or interaction modes than the caller has.
  """

  alias HalC2.{Orchestration, StreamState}

  @implemented ~w(hal_c2_thread_list hal_c2_thread_read hal_c2_thread_send hal_c2_thread_wait hal_c2_thread_interrupt
                  hal_c2_thread_search hal_c2_environment_read hal_c2_environment_preferences_update
                  hal_c2_project_list hal_c2_project_read list_scheduled_tasks schedule_task
                  update_scheduled_task delete_scheduled_task run_scheduled_task_now
                  hal_c2_preview_list hal_c2_preview_close)

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
  # How long the MC a thread moved to has to answer a send, stop or read.
  @owner_timeout :timer.minutes(2)

  # The tools a run that may only read is pre-approved for, as Claude names them
  # (`mcp__hal-c2__<tool>`): the advertised ones that only read, mirroring the
  # read-only annotations upstream's Claude adapter cross-checks.
  @read_only ~w(orchestrator_capabilities list_scheduled_tasks hal_c2_thread_list
                hal_c2_thread_wait hal_c2_pending_request_list hal_c2_pending_request_read
                hal_c2_thread_configuration hal_c2_thread_transfers hal_c2_worktree_status
                hal_c2_worktree_list hal_c2_project_list hal_c2_project_read
                hal_c2_thread_search hal_c2_preview_list hal_c2_environment_read
                hal_c2_queue_list hal_c2_queue_read list_thread_pull_requests)

  @doc "The read-only tools' Claude names, of those this MC advertises."
  @spec read_only_allowed() :: [String.t()]
  def read_only_allowed do
    advertised = MapSet.new(list(), & &1["name"])

    for name <- @read_only,
        MapSet.member?(advertised, name),
        do: "mcp__hal-c2__" <> name
  end

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
          Enum.flat_map(
            ~w(mcp_tools.json mcp_mc_tools.json),
            &(Application.app_dir(:hal_c2, Path.join("priv", &1))
              |> File.read!()
              |> JSON.decode!())
          )

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

  # The browser tools are the credential's preview capability to give: a
  # credential minted while the user withheld agent browser access (or while
  # the settings granting it could not be read) is refused here, everywhere
  # the token is honoured. A caller minted before capabilities existed has
  # none recorded and keeps the access its session was given.
  def call(name, args, caller) when name in @preview do
    capabilities = Map.get(caller, :capabilities)

    if capabilities == nil or MapSet.member?(capabilities, "preview") do
      HalC2.Mcp.Preview.call(name, args, caller)
    else
      {:error, "capability_denied",
       "Agent browser access is turned off for this thread's project, so #{name} is not available to its agent."}
    end
  end

  def call(name, args, caller) when name in @devices,
    do: HalC2.Mcp.Devices.call(name, args, caller)

  def call(name, args, caller) do
    area = if name in @implemented, do: __MODULE__, else: Enum.find(@areas, &(name in &1.tools()))

    if area do
      with {:ok, me} <- caller_row(caller), do: area.run(name, args, Map.put(caller, :row, me))
    else
      {:error, "capability_denied", "#{name} is not available on this MC."}
    end
  end

  # --- threads ---------------------------------------------------------------------

  @doc """
  How long `hal_c2_thread_wait` waits for a requested `timeoutMs`: 10 minutes when none
  is given, at least 1 millisecond and at most 1 hour.
  """
  def wait_timeout(requested), do: min(max(parse_number(requested, 600_000), 1), 3_600_000)

  @doc """
  `wait_timeout/1` cut to what the caller's provider can wait for
  (`HalC2.Mcp.max_wait_ms/1`). A caller forwarded from another MC brings that MC's
  answer as `max_wait_ms`: this one may not know the caller's provider instance.
  """
  def wait_limit(requested, caller),
    do: min(wait_timeout(requested), max_wait(caller))

  defp max_wait(%{max_wait_ms: ms}), do: ms
  defp max_wait(caller), do: HalC2.Mcp.max_wait_ms(caller.instance)

  @doc false
  def run(name, args, caller)

  def run("hal_c2_thread_list", args, %{row: me}) do
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
      |> Enum.filter(&(not is_boolean(args["settled"]) or settled?(&1) == args["settled"]))

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

  def run("hal_c2_thread_read", args, %{row: me} = caller) do
    with {:ok, row} <- readable_thread(me, args["threadId"]),
         :here <- on_owner(row, "hal_c2_thread_read", args, caller) do
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

      read =
        Enum.map(page, fn {item, position} ->
          timeline_item(item, position, messages, max_chars, args["textOffset"] || 0)
        end)

      # Reading a finished direct child's answer in full is the caller taking
      # its result: its automatic delivery is acknowledged, so no wake follows.
      # The answer is the child's last assistant message, so only a page that
      # contains it untruncated counts, not an early progress message or the
      # first page of a long child. It is picked from the unfiltered turn items:
      # `items` may already be narrowed to one earlier item by `itemId`.
      last_answer_id =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(&(&1["type"] == "assistant_message"))
        |> List.last(%{})
        |> Map.get("id")

      answer_read? =
        Enum.any?(page, fn {item, position} ->
          item["id"] == last_answer_id and
            Enum.any?(
              read,
              &(&1["position"] == position and &1["type"] == "assistant_message" and
                  not &1["truncated"])
            )
        end)

      if (args["textOffset"] || 0) == 0 and answer_read? do
        observed =
          me["id"]
          |> stream()
          |> StreamState.list("run")
          |> Enum.filter(&(&1["status"] in ~w(preparing starting running waiting)))
          |> Enum.max_by(&(&1["ordinal"] || 0), fn -> %{} end)
          |> Map.get("id")

        HalC2.Orchestration.Delegation.acknowledge_child_read(me["id"], row["id"], observed)
      end

      {:ok,
       %{
         "thread" => Map.put(list_item(row), "totalItems", length(items)),
         "recentRuns" =>
           state
           |> StreamState.list("run")
           |> Enum.sort_by(&(&1["ordinal"] || 0), :desc)
           |> Enum.take(args["runLimit"] || 10)
           |> Enum.map(&run_summary/1),
         "items" => read,
         "nextPosition" =>
           case List.last(page) do
             {_, position} -> position
             nil -> nil
           end,
         "hasMore" => length(items) > after_position + 1 + length(page)
       }}
    end
  end

  def run("hal_c2_thread_send", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :ok <- live(caller) do
      deliver(row["id"], me, args)
    end
  end

  def run("hal_c2_thread_wait", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :here <- on_owner(row, "hal_c2_thread_wait", args, caller) do
      timeout = wait_limit(args["timeoutMs"], caller)
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

  def run("hal_c2_thread_interrupt", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :ok <- live(caller) do
      interrupt(row["id"], args, me["id"])
    end
  end

  def run("hal_c2_thread_search", args, %{row: me}) do
    case HalC2.Search.threads(Map.take(args, ["query", "limit"])) do
      {:ok, %{"matches" => matches}} ->
        {:ok, %{"matches" => Enum.filter(matches, &(&1["projectId"] == me["projectId"]))}}

      {:error, message} ->
        {:error, "invalid_request", message}
    end
  end

  # --- environment and projects ------------------------------------------------------

  def run("hal_c2_environment_read", _args, %{row: me} = caller) do
    with :ok <- own_environment(caller) do
      environment = HalC2.Environment.descriptor()
      {settings, _version} = HalC2.Settings.get()

      {:ok,
       %{
         "environmentId" => environment["environmentId"],
         "label" => environment["label"],
         "platform" => environment["platform"],
         "preferences" => preferences(settings),
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
  end

  def run("hal_c2_environment_preferences_update", args, caller) do
    with :ok <- own_environment(caller),
         :ok <- live(caller),
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

  def run("hal_c2_project_list", args, _caller) do
    projects =
      for {{mc, _}, {"project", row}} <- HalC2.Shell.rows(),
          mc == node() and row["deletedAt"] == nil,
          do: project(row)

    cursor = args["cursor"] || 0
    page = Enum.slice(projects, cursor, args["limit"] || 20)

    {:ok,
     %{
       "projects" => page,
       "nextCursor" => if(cursor + length(page) < length(projects), do: cursor + length(page)),
       "total" => length(projects)
     }}
  end

  def run("hal_c2_project_read", %{"projectId" => id}, _caller) do
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

  def run("hal_c2_preview_list", args, %{row: me}) do
    {:ok, result} = HalC2.Preview.list(%{"threadId" => me["id"]})
    cursor = args["cursor"] || 0
    stop = cursor + (args["limit"] || 20)

    {:ok,
     Map.merge(result, %{
       "sessions" => Enum.slice(result["sessions"], cursor, stop - cursor),
       "nextCursor" => if(stop < length(result["sessions"]), do: stop)
     })}
  end

  def run("hal_c2_preview_close", %{"tabId" => tab}, %{row: me}) do
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

  # The environment tools act on this MC's preferences, so a credential another
  # environment issued — its stamp names a different environment id — is refused
  # even where the token is otherwise honoured. A caller minted before
  # credentials carried the stamp has none and keeps its access. No production
  # path reaches this yet: credentials are minted into this MC's local table
  # and the environment tools are never forwarded between MCs, so the stamp
  # only differs when a cluster-peer token is honoured here later.
  defp own_environment(caller) do
    case Map.get(caller, :environment_id) do
      nil -> :ok
      id -> if id == HalC2.Environment.id(), do: :ok, else: foreign_credential()
    end
  end

  defp foreign_credential,
    do: {:error, "capability_denied", "This credential belongs to another environment."}

  # A thread `hal_c2_thread_read` may show the caller: one of its project, or one
  # the user attached to the caller's conversation as context, of any project.
  # A deleted one the caller could otherwise read says it is gone, not missing.
  defp readable_thread(me, nil), do: {:ok, me}

  defp readable_thread(%{"projectId" => project} = me, id) do
    case HalC2.Shell.row(node(), id) do
      {"thread", row} ->
        cond do
          row["projectId"] != project and not user_attached?(me, id) ->
            {:error, "thread_not_found", "The thread was not found in the calling project."}

          row["deletedAt"] != nil ->
            {:error, "thread_not_found", "Thread #{id} is no longer available."}

          true ->
            {:ok, row}
        end

      _ ->
        {:error, "thread_not_found", "The thread was not found in the calling project."}
    end
  end

  # Only records on messages the user wrote count: an agent cannot widen its own
  # reach by writing a `thread` context record naming a thread elsewhere.
  defp user_attached?(me, thread_id) do
    me["id"]
    |> stream()
    |> StreamState.list("message")
    |> Enum.any?(fn message ->
      message["role"] == "user" and message["createdBy"] == "user" and
        Enum.any?(
          get_in(message, ["context", "records"]) || [],
          &(&1["kind"] == "thread" and &1["threadId"] == thread_id)
        )
    end)
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

  @doc "A project of this MC that is not deleted, or nil. Project rows omit null fields."
  def project_row(id) do
    case HalC2.Shell.row(node(), id) do
      {"project", row} -> if row["deletedAt"] == nil, do: row
      _ -> nil
    end
  end

  @doc "A project's threads that are not deleted, most recently updated first."
  def project_threads(project_id) do
    for(
      {{mc, _}, {"thread", row}} <- HalC2.Shell.rows(),
      mc == node() and row["projectId"] == project_id and row["deletedAt"] == nil,
      do: row
    )
    |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
  end

  # Whether the thread is settled: moved out of the active list by the user or
  # by automatic settlement (`thread.settle` records the override either way).
  defp settled?(row), do: row["settledOverride"] == "settled"

  # The settlement a list or read answer carries: whether the thread settled and
  # when, and why it can or cannot settle now — automatic settlement's own
  # blockers (`HalC2.Orchestration.Settlement.blocker/2`).
  defp settlement(row) do
    settled = settled?(row)
    blocker = HalC2.Orchestration.Settlement.blocker(row, System.system_time(:millisecond))

    %{
      "settled" => settled,
      "settledAt" => if(settled, do: row["settledAt"]),
      "canSettle" => blocker == nil,
      "settlementReason" => blocker || "nothing is running or pending"
    }
  end

  @doc "A thread as `hal_c2_thread_list` lists it."
  def list_item(row) do
    Map.merge(
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
      },
      settlement(row)
    )
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
  def stream(thread_id), do: HalC2.Streams.state(thread_id)

  @doc """
  Sends the message of `sender`, the calling agent's thread row, to a thread of this
  MC, or of the MC it moved to: `auto` steers a running turn and starts one otherwise.
  The thread's modes are checked where it lives, as they are now.
  """
  def deliver(id, sender, args) do
    case HalC2.Shell.row(node(), id) do
      {"thread", %{"movedTo" => %{"mc" => mc}}} when is_binary(mc) ->
        on_mc(mc, __MODULE__, :deliver, [id, sender, args], @owner_timeout)

      {"thread", %{"archivedAt" => archived}} when archived != nil ->
        {:error, "thread_not_sendable", "The thread is archived."}

      {"thread", row} ->
        # The stream's modes: the sidebar row trails a change.
        with :ok <- no_escalation(sender, thread(id) || row),
             do: dispatch_message(row, sender["id"], args)

      nil ->
        {:error, "thread_not_found", "The thread was not found."}
    end
  end

  defp dispatch_message(row, sender, args) do
    # A retry with the same request key names the same message and command, so
    # the command receipt answers it without delivering the message twice.
    key = args["clientRequestId"]

    message_id =
      if key,
        do: "message:mcp:#{sender}:#{key}",
        else: "message:mcp:" <> HalC2.Environment.uuid4()

    active = row["activeRunId"]

    mode =
      case {args["mode"] || "auto", active} do
        {"queue", _} -> %{"type" => "queue_after_active"}
        {"restart", _} -> %{"type" => "restart_active", "targetRunId" => active}
        {"auto", nil} -> %{"type" => "start_immediately"}
        _ -> %{"type" => "steer_active", "targetRunId" => active}
      end

    if mode["type"] in ["steer_active", "restart_active"] and active == nil do
      {:error, "thread_not_sendable", "The thread has no running turn to #{args["mode"]}."}
    else
      command = %{
        "type" => "message.dispatch",
        "commandId" => "command:mcp:#{sender}:" <> (args["clientRequestId"] || message_id),
        "threadId" => row["id"],
        "messageId" => message_id,
        "senderThreadId" => sender,
        "text" => args["message"],
        "attachments" => [],
        "dispatchMode" => mode,
        "createdBy" => "agent",
        "creationSource" => "mcp"
      }

      with {:ok, _} <- orchestration(Orchestration.dispatch_once(command)) do
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

  @doc """
  Interrupts a run of a thread of this MC, or of the MC it moved to, on behalf
  of `caller_id`. The retry key is scoped by caller, so one agent's key never
  answers another's call; a retry with the same key gets the first answer back
  from its receipt, whenever it comes.
  """
  def interrupt(id, args, caller_id \\ nil) do
    command_id =
      "command:mcp:interrupt:#{caller_id || id}:" <>
        (args["clientRequestId"] || HalC2.Environment.uuid4())

    case HalC2.Shell.row(node(), id) do
      {"thread", %{"movedTo" => %{"mc" => mc}}} when is_binary(mc) ->
        on_mc(mc, __MODULE__, :interrupt, [id, args, caller_id], @owner_timeout)

      {"thread", _row} ->
        case interrupt_receipt(args["clientRequestId"], command_id, id) do
          {:ok, answer} -> {:ok, answer}
          {:error, _, _} = refused -> refused
          nil -> interrupt_now(id, args, command_id)
        end

      nil ->
        {:error, "thread_not_found", "The thread was not found."}
    end
  end

  # The first answer a keyed interrupt gave, kept beside the command receipts:
  # a retry after a lost response is answered from it, not from whatever run
  # happens to be active (or finished) by then. A key already spent on another
  # thread is refused, as `dispatch_once` refuses it.
  defp interrupt_receipt(nil, _command_id, _id), do: nil

  defp interrupt_receipt(_key, command_id, id) do
    case HalC2.Store.meta(HalC2.Store.path(), "mcp-interrupt:" <> command_id) do
      nil ->
        nil

      receipt ->
        case JSON.decode!(receipt) do
          %{"threadId" => ^id, "answer" => answer} ->
            {:ok, answer}

          %{"threadId" => handled} ->
            {:error, "orchestration_error",
             "Command #{command_id} was already handled for thread #{handled} and cannot be replayed for #{id}."}
        end
    end
  end

  defp keep_interrupt_receipt(nil, _command_id, _answer), do: :ok

  defp keep_interrupt_receipt(_key, command_id, answer) do
    HalC2.Store.put_meta(
      "mcp-interrupt:" <> command_id,
      JSON.encode!(%{"threadId" => answer["threadId"], "answer" => answer})
    )

    :ok
  end

  defp interrupt_now(id, args, command_id) do
    # From the stream: the sidebar row trails a run's start. A run that
    # already finished, and a thread with none running, answer what
    # happened without another side effect.
    runs = StreamState.list(stream(id), "run")
    named = args["runId"] && Enum.find(runs, &(&1["id"] == args["runId"]))

    active =
      Enum.find(
        runs,
        &(&1["status"] in ~w(preparing starting running waiting) and
            (args["runId"] == nil or &1["id"] == args["runId"]))
      )

    cond do
      active != nil ->
        run = active["id"]

        with {:ok, _} <-
               orchestration(
                 Orchestration.dispatch_once(%{
                   "type" => "run.interrupt",
                   "commandId" => command_id,
                   "threadId" => id,
                   "runId" => run
                 })
               ) do
          answer = %{
            "threadId" => id,
            "runId" => run,
            "status" => "interrupt_requested",
            "interrupted" => true
          }

          keep_interrupt_receipt(args["clientRequestId"], command_id, answer)
          {:ok, answer}
        end

      named != nil ->
        {:ok,
         %{
           "threadId" => id,
           "runId" => named["id"],
           "status" => named["status"],
           "interrupted" => false
         }}

      args["runId"] != nil ->
        {:error, "invalid_request", "Run #{args["runId"]} was not found in the thread."}

      # Kept too: a retry must not interrupt a run that started after this answer.
      true ->
        answer = %{
          "threadId" => id,
          "runId" => nil,
          "status" => "no_active_run",
          "interrupted" => false
        }

        keep_interrupt_receipt(args["clientRequestId"], command_id, answer)
        {:ok, answer}
    end
  end

  # A thread that moved to another MC of the cluster lives there: what is asked of it
  # runs on that MC, in the project it moved into. `:here` for a thread that did not move.
  defp on_owner(%{"movedTo" => %{"mc" => mc, "projectId" => project}}, name, args, caller)
       when is_binary(mc) and is_binary(project) do
    caller = %{caller | row: %{caller.row | "projectId" => project}}
    caller = Map.put(caller, :max_wait_ms, max_wait(caller))
    on_mc(mc, __MODULE__, :run, [name, args, caller], owner_timeout(name, args, caller))
  end

  defp on_owner(_row, _name, _args, _caller), do: :here

  # How long the other MC has to answer: a wait for as long as it may wait, and a
  # little more, so its own timeout answers first.
  defp owner_timeout("hal_c2_thread_wait", args, caller),
    do: wait_limit(args["timeoutMs"], caller) + :timer.seconds(30)

  defp owner_timeout(_name, _args, _caller), do: @owner_timeout

  defp on_mc(mc, module, fun, args, timeout) do
    :erpc.call(String.to_atom(mc), module, fun, args, timeout)
  catch
    :error, {:erpc, reason} ->
      {:error, "thread_unreachable",
       "The MC the thread moved to is unreachable (#{inspect(reason)})."}
  end

  @doc "The run a message of the thread belongs to, or nil."
  def message_run(thread_id, message_id) do
    state = stream(thread_id)

    with %{"runId" => run_id} <- StreamState.get(state, "message")[message_id],
         do: StreamState.get(state, "run")[run_id],
         else: (_ -> nil)
  end

  # Waits for a run (the given one, or the latest) to finish, or for the timeout.
  defp wait(thread_id, run_id, timeout) do
    :ok = HalC2.Streams.watch(thread_id, self())
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
        else: HalC2.Projection.Shell.latest_run(runs)

    left = deadline - System.monotonic_time(:millisecond)

    cond do
      run == nil or run["status"] in @finished ->
        {run, false}

      left <= 0 ->
        {run, true}

      true ->
        receive do
          {:hal_c2_stream, ^thread_id, _} -> wait_loop(thread_id, run_id, deadline)
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
