defmodule HalC2.Orchestration.Wake do
  @moduledoc """
  Wakes a thread for work a provider finished in the background: a message from the
  agent, queued behind the thread's running turn, whose run tells the provider. The
  Claude and Codex runtimes call `deliver/3` off their own process, since starting the
  run calls back into them.

  A wake for a thread that was archived or deleted is dropped. One the engine does not
  take is tried again, 100 ms later at first and doubling to at most 5 s between tries
  (apps/server ProviderContinuationService.ts), with the same message id, so a try
  that did land is not sent twice.
  """

  require Logger

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.Entities

  @tries 10

  def child_spec(_opts), do: Task.Supervisor.child_spec(name: __MODULE__)

  @doc """
  Sends the wake `message` (`text`, `notification` and the like, merged into the
  `message.dispatch`) to `thread_id` in a task of its own. Its run is on the model of
  the latest run on provider instance `opts[:instance]`, the one that woke, or of the
  latest run when it has none. `opts[:on_dropped]` runs, in that task, when no wake
  will be sent: the thread was put away, or every try failed.
  """
  def deliver(thread_id, message, opts \\ []) do
    message_id = Entities.new_id("message")
    message = Map.put(message, :instance, opts[:instance])
    on_dropped = Keyword.get(opts, :on_dropped, fn -> :ok end)
    run = fn -> send_wake(thread_id, message_id, message, on_dropped, 0) end

    if Process.whereis(__MODULE__),
      do: Task.Supervisor.start_child(__MODULE__, run),
      else: Task.start(run)
  end

  @doc "How long to wait before try `attempt + 1`, for the `attempt`th failure (from 0)."
  def retry_delay(attempt), do: min(100 * 2 ** min(attempt, 6), 5_000)

  @doc """
  Returns once every wake on its way has been sent or dropped. For tests, which wait on
  it rather than on time.
  """
  def drain do
    if Process.whereis(__MODULE__) do
      refs =
        for pid <- Task.Supervisor.children(__MODULE__), do: Process.monitor(pid)

      for ref <- refs, do: receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
    end

    :ok
  end

  defp send_wake(thread_id, message_id, message, on_dropped, attempt) do
    stream = HalC2.Streams.state(thread_id)
    thread = StreamState.get(stream, "thread")[thread_id] || %{}

    if thread["archivedAt"] != nil or thread["deletedAt"] != nil do
      on_dropped.()
    else
      {instance, message} = Map.pop(message, :instance)
      runs = StreamState.list(stream, "run")
      own = Enum.filter(runs, &(get_in(&1, ["modelSelection", "instanceId"]) == instance))

      # Not a held queue's run, which waits with a higher ordinal behind the one that ran.
      latest =
        HalC2.Projection.Shell.latest_run(own) || HalC2.Projection.Shell.latest_run(runs) || %{}

      command =
        Map.merge(
          %{
            "type" => "message.dispatch",
            "commandId" => "command:wake:#{message_id}",
            "threadId" => thread_id,
            "messageId" => message_id,
            "attachments" => [],
            "modelSelection" => latest["modelSelection"],
            "dispatchMode" => %{"type" => "queue_after_active"},
            "createdBy" => "agent",
            "creationSource" => "provider"
          },
          message
        )

      case dispatch(command) do
        {:ok, _} -> :ok
        {:error, reason} -> retry(thread_id, message_id, message, on_dropped, attempt, reason)
      end
    end
  catch
    kind, reason ->
      retry(thread_id, message_id, message, on_dropped, attempt, {kind, reason})
  end

  defp retry(thread_id, message_id, message, on_dropped, attempt, reason) do
    if attempt + 1 < @tries do
      Logger.warning("wake of #{thread_id} not taken, trying again: #{inspect(reason)}")
      Process.sleep(retry_delay(attempt))
      send_wake(thread_id, message_id, message, on_dropped, attempt + 1)
    else
      Logger.warning("wake of #{thread_id} dropped: #{inspect(reason)}")
      on_dropped.()
    end
  end

  # Tests refuse a try: `{module, function, args}`, called with the command, returning
  # `:ok` to send it or a result to stand in for the engine's.
  defp dispatch(command) do
    case Application.get_env(:hal_c2, :wake_hook) do
      {m, f, a} ->
        with :ok <- apply(m, f, a ++ [command]), do: Orchestration.dispatch(command)

      nil ->
        Orchestration.dispatch(command)
    end
  end
end
