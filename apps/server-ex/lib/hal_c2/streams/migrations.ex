defmodule HalC2.Streams.Migrations do
  @moduledoc """
  Takes turns for the streams migrating an older MC's long snapshot
  (`HalC2.Streams.Server`): one at a time, so the boot after an update reads one
  such snapshot at once, not every one a client opens. A turn ends when its process
  does.

  `migrate_all/0` opens every stream that still has one, oldest last, so each is
  migrated soon after boot rather than when a client first opens it.
  """

  use GenServer

  alias HalC2.{Store, StreamState, Streams}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Waits for the caller's turn. Without the service (a test that left it out), it is at once."
  @spec turn() :: :ok
  def turn do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :turn, :infinity)
    end
  end

  @doc "Migrates, one at a time, the streams an older MC left a long snapshot of."
  @spec migrate_all() :: :ok
  def migrate_all do
    Process.flag(:priority, :low)

    for id <- Store.legacy_streams(Store.path(), StreamState.max_legacy()) do
      Streams.with_server(id, &Streams.Server.await_cold/1)
    end

    :ok
  end

  @impl true
  def init(:ok), do: {:ok, %{holder: nil, queue: :queue.new()}}

  @impl true
  def handle_call(:turn, {pid, _}, %{holder: nil} = state),
    do: {:reply, :ok, %{state | holder: {pid, Process.monitor(pid)}}}

  def handle_call(:turn, from, state),
    do: {:noreply, %{state | queue: :queue.in(from, state.queue)}}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder: {_, ref}} = state),
    do: {:noreply, next(%{state | holder: nil})}

  # One that died while it waited.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {pid, _} = from}, queue} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          %{state | holder: {pid, Process.monitor(pid)}, queue: queue}
        else
          next(%{state | queue: queue})
        end
    end
  end
end
