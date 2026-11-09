defmodule HalC2.Orchestration.TurnWatch do
  @moduledoc """
  Which process drives each running turn, so no turn outlives what drives it. The
  process that runs a turn claims it (`TurnWriter.started/1`) until
  `TurnWriter.finish/3`. If it crashes first, whatever the provider or plugin, the
  turn ends as failed from what the thread recorded (`TurnWriter.abandon/4`) and the
  thread's next message starts. A process that stops (`:normal`, `:shutdown`) leaves
  its turn alone: an MC shutting down settles its turns at boot
  (`HalC2.Orchestration.Recovery`), and a stop on a turn nothing drives ends it. So
  does a process killed while the MC stops, as one stuck in a call to its provider is
  at its shutdown limit: this outlives the runtimes, and a failed run is one boot
  recovery would skip, leaving a steer it cut off pending.

  An end the store could not record (a full disk) waits here, in memory, and is tried
  again until the store takes it, with the time the run failed
  (`unrecorded/3`): a provider runtime hands over the end of a turn whose events it
  could not record (`HalC2.Orchestration.Unrecorded`), and a crash's end is kept the
  same way. Until it is recorded the run reads as running and nothing else ends it,
  and the runtime stays watched: one that goes first took its app-server with it, so
  the work it kept running ends with the run, and a provider turn it could not stop
  reads as interrupted. One that goes while a try runs leaves that try's end short of
  what went with it: the try after ends that too, the run already recorded.
  An MC that stops first loses it: the next boot settles the run
  (`HalC2.Orchestration.Recovery`), with its own time.
  """

  use GenServer

  require Logger

  alias HalC2.Orchestration.Entities
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

  @doc """
  Run `run_id` of `thread_id` failed with an end the store did not record: `at`, when
  it failed, and `failure`, why. `provider_turn` is how its provider turn ended:
  `:pending` while the runtime still drives it to an end (the run is not recorded
  until it says), a status, `"running"` for one the provider did not stop, or nil
  for the run's own status. `ended`, with how it ended, is the work the runtime ended,
  and `leftover`, a left-over provider turn's end it heard, as `{id, status}`
  (`TurnWriter.abandon/5`). Recorded once, as soon as the store takes it.
  """
  def unrecorded(thread_id, run_id, %{at: _, failure: _, provider_turn: _} = ending),
    do: GenServer.cast(__MODULE__, {:unrecorded, thread_id, run_id, ending})

  @doc """
  Waits for the next try at recording run `run_id`'s unrecorded end to fail, or for
  it to be recorded: `{:unrecorded, at}` or `{:recorded, at}`, `at` the time the run
  failed. One already failed answers at once. For tests.
  """
  def attempted(run_id, timeout \\ 5_000),
    do: GenServer.call(__MODULE__, {:attempted, run_id}, timeout)

  @impl true
  def init(nil), do: {:ok, %{claims: %{}, pending: %{}, waiters: %{}}}

  @impl true
  # A run whose end is held keeps its runtime watched until the end records
  # (`recorded/3`): the try that ends it releases it before its answer is heard, and a
  # runtime that goes in between takes its work with it.
  def handle_cast({:release, run_id}, state) do
    if Map.has_key?(state.pending, run_id),
      do: {:noreply, state},
      else: {:noreply, forget(state, run_id)}
  end

  def handle_cast({:unrecorded, thread_id, run_id, ending}, state) do
    ending =
      state.pending
      |> Map.get(run_id, %{thread: thread_id, failures: 0, trying: false})
      # The first `at` and `failure` stand; how the provider turn ended comes later.
      |> Map.merge(Map.take(ending, [:provider_turn, :ended, :leftover]))
      |> Map.put_new(:at, ending.at)
      |> Map.put_new(:failure, ending.failure)

    {:noreply, try_record(put_in(state.pending[run_id], ending), run_id)}
  end

  @impl true
  def handle_call({:claim, pid, thread_id, run_id}, _from, state) do
    state = forget(state, run_id)
    {:reply, :ok, put_in(state.claims[run_id], {Process.monitor(pid), pid, thread_id})}
  end

  # A process that has exited no longer drives its run, though its `:DOWN` may still
  # be queued behind this call. A run whose end waits on the store is driven here.
  def handle_call({:driven?, run_id}, _from, state) do
    case state do
      %{pending: %{^run_id => _}} -> {:reply, true, state}
      %{claims: %{^run_id => {_, pid, _}}} -> {:reply, Process.alive?(pid), state}
      _ -> {:reply, false, state}
    end
  end

  def handle_call({:attempted, run_id}, from, state) do
    case state.pending do
      %{^run_id => %{failures: failures, at: at}} when failures > 0 ->
        {:reply, {:unrecorded, at}, state}

      _ ->
        {:noreply, update_in(state.waiters[run_id], &[from | &1 || []])}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.claims, fn {_run_id, {run_ref, _, _}} -> run_ref == ref end) do
      {run_id, {_, _, thread_id}} ->
        state = %{state | claims: Map.delete(state.claims, run_id)}

        # A runtime that went after the store failed its turn keeps that failure,
        # whatever it went by; its provider turn went with it, and so did the work
        # it kept running (`lost`).
        if (crashed?(reason) or Map.has_key?(state.pending, run_id)) and
             not HalC2.Orchestration.Recovery.stopping?() do
          Logger.warning("run #{run_id} lost its runtime: #{inspect(reason)}")

          ending =
            Map.get(state.pending, run_id, %{
              thread: thread_id,
              failures: 0,
              trying: false,
              at: Entities.now(),
              failure: "The provider's session ended unexpectedly."
            })
            |> gone()

          {:noreply, try_record(put_in(state.pending[run_id], ending), run_id)}
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:retry, run_id}, state), do: {:noreply, try_record(state, run_id)}

  def handle_info({:attempted, run_id, result}, state) do
    case {result, state.pending} do
      {:ok, %{^run_id => ending}} ->
        claim = state.claims[run_id]
        ending = if claim && lost?(elem(claim, 1)), do: gone(ending), else: ending

        # The runtime went while the try ran, its `:DOWN` heard or not: the work it
        # kept running went with it, which the next try ends, the run recorded.
        if ending[:lost] == true and ending[:tried_lost] != true,
          do:
            {:noreply,
             try_record(put_in(state.pending[run_id], %{ending | trying: false}), run_id)},
          else: {:noreply, recorded(state, run_id, ending)}

      {{:error, error}, %{^run_id => ending}} ->
        failures = ending.failures + 1
        Logger.warning("run #{run_id}'s end is not recorded yet (try #{failures}): #{error}")
        {waiters, state} = pop_in(state.waiters[run_id])
        for from <- waiters || [], do: GenServer.reply(from, {:unrecorded, ending.at})
        base = Application.get_env(:hal_c2, :unrecorded_retry_ms, 1_000)
        delay = min(base * Integer.pow(2, min(failures - 1, 10)), 30_000)
        Process.send_after(self(), {:retry, run_id}, delay)
        ending = %{ending | failures: failures, trying: false}
        {:noreply, put_in(state.pending[run_id], ending)}

      _ ->
        {:noreply, state}
    end
  end

  # An MC upgraded in place carries the claims alone.
  @impl true
  def code_change(_old, %{claims: _} = state, _extra), do: {:ok, state}
  def code_change(_old, claims, _extra), do: {:ok, %{claims: claims, pending: %{}, waiters: %{}}}

  defp recorded(state, run_id, ending) do
    {waiters, state} = pop_in(state.waiters[run_id])
    for from <- waiters || [], do: GenServer.reply(from, {:recorded, ending.at})
    forget(%{state | pending: Map.delete(state.pending, run_id)}, run_id)
  end

  # One try at a time, off this process: ending a run writes to the thread and starts
  # the next one. A run whose provider turn has not ended yet waits for it. What the
  # try took of its runtime (`tried_lost`) is kept for when it is answered.
  defp try_record(state, run_id) do
    case state.pending do
      %{^run_id => %{trying: false, provider_turn: provider_turn} = ending}
      when provider_turn != :pending ->
        watch = self()
        claim = state.claims[run_id]
        # A runtime that went before its `:DOWN` reached here went as one that had.
        ending = if claim && lost?(elem(claim, 1)), do: gone(ending), else: ending

        Task.start(fn ->
          result =
            try do
              TurnWriter.abandon(ending.thread, run_id, "failed", ending.failure,
                at: ending.at,
                provider_turn: ending.provider_turn,
                ended: ending[:ended],
                lost: ending[:lost],
                leftover: ending[:leftover]
              )

              :ok
            rescue
              error -> {:error, Exception.message(error)}
            catch
              kind, reason -> {:error, Exception.format(kind, reason)}
            end

          send(watch, {:attempted, run_id, result})
        end)

        put_in(
          state.pending[run_id],
          Map.merge(ending, %{trying: true, tried_lost: ending[:lost] == true})
        )

      _ ->
        state
    end
  end

  defp forget(state, run_id) do
    {claim, claims} = Map.pop(state.claims, run_id)
    if claim, do: Process.demonitor(elem(claim, 0), [:flush])
    %{state | claims: claims}
  end

  defp lost?(pid),
    do: not Process.alive?(pid) and not HalC2.Orchestration.Recovery.stopping?()

  # A run whose runtime went: its app-server went too, and the work it kept running.
  defp gone(ending),
    do: ending |> Map.update(:provider_turn, nil, &gone_turn/1) |> Map.put(:lost, true)

  # How a runtime's provider turn reads once the runtime went: as the run, if it had not
  # said; one it could not stop went with its app-server.
  defp gone_turn(:pending), do: nil
  defp gone_turn("running"), do: "interrupted"
  defp gone_turn(provider_turn), do: provider_turn

  defp crashed?(reason),
    do: not (reason in [:normal, :shutdown] or match?({:shutdown, _}, reason))
end
