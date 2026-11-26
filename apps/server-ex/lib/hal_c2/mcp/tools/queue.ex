defmodule HalC2.Mcp.Tools.Queue do
  @moduledoc """
  MCP tools for a thread's queued messages, held queue and the requests it is
  waiting on (`HalC2.Mcp.Tools`). Reading needs a thread of the caller's project;
  changing one needs a thread the caller may write (`HalC2.Mcp.Tools.writable/2`).

  Any writer may answer a question. An approval is the user's, except to the agent
  that delegated the thread's work (its lineage parent) running at full access: the
  child can hold no more than its parent's modes, so that parent may already do what
  the child asks. It decides once (`accept`, `acceptForSession`, `decline`,
  `cancel`); a standing rule (`acceptAlways`) stays the user's.
  """

  import HalC2.Mcp.Tools,
    only: [command_id: 0, orchestration: 1, project_thread: 2, stream: 1, writable: 2]

  alias HalC2.{Orchestration, StreamState}

  @tools ~w(hal_c2_queue_list hal_c2_queue_read hal_c2_queue_cancel hal_c2_queue_edit hal_c2_queue_reorder
            hal_c2_queue_promote_to_steer hal_c2_queue_resume hal_c2_pending_request_list
            hal_c2_pending_request_read hal_c2_pending_request_respond)

  # What a parent may decide on its child's approval: once, never a standing rule.
  @agent_decisions ~w(accept acceptForSession decline cancel)

  def tools, do: @tools

  def run("hal_c2_queue_list", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      state = stream(row["id"])
      queued = queued(state)
      cursor = args["cursor"] || 0
      stop = cursor + (args["limit"] || 20)

      {:ok,
       %{
         "items" =>
           for(
             run <- Enum.slice(queued, cursor, stop - cursor),
             entry = entry(state, run["id"], 1000),
             do: entry
           ),
         "nextCursor" => if(stop < length(queued), do: stop)
       }}
    end
  end

  def run("hal_c2_queue_read", %{"queuedRunId" => run_id} = args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         %{} = entry <- entry(stream(row["id"]), run_id, 16_000) || not_queued(),
         do: {:ok, entry}
  end

  def run("hal_c2_queue_edit", %{"queuedRunId" => run_id} = args, caller),
    do:
      queue_command(caller, args, %{
        "type" => "queued-run.edit",
        "runId" => run_id,
        "text" => args["text"]
      })

  def run("hal_c2_queue_cancel", %{"queuedRunId" => run_id} = args, caller),
    do: queue_command(caller, args, %{"type" => "queued-run.cancel", "runId" => run_id})

  def run("hal_c2_queue_reorder", %{"queuedRunId" => run_id} = args, caller),
    do:
      queue_command(caller, args, %{
        "type" => "queued-run.reorder",
        "runId" => run_id,
        "beforeRunId" => args["beforeRunId"]
      })

  def run("hal_c2_queue_promote_to_steer", %{"queuedRunId" => run_id} = args, caller),
    do:
      queue_command(caller, args, %{
        "type" => "queued-message.promote-to-steer",
        "queuedRunId" => run_id,
        "targetRunId" => args["targetRunId"]
      })

  # A held queue (after a restart, a usage limit, a stop) starts again, as the user's
  # Resume does.
  def run("hal_c2_queue_resume", args, caller) do
    with {:ok, row} <- writable(caller, args["threadId"]),
         {:ok, %{"sequence" => sequence}} <-
           orchestration(
             Orchestration.dispatch(%{
               "type" => "queue.resume",
               "commandId" => command_id(),
               "threadId" => row["id"]
             })
           ),
         do: {:ok, %{"sequence" => sequence}}
  end

  def run("hal_c2_pending_request_list", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      pending =
        for request <- StreamState.list(stream(row["id"]), "runtime-request"),
            request["status"] == "pending",
            do: request

      {:ok,
       %{
         "requestIds" => Enum.map(pending, & &1["id"]),
         "requests" =>
           for(
             request <- pending,
             do: %{
               "requestId" => request["id"],
               "kind" => request["kind"],
               "createdAt" => request["createdAt"]
             }
           )
       }}
    end
  end

  def run("hal_c2_pending_request_read", %{"requestId" => id} = args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         {:ok, request, item} <- pending(row["id"], id) do
      if request["kind"] == "user_input" do
        {:ok, %{"requestId" => id, "kind" => "user_input", "questions" => item["questions"]}}
      else
        {:ok,
         %{
           "requestId" => id,
           "kind" => request["kind"],
           "prompt" => item["prompt"],
           "reason" => item["reason"],
           "fullAccessOverride" => item["fullAccessOverride"],
           "options" => item["options"] || default_options(),
           "canRespond" => approver(me, row["id"]) == :ok
         }
         |> Map.reject(fn {_key, value} -> value == nil end)}
      end
    end
  end

  def run("hal_c2_pending_request_respond", %{"requestId" => id} = args, %{row: me} = caller) do
    with {:ok, row} <- writable(caller, args["threadId"]),
         {:ok, request, item} <- pending(row["id"], id),
         {:ok, answer} <- answer(me, row["id"], request, item, args),
         {:ok, %{"sequence" => sequence}} <-
           orchestration(
             Orchestration.dispatch(
               Map.merge(
                 %{
                   "type" => "runtime-request.respond",
                   "commandId" => command_id(),
                   "threadId" => row["id"],
                   "requestId" => id
                 },
                 answer
               )
             )
           ),
         do: {:ok, %{"sequence" => sequence}}
  end

  # --- helpers ----------------------------------------------------------------------------

  # Queue commands name a run that is still queued; the rest are left alone.
  defp queue_command(caller, args, command) do
    with {:ok, row} <- writable(caller, args["threadId"]),
         %{} <- entry(stream(row["id"]), args["queuedRunId"], 0) || not_queued(),
         {:ok, %{"sequence" => sequence}} <-
           command
           |> Map.merge(%{"commandId" => command_id(), "threadId" => row["id"]})
           |> Orchestration.dispatch()
           |> orchestration(),
         do: {:ok, %{"sequence" => sequence}}
  end

  # Queued runs in the order they will start.
  defp queued(state) do
    state
    |> StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(&{&1["queuePosition"] || 0, &1["ordinal"] || 0})
  end

  defp entry(state, run_id, limit) do
    with %{"status" => "queued"} = run <- StreamState.get(state, "run")[run_id],
         %{} = message <- StreamState.get(state, "message")[run["userMessageId"]] do
      text = message["text"] || ""

      %{
        "queuedRunId" => run_id,
        "text" => String.slice(text, 0, limit),
        "truncated" => String.length(text) > limit
      }
    else
      _ -> nil
    end
  end

  defp not_queued, do: {:error, "invalid_request", "The queued message was not found."}

  # A pending request of the thread, with its waiting item (the question or the
  # approval the user is shown).
  defp pending(thread_id, request_id) do
    state = stream(thread_id)
    request = StreamState.get(state, "runtime-request")[request_id]

    with %{"status" => "pending"} = request <- request,
         %{} = item <-
           Enum.find(
             StreamState.list(state, "turn-item"),
             &(&1["type"] in ["user_input_request", "approval_request"] and
                 &1["requestId"] == request_id)
           ) do
      {:ok, request, item}
    else
      _ -> {:error, "invalid_request", no_longer(request)}
    end
  end

  # A question that is over says how it ended, not that it was never there
  # (upstream #22850).
  defp no_longer(%{"kind" => "user_input", "status" => status}) do
    case status do
      "resolved" -> "The user-input request was already answered."
      "expired" -> "The user-input request is no longer pending (expired)."
      "cancelled" -> "The user-input request is no longer pending (cancelled)."
      _other -> "The pending request was not found."
    end
  end

  defp no_longer(_request), do: "The pending request was not found."

  # A question takes answers; an approval a decision, from its approver only.
  defp answer(_me, _thread_id, %{"kind" => "user_input"}, _item, args) do
    case args["answers"] do
      %{} = answers -> {:ok, %{"answers" => answers}}
      _ -> {:error, "invalid_request", "A question is answered with answers."}
    end
  end

  defp answer(me, thread_id, _request, item, args) do
    offered = for option <- item["options"] || default_options(), do: option["decision"]

    with :ok <- approver(me, thread_id) do
      decision = args["decision"]

      if decision in @agent_decisions and decision in offered,
        do: {:ok, %{"decision" => decision}},
        else:
          {:error, "invalid_request",
           "An approval is answered with a decision, one of: " <>
             Enum.join(Enum.filter(offered, &(&1 in @agent_decisions)), ", ") <> "."}
    end
  end

  # The decisions an approval without its own choices offers.
  defp default_options do
    [
      %{"decision" => "accept", "label" => "Approve"},
      %{"decision" => "acceptForSession", "label" => "Approve for this session"},
      %{"decision" => "decline", "label" => "Decline"}
    ]
  end

  # Only the agent that delegated the thread's work, at full access, decides its
  # approvals; anyone else leaves them to the user.
  defp approver(me, thread_id) do
    lineage = (HalC2.Mcp.Tools.thread(thread_id) || %{})["lineage"] || %{}
    # A fork's parent is only where the user branched it from.
    parent = lineage["relationshipToParent"] == "subagent" && lineage["parentThreadId"]
    # The caller's stream, not its sidebar row: the row trails a mode change.
    mode = (HalC2.Mcp.Tools.thread(me["id"]) || me)["runtimeMode"]

    cond do
      parent != me["id"] ->
        {:error, "capability_denied",
         "Approvals are the user's. Only the agent that delegated this thread's work, at full access, may decide them."}

      mode != "full-access" ->
        {:error, "capability_denied",
         "This thread runs #{mode || "supervised"}, so its workers' approvals are the user's. Tell the user what the worker asks and where (its thread)."}

      true ->
        :ok
    end
  end
end
