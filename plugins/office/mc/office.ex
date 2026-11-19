defmodule HalC2Plugins.Office do
  @moduledoc """
  The Office plugin's MC part: who is in the office, what each does and who talks to
  whom, published as the `office` topic (`HalC2Plugins.Office.Floor` says its shape)
  for the page to draw.

  It reads this MC's thread rows as it starts and hears each change to them
  (`Host.watch_threads/1`), and hears every turn's tool calls (`observe/2`), which it
  only casts to this process: the feed must not wait on it. What changed is published
  at most once a second, and only when the topic's value changed; a timer publishes
  when an idle thread or a talk grows too old to show. Nothing is kept on disk: a
  restart reads the rows again and forgets what each agent was last seen doing.
  """
  use GenServer
  @behaviour HalC2.Plugins.Extension

  alias HalC2.Plugins.Host
  alias HalC2Plugins.Office.Floor

  @id "office"
  @topic "office"
  @every_ms 1_000
  # The longest a timer is set for: Erlang's own limit is about 49 days, and one that
  # fires early only looks again.
  @longest_ms 86_400_000

  @impl HalC2.Plugins.Extension
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl HalC2.Plugins.Extension
  def settings_changed(pid, settings, _old), do: GenServer.call(pid, {:settings, settings})

  @impl HalC2.Plugins.Extension
  def validate_settings(settings) do
    cond do
      not count?(settings["maxPeople"]) ->
        {:error, "maxPeople: give a whole number, 1 or more."}

      not hours?(settings["idleHours"]) ->
        {:error, "idleHours: give a number of hours above 0, at most #{Floor.max_idle_hours()}."}

      true ->
        :ok
    end
  end

  defp count?(n), do: is_number(n) and n >= 1 and n == trunc(n)
  defp hours?(n), do: is_number(n) and n > 0 and n <= Floor.max_idle_hours()

  @impl HalC2.Plugins.Extension
  def call(@topic, _input, _context), do: {:ok, GenServer.call(__MODULE__, :view)}
  def call(method, _input, _context), do: {:error, "office has no method #{method}."}

  @impl HalC2.Plugins.Extension
  def observe(event, _context), do: GenServer.cast(__MODULE__, {:observe, event})

  @impl GenServer
  def init(settings) do
    # Watch first, then read: a change between the two comes again as a change.
    with {:ok, _relay} <- Host.watch_threads(@id),
         {:ok, rows} <- Host.threads(@id) do
      now = now()
      floor = settings |> Floor.new() |> Floor.load(rows, now)
      state = %{floor: floor, published: nil, published_at: nil, publish: nil, expire: nil}
      {:ok, publish(state)}
    else
      {:error, message} -> {:stop, message}
    end
  end

  @impl GenServer
  def handle_call(:view, _from, state), do: {:reply, Floor.view(state.floor, now()), state}

  def handle_call({:settings, settings}, _from, state),
    do: {:reply, :ok, changed(state, fn floor, _now -> Floor.settings(floor, settings) end)}

  @impl GenServer
  def handle_cast({:observe, event}, state),
    do: {:noreply, changed(state, &Floor.observe(&1, event, &2))}

  @impl GenServer
  def handle_info({:hal_c2_threads, rows}, state),
    do: {:noreply, changed(state, &Floor.rows(&1, rows, &2))}

  def handle_info(:publish, state), do: {:noreply, publish(%{state | publish: nil})}

  def handle_info(:expire, state),
    do: {:noreply, changed(%{state | expire: nil}, &Floor.expire/2)}

  def handle_info(_message, state), do: {:noreply, state}

  # The throttle reads one monotonic sample, so the wait it sets is never negative.
  defp changed(state, fun) do
    state = %{state | floor: fun.(state.floor, now())}
    clock = clock()

    cond do
      state.publish != nil ->
        state

      state.published_at == nil or clock - state.published_at >= @every_ms ->
        publish(state)

      true ->
        wait = state.published_at + @every_ms - clock
        %{state | publish: Process.send_after(self(), :publish, wait)}
    end
  end

  # Publishes the topic when it changed, and sets the timer for when it next changes on
  # its own. The throttle counts from every look, so the view is built at most once a
  # `@every_ms` however often the floor changes.
  defp publish(state) do
    now = now()
    view = Floor.view(state.floor, now)
    if view != state.published, do: Host.publish(@id, @topic, view)
    state = %{state | published: view, published_at: clock()}

    if state.expire, do: Process.cancel_timer(state.expire)

    expire =
      case Floor.next_change(state.floor, now) do
        nil -> nil
        at -> Process.send_after(self(), :expire, min(max(at - now, 0) + 1, @longest_ms))
      end

    %{state | expire: expire}
  end

  # Wall time, for the topic's times; `clock/0` paces publishing.
  defp now, do: System.system_time(:millisecond)
  defp clock, do: System.monotonic_time(:millisecond)
end
