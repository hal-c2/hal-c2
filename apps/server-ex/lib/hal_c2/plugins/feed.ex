defmodule HalC2.Plugins.Feed do
  @moduledoc """
  The process a running extension hears turns in (`HalC2.Plugins.observe/1`) and the
  entries that find it, in `HalC2.Plugins.Hooks`: `{:observe, id}` when the extension
  exports `observe/2`, `{:shape, id}` when it exports `shape_run/2`. It runs under the
  plugin's supervisor, so stopping or replacing the run ends it and its entries.

  Senders never wait for it. A turn's events come from the process driving the turn, so
  they arrive in its order; one that finds `@max_queue` events already waiting is
  dropped and counted, and the next event delivered says how many were (`"dropped"`).
  Whether the plugin may hear turns is checked here, as each event is delivered, so a
  permission revoked while the plugin runs takes effect at once.
  """

  use GenServer

  require Logger

  @hooks HalC2.Plugins.Hooks
  @max_queue 1_000

  @doc "The most events a feed holds before senders drop theirs."
  def max_queue, do: @max_queue

  @doc false
  def child_spec({id, module, settings}),
    do: %{id: :feed, start: {__MODULE__, :start_link, [{id, module, settings}]}}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Whether `module` has hooks a feed serves."
  def hooks?(module),
    do: function_exported?(module, :observe, 2) or function_exported?(module, :shape_run, 2)

  @doc "Hands the feed the settings the user saved, for the hooks it serves from now on."
  def settings_changed(pid, settings), do: GenServer.cast(pid, {:settings, settings})

  @doc """
  `{pid, value}` of every feed registered for `hook` (`:observe` or `:shape`). None when
  the plugin host is not running.
  """
  def lookup(hook) do
    Registry.select(@hooks, [{{{hook, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  @impl true
  def init({id, module, settings}) do
    Logger.metadata(plugin: id)
    dropped = :counters.new(1, [:write_concurrency])

    if function_exported?(module, :observe, 2),
      do: {:ok, _} = Registry.register(@hooks, {:observe, id}, %{id: id, dropped: dropped})

    if function_exported?(module, :shape_run, 2),
      do:
        {:ok, _} =
          Registry.register(@hooks, {:shape, id}, %{id: id, module: module, settings: settings})

    {:ok, %{id: id, module: module, settings: settings, dropped: dropped}}
  end

  @impl true
  def handle_cast({:settings, settings}, state) do
    if function_exported?(state.module, :shape_run, 2),
      do: Registry.update_value(@hooks, {:shape, state.id}, &%{&1 | settings: settings})

    {:noreply, %{state | settings: settings}}
  end

  @impl true
  def handle_info({:observe, event}, state) do
    if "turns:observe" in HalC2.Plugins.granted(state.id) do
      event =
        case :counters.get(state.dropped, 1) do
          0 ->
            event

          missed ->
            :counters.sub(state.dropped, 1, missed)
            Map.put(event, "dropped", missed)
        end

      context = %{id: state.id, settings: state.settings, thread_id: event["threadId"]}

      try do
        state.module.observe(event, context)
      rescue
        e ->
          Logger.warning(
            "plugin #{state.id} failed observing #{event["type"]}: #{Exception.message(e)}"
          )
      catch
        kind, reason ->
          Logger.warning(
            "plugin #{state.id} failed observing #{event["type"]}: #{inspect({kind, reason})}"
          )
      end
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
