defmodule HalC2.Orchestration.IdleSessions do
  @moduledoc """
  Stops provider processes (Codex app-servers, Claude and ACP agents) that have sat
  idle: after 30 minutes without a turn,
  or up to 4 hours while the provider still has background tasks running. The
  session is marked stopped and the next run starts it again, resuming the
  provider's thread (`HalC2.Orchestration.release_session/1`).

  A check runs every few minutes over the threads that have a live process. The same
  check ends a started run that no process drives any more (its provider's session
  stopped without ending it, leaving only the run's record), so the send fails
  explicitly and the thread takes its next message.
  """

  use GenServer

  @registries [HalC2.Codex.Registry, HalC2.Claude.Registry, HalC2.Acp.Registry, HalC2.Pi.Registry]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Releases every idle session now; returns the released thread ids."
  def check, do: GenServer.call(__MODULE__, :check, :timer.minutes(1))

  @impl true
  def init(nil) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call(:check, _from, state), do: {:reply, release_idle(), state}

  @impl true
  def handle_info(:check, state) do
    release_idle()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    case Application.get_env(:hal_c2, :idle_session_check_ms, :timer.minutes(5)) do
      nil -> :ok
      ms -> Process.send_after(self(), :check, ms)
    end
  end

  # Runs of this MC's threads that started, and that neither a provider process nor
  # anything else drives.
  defp end_abandoned do
    for {{mc, thread_id}, {"thread", %{"activeRunId" => run_id}}} <- HalC2.Shell.rows(),
        mc == node() and is_binary(run_id),
        run =
          HalC2.Streams.state(thread_id)
          |> HalC2.StreamState.get("run")
          |> Map.get(run_id),
        run != nil and run["status"] in ~w(running waiting),
        not live?(thread_id) and not HalC2.Orchestration.TurnWatch.driven?(run_id) do
      HalC2.Orchestration.TurnWriter.abandon(
        thread_id,
        run_id,
        "failed",
        "The provider's session ended unexpectedly."
      )
    end
  end

  # A provider process of the thread is still up: its run is its own to end.
  defp live?(thread_id) do
    Enum.any?(
      @registries,
      &(Process.whereis(&1) != nil and Registry.lookup(&1, thread_id) != [])
    )
  end

  defp release_idle do
    end_abandoned()
    now = System.system_time(:millisecond)
    idle_ms = Application.get_env(:hal_c2, :session_idle_ms, :timer.minutes(30))
    pinned_ms = Application.get_env(:hal_c2, :session_max_pin_ms, :timer.hours(4))

    for registry <- @registries,
        Process.whereis(registry) != nil,
        thread_id <- Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        idle?(HalC2.Shell.row(node(), thread_id), now, idle_ms, pinned_ms),
        HalC2.Orchestration.release_session(thread_id) == :ok,
        uniq: true,
        do: thread_id
  end

  # A deleted thread's process has nothing to wait for either.
  defp idle?({"thread", %{"deletedAt" => deleted}}, _now, _idle_ms, _pinned_ms)
       when is_binary(deleted),
       do: true

  defp idle?({"thread", row}, now, idle_ms, pinned_ms) do
    quiet = now - last_activity(row)
    background = (row["pendingBackgroundTasks"] || []) != []

    row["activeRunId"] == nil and row["pendingRuntimeRequest"] == nil and
      quiet >= if(background, do: pinned_ms, else: idle_ms)
  end

  # A process with no thread row (a deleted thread) has nothing to wait for.
  defp idle?(nil, _now, _idle_ms, _pinned_ms), do: true
  defp idle?(_other, _now, _idle_ms, _pinned_ms), do: false

  defp last_activity(row) do
    ~w(createdAt latestUserMessageAt latestRunRequestedAt latestRunStartedAt latestRunCompletedAt)
    |> Enum.flat_map(fn key ->
      with at when is_binary(at) <- row[key],
           {:ok, time, _} <- DateTime.from_iso8601(at) do
        [DateTime.to_unix(time, :millisecond)]
      else
        _ -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
  end
end
