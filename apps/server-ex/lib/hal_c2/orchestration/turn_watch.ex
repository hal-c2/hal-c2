defmodule HalC2.Orchestration.TurnWatch do
  @moduledoc """
  Which process drives each running turn, so no turn outlives what drives it. The
  process that runs a turn claims it (`TurnWriter.started/1`) until
  `TurnWriter.finish/3`. If it crashes first, whatever the provider or plugin, the
  turn ends as failed from what the thread recorded (`TurnWriter.abandon/4`) and the
  thread's next message starts. A process that stops (`:normal`, `:shutdown`) leaves
  its turn alone: an MC shutting down settles its turns at boot
  (`HalC2.Orchestration.Recovery`), and a stop on a turn nothing drives ends it.
  """

  use GenServer

  require Logger

  alias HalC2.Orchestration.TurnWriter

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The calling process drives run `run_id` of `thread_id` until `release/1`. Returns
  once the claim is in place, so a stop that sees the run running sees it driven.
  """
  def claim(thread_id, run_id) do
    GenServer.call(__MODULE__, {:claim, self(), thread_id, run_id})
  catch
    :exit, _ -> :ok
  end

  @doc "Run `run_id` ended; its process no longer drives it."
  def release(run_id), do: GenServer.cast(__MODULE__, {:release, run_id})

  @doc """
  Whether a live process drives run `run_id`. An MC upgraded in place, where this
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
  def handle_cast({:release, run_id}, runs), do: {:noreply, forget(runs, run_id)}

  @impl true
  def handle_call({:claim, pid, thread_id, run_id}, _from, runs) do
    runs = forget(runs, run_id)
    {:reply, :ok, Map.put(runs, run_id, {Process.monitor(pid), pid, thread_id})}
  end

  # A process that has exited no longer drives its run, though its `:DOWN` may still
  # be queued behind this call.
  def handle_call({:driven?, run_id}, _from, runs) do
    case runs do
      %{^run_id => {_, pid, _}} -> {:reply, Process.alive?(pid), runs}
      _ -> {:reply, false, runs}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, runs) do
    case Enum.find(runs, fn {_run_id, {run_ref, _, _}} -> run_ref == ref end) do
      {run_id, {_, _, thread_id}} ->
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
