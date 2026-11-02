defmodule HalC2.Space.Presence do
  @moduledoc """
  Who has a page open right now (the `spacePresence` shape). Nothing here is stored: it
  lives as long as the connections and turns it describes, so a restart forgets it.

  Subscribing is what puts a client on the page. The socket names its device, since only
  its own MC knows its session, and leaves by unsubscribing or by exiting, which the
  monitor (`HalC2.Watchers`) sees at once; a connection that dies silently goes when the
  socket's idle timeout ends it, with no traffic beyond the pings clients already send.

  Agents have no connection. One is on the page it last read or wrote, until it touches
  another, its turn ends (`agent_done/1`), or `@agent_idle` passes without a touch.

  Watchers get `{:hal_c2_space_presence, space, page, view}` only when that page's view
  changes, `view` being `%{devices: [device], agents: [agent]}` with every device; each
  socket leaves itself out of what it sends on.
  """

  use GenServer

  alias HalC2.Watchers

  # Long enough for an agent to think between two edits of a page.
  @agent_idle :timer.minutes(2)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Puts `pid` on a page as `device` (`%{key:, label:}`) under `ref`; returns the page's view.
  """
  def subscribe(pid, space, page, device, ref \\ nil),
    do: GenServer.call(__MODULE__, {:subscribe, pid, {space, page}, device, ref})

  def unsubscribe(pid, space, page, _device, ref \\ nil),
    do: GenServer.cast(__MODULE__, {:unsubscribe, pid, {space, page}, ref})

  @doc "The agent of `thread_id`, called `title`, read or wrote this page."
  def agent_touched(thread_id, title, space, page),
    do: GenServer.cast(__MODULE__, {:agent_touched, thread_id, title, {space, page}})

  @doc "The agent of `thread_id` finished its turn."
  def agent_done(thread_id), do: GenServer.cast(__MODULE__, {:agent_gone, thread_id})

  @doc "What the viewers of a page look like now."
  def view(space, page), do: GenServer.call(__MODULE__, {:view, {space, page}})

  @impl true
  def init(nil), do: {:ok, %{pages: %{}, agents: %{}}}

  @impl true
  def handle_call({:subscribe, pid, key, device, ref}, _from, state) do
    # The subscriber has what it is told in the reply, so only the others hear of it.
    state =
      changing(
        state,
        key,
        fn state ->
          viewers = Map.get(state.pages, key, %{watchers: %{}, devices: %{}})

          viewers = %{
            watchers: Watchers.add(viewers.watchers, pid, ref),
            devices: Map.put(viewers.devices, pid, device)
          }

          put_in(state.pages[key], viewers)
        end,
        pid
      )

    {:reply, view_of(state, key), state}
  end

  def handle_call({:view, key}, _from, state), do: {:reply, view_of(state, key), state}

  @impl true
  def handle_cast({:unsubscribe, pid, key, ref}, state) do
    state =
      changing(state, key, fn state ->
        update_viewers(state, key, &Watchers.remove(&1, pid, ref), pid)
      end)

    {:noreply, state}
  end

  def handle_cast({:agent_touched, thread_id, title, key}, state) do
    {:noreply, agent_on(state, thread_id, title, key)}
  end

  def handle_cast({:agent_gone, thread_id}, state), do: {:noreply, agent_off(state, thread_id)}

  @impl true
  def handle_info({:agent_idle, thread_id, timer}, state) do
    case state.agents do
      %{^thread_id => %{timer: ^timer}} -> {:noreply, agent_off(state, thread_id)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    keys = for {key, %{devices: %{^pid => _}}} <- state.pages, do: key

    state =
      Enum.reduce(keys, state, fn key, state ->
        changing(state, key, fn state ->
          update_viewers(state, key, &Watchers.down(&1, monitor, pid), pid)
        end)
      end)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Tells the page's watchers, those `change` left but `except`, if it changed what they see.
  defp changing(state, key, change, except \\ nil) do
    before = view_of(state, key)
    state = change.(state)
    now = view_of(state, key)

    with true <- now != before,
         %{watchers: watchers} <- state.pages[key] do
      {space, page} = key
      Watchers.notify(Map.delete(watchers, except), {:hal_c2_space_presence, space, page, now})
    end

    state
  end

  # Changes a page's watchers; a pid with no subscription left is off the page.
  defp update_viewers(state, key, change, pid) do
    case state.pages do
      %{^key => viewers} ->
        watchers = change.(viewers.watchers)

        devices =
          if is_map_key(watchers, pid),
            do: viewers.devices,
            else: Map.delete(viewers.devices, pid)

        if watchers == %{},
          do: %{state | pages: Map.delete(state.pages, key)},
          else: put_in(state.pages[key], %{watchers: watchers, devices: devices})

      _ ->
        state
    end
  end

  defp agent_on(state, thread_id, title, key) do
    from = get_in(state.agents, [thread_id, :page])
    state = if from && from != key, do: agent_off(state, thread_id), else: state
    if timer = get_in(state.agents, [thread_id, :cancel]), do: Process.cancel_timer(timer)

    stamp = make_ref()
    cancel = Process.send_after(self(), {:agent_idle, thread_id, stamp}, agent_idle())
    agent = %{page: key, title: title, timer: stamp, cancel: cancel}

    changing(state, key, &put_in(&1.agents[thread_id], agent))
  end

  defp agent_off(state, thread_id) do
    case state.agents do
      %{^thread_id => %{page: key, cancel: cancel}} ->
        Process.cancel_timer(cancel)
        changing(state, key, &%{&1 | agents: Map.delete(&1.agents, thread_id)})

      _ ->
        state
    end
  end

  defp agent_idle, do: Application.get_env(:hal_c2, :presence_agent_idle, @agent_idle)

  # Devices by key and agents by thread, sorted, so an equal view compares equal.
  defp view_of(state, key) do
    devices =
      case state.pages do
        %{^key => %{devices: devices}} -> devices |> Map.values() |> Enum.uniq_by(& &1.key)
        _ -> []
      end

    agents =
      for {thread_id, %{page: ^key, title: title}} <- state.agents,
          do: %{thread_id: thread_id, title: title}

    %{devices: Enum.sort_by(devices, & &1.key), agents: Enum.sort_by(agents, & &1.thread_id)}
  end
end
