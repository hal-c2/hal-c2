defmodule HalC2.Mcp.Tools.Queue do
  @moduledoc """
  MCP tools for a thread's queued messages and the questions it is waiting on the
  user for (`HalC2.Mcp.Tools`). Reading needs a thread of the caller's project;
  changing one needs a thread the caller may write (`HalC2.Mcp.Tools.writable/2`).
  Approvals are left to the user: an agent can only answer questions.
  """

  import HalC2.Mcp.Tools,
    only: [command_id: 0, orchestration: 1, project_thread: 2, stream: 1, writable: 2]

  alias HalC2.{Orchestration, StreamState}

  @tools ~w(halc2_queue_list halc2_queue_read halc2_queue_cancel halc2_queue_edit halc2_queue_reorder
            halc2_queue_promote_to_steer halc2_pending_request_list halc2_pending_request_read
            halc2_pending_request_respond)

  def tools, do: @tools

  def run("halc2_queue_list", args, %{row: me}) do
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

  def run("halc2_queue_read", %{"queuedRunId" => run_id} = args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         %{} = entry <- entry(stream(row["id"]), run_id, 16_000) || not_queued(),
         do: {:ok, entry}
  end

  def run("halc2_queue_edit", %{"queuedRunId" => run_id} = args, caller),
    do:
      queue_command(caller, args, %{
        "type" => "queued-run.edit",
        "runId" => run_id,
        "text" => args["text"]
      })

  def run("halc2_queue_cancel", %{"queuedRunId" => run_id} = args, caller),
    do: queue_command(caller, args, %{"type" => "queued-run.cancel", "runId" => run_id})

  def run("halc2_queue_reorder", %{"queuedRunId" => run_id} = args, caller),
    do:
      queue_command(caller, args, %{
        "type" => "queued-run.reorder",
        "runId" => run_id,
        "beforeRunId" => args["beforeRunId"]
      })

  def run("halc2_queue_promote_to_steer", %{"queuedRunId" => run_id} = args, caller),
    do:
      queue_command(caller, args, %{
        "type" => "queued-message.promote-to-steer",
        "queuedRunId" => run_id,
        "targetRunId" => args["targetRunId"]
      })

  def run("halc2_pending_request_list", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      {:ok,
       %{
         "requestIds" =>
           for(
             request <- StreamState.list(stream(row["id"]), "runtime-request"),
             request["kind"] == "user_input" and request["status"] == "pending",
             do: request["id"]
           )
       }}
    end
  end

  def run("halc2_pending_request_read", %{"requestId" => id} = args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         {:ok, item} <- question(row["id"], id),
         do: {:ok, %{"requestId" => id, "questions" => item["questions"]}}
  end

  def run("halc2_pending_request_respond", %{"requestId" => id} = args, caller) do
    with {:ok, row} <- writable(caller, args["threadId"]),
         {:ok, _} <- question(row["id"], id),
         {:ok, %{"sequence" => sequence}} <-
           orchestration(
             Orchestration.dispatch(%{
               "type" => "runtime-request.respond",
               "commandId" => command_id(),
               "threadId" => row["id"],
               "requestId" => id,
               "answers" => args["answers"] || %{}
             })
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
    |> Enum.sort_by(&{&1["queuePosition"] || 0, &1["ordinal"]})
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

  # A pending question of the thread, as its waiting item.
  defp question(thread_id, request_id) do
    state = stream(thread_id)

    with %{"kind" => "user_input", "status" => "pending"} <-
           StreamState.get(state, "runtime-request")[request_id],
         %{} = item <-
           Enum.find(
             StreamState.list(state, "turn-item"),
             &(&1["type"] == "user_input_request" and &1["requestId"] == request_id)
           ) do
      {:ok, item}
    else
      _ -> {:error, "invalid_request", "The pending user-input request was not found."}
    end
  end
end
