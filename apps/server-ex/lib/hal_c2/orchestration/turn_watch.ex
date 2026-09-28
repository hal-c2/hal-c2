defmodule HalC2.Orchestration.TurnWatch do
  @moduledoc """
  Which process drives each running turn, so no turn outlives what drives it. The
  process that runs a turn claims it (`TurnWriter.started/1`) until
  `TurnWriter.finish/3`. If it crashes first, whatever the provider or plugin, the
  turn ends as failed from what the thread recorded (`TurnWriter.abandon/4`) and the
  thread's next message starts. A process that stops (`:normal`, `:shutdown`) leaves
  its turn alone: a node shutting down settles its turns at boot
  (`HalC2.Orchestration.Recovery`), and a stop on a turn nothing drives ends it.
  """

  use GenServer

  require Logger

  alias HalC2.Orchestration.TurnWriter

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The calling process drives run `run_id` of `thread_id` until `release/1`."
  def claim(thread_id, run_id),
    do: GenServer.cast(__MODULE__, {:claim, self(), thread_id, run_id})

  @doc "Run `run_id` ended; its process no longer drives it."
  def release(run_id), do: GenServer.cast(__MODULE__, {:release, run_id})

  @doc """
  Whether a live process drives run `run_id`. A node upgraded in place, where this
  process has not started yet, assumes one does.
  """
  def driven?(run_id) do
    GenServer.call(__MODULE__, {:driven?, run_id})
  catch
    :exit, _ -> true
  end

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_cast({:claim, pid, thread_id, run_id}, runs) do
    runs = forget(runs, run_id)
    {:noreply, Map.put(runs, run_id, {Process.monitor(pid), thread_id})}
  end

  def handle_cast({:release, run_id}, runs), do: {:noreply, forget(runs, run_id)}

  @impl true
  def handle_call({:driven?, run_id}, _from, runs), do: {:reply, Map.has_key?(runs, run_id), runs}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, runs) do
    case Enum.find(runs, fn {_run_id, {run_ref, _}} -> run_ref == ref end) do
      {run_id, {_, thread_id}} ->
        if crashed?(reason) do
          Logger.warning("run #{run_id} lost its runtime: #{inspect(reason)}")

          # Off this process: ending a run writes to the thread and starts the next one.
          Task.start(fn ->
            TurnWriter.abandon(
              thread_id,
              run_id,
              "failed",
              "The provider's session ended unexpectedly."
            )
          end)
        end

        {:noreply, Map.delete(runs, run_id)}

      nil ->
        {:noreply, runs}
    end
  end

  defp forget(runs, run_id) do
    {claim, runs} = Map.pop(runs, run_id)
    if claim, do: Process.demonitor(elem(claim, 0), [:flush])
    runs
  end

  defp crashed?(reason),
    do: not (reason in [:normal, :shutdown] or match?({:shutdown, _}, reason))
end
