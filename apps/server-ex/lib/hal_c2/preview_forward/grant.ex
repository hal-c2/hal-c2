defmodule HalC2.PreviewForward.Grant do
  @moduledoc """
  On the thread's MC, the permission behind one forward: while one of the
  thread's browser tabs names a loopback URL at the port, the client MC's
  `Listener` (`owner`) may have its connections dialed here. Never for this
  MC's own web, cluster or distribution ports, whatever a tab names. It stops,
  and with it every connection it dialed, when the last such tab closes or
  navigates away, or the listener goes.
  """

  use GenServer, restart: :temporary

  alias HalC2.PreviewForward.Pipe

  def start_link({thread, port, owner}),
    do: GenServer.start_link(__MODULE__, {thread, port, owner})

  @doc "The ports a tab may never forward: this MC's own."
  def reserved do
    Enum.uniq([HalC2.Web.port(), HalC2.Cluster.dist_port(), HalC2.Cluster.Epmd.listen_port()])
  end

  @impl true
  def init({thread, port, owner}) do
    Process.flag(:trap_exit, true)

    if port in reserved() do
      {:stop, {:shutdown, :reserved}}
    else
      # Subscribed before the first look, so no change slips between them.
      :ok = HalC2.Preview.subscribe(self())
      state = %{thread: thread, port: port, owner: Process.monitor(owner)}

      if named?(state),
        do: {:ok, Map.put(state, :preview, Process.monitor(HalC2.Preview))},
        else: {:stop, {:shutdown, :not_open}}
    end
  end

  @impl true
  def handle_call({:dial, peer}, _from, state) do
    {:ok, pipe} = Pipe.start_link({:dial, state.port, peer})
    {:reply, {:ok, pipe}, state}
  end

  @impl true
  def handle_info({:hal_c2_preview, _mc, %{"threadId" => thread}}, %{thread: thread} = state) do
    if named?(state), do: {:noreply, state}, else: {:stop, {:shutdown, :closed}, state}
  end

  def handle_info({:hal_c2_preview, _mc, _event}, state), do: {:noreply, state}

  # The listener, or the tabs themselves (they live in `HalC2.Preview`).
  def handle_info({:DOWN, _ref, :process, _, reason}, state),
    do: {:stop, {:shutdown, {:down, reason}}, state}

  # A connection ended; the others go on.
  def handle_info({:EXIT, _pipe, _reason}, state), do: {:noreply, state}

  defp named?(%{thread: thread, port: port}) do
    {:ok, %{"sessions" => tabs}} = HalC2.Preview.list(%{"threadId" => thread})
    Enum.any?(tabs, &HalC2.PreviewForward.loopback?(get_in(&1, ["navStatus", "url"]), port))
  end
end
