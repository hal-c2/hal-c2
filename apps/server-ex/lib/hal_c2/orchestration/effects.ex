defmodule HalC2.Orchestration.Effects do
  @moduledoc """
  The durable side effects of accepted commands: starting, steering,
  interrupting and restarting provider turns, answering a provider's
  requests, detaching its session, rewinding its conversation, capturing
  checkpoints, cleaning up a deleted thread's terminals and attached files,
  continuing a thread after an update, and generating thread titles.

  Each effect is recorded before it runs (`effect:` rows in the store's meta
  table) and run by this worker: effects of one thread run in order on their
  lane — the provider lane, and a separate title lane so generating a title
  neither waits for nor delays the thread's provider work — while other
  threads proceed. A failing effect is tried five times in all, waiting
  100ms, then doubling, never more than 30s, and is then recorded as failed
  with its error. `run_now/5` effects answer their caller when they finish,
  which is how dispatch keeps its replies; `enqueue/4` effects run in the
  background.

  When the server process ends, unfinished work tied to the old provider
  process (a turn start, interrupt, steer or restart, an answer) is cancelled
  rather than run again: the provider it meant is gone. Work that is safe to
  repeat runs again from the start. A record that ran to done is deleted;
  failed and cancelled records are kept for diagnosis, newest hundred per
  thread and no older than a week, pruned at boot and dropped with their
  thread.

  Ported from upstream T3 Code's `orchestration-v2/EffectOutbox.ts` and
  `EffectWorker.ts` (see `features/mc/orchestration/commands.feature`).
  Handlers live in `HalC2.Orchestration.execute_effect/3`.
  """

  use GenServer

  alias HalC2.Orchestration.Entities

  @process_bound ~w(provider-turn.start provider-turn.interrupt provider-turn.steer
                    provider-turn.restart runtime-request.respond)
  @replay_safe ~w(provider-runtime.continue provider-session.detach
                  provider-thread.rollback checkpoint.capture terminal.cleanup
                  attachment.cleanup thread-title.generate)
  @process_ended "Cancelled because the server process ended before the effect completed."
  @max_attempts 5
  @base_delay_ms 100
  @max_delay_ms 30_000
  # How much of a thread's settled failure history a boot keeps.
  @kept_terminal 100
  @terminal_ttl_ms 7 * 24 * 60 * 60 * 1000

  @type result :: :ok | {:ok, term} | {:error, String.t()} | {:retry, String.t()}

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether an effect type is tied to the provider process that was running when it was recorded."
  def process_bound?(type), do: type in @process_bound

  @doc "The wait before try `attempt + 1`: 100ms doubling, capped at 30s."
  def delay(attempt), do: min(@base_delay_ms * 2 ** (attempt - 1), @max_delay_ms)

  @doc """
  Records an effect on `lane` and runs it in the background, answering its id.
  Without a worker (an MC started without one, as in unit tests) it runs in a
  task, unrecorded.
  """
  @spec enqueue(String.t(), String.t(), map, String.t()) :: {:ok, String.t()}
  def enqueue(thread_id, type, args, lane \\ "provider") do
    record = new_record(thread_id, type, args, lane)

    if Process.whereis(__MODULE__) do
      :ok = GenServer.call(__MODULE__, {:enqueue, record, nil, nil})
      {:ok, record["id"]}
    else
      Task.start(fn -> execute_inline(record, nil, @max_attempts) end)
      {:ok, record["id"]}
    end
  end

  @doc """
  Records an effect and waits for its outcome, the way a dispatch waits for
  the provider work it set going. `payload` is carried in memory only (a
  decided turn, say); the record keeps `args`, which is all a replay after a
  restart can rebuild from. An effect asked for from inside the same lane's
  running effect runs here instead of queueing behind itself.
  """
  @spec run_now(String.t(), String.t(), map, term, String.t()) :: result
  def run_now(thread_id, type, args, payload, lane \\ "provider") do
    record = new_record(thread_id, type, args, lane)

    cond do
      Process.get(:hal_c2_effect_key) == {thread_id, lane} ->
        execute_inline(record, payload, @max_attempts)

      Process.whereis(__MODULE__) ->
        GenServer.call(__MODULE__, {:run_now, record, payload}, :infinity)

      true ->
        execute_inline(record, payload, @max_attempts)
    end
  end

  @doc "Cancels an effect: a waiting one never runs, a running one stops and is not retried."
  @spec cancel(String.t()) :: :ok
  def cancel(effect_id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:cancel, effect_id}),
      else: :ok
  end

  @doc "Cancels a thread's unfinished effects of `type` for `run_id`, if any wait or run."
  @spec cancel_pending(String.t(), String.t(), String.t()) :: :ok
  def cancel_pending(thread_id, type, run_id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:cancel_matching, thread_id, type, run_id}),
      else: :ok
  end

  @doc "Cancels a thread's unfinished effects, except the kinds in `except`."
  @spec cancel_thread(String.t(), [String.t()]) :: :ok
  def cancel_thread(thread_id, except \\ []) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:cancel_thread, thread_id, except}),
      else: :ok
  end

  @doc "A thread's recorded effects, oldest first."
  @spec effects(String.t()) :: [map]
  def effects(thread_id) do
    HalC2.Store.path()
    |> HalC2.Store.metas("effect:#{thread_id}:")
    |> Map.values()
    |> Enum.map(&JSON.decode!/1)
    |> Enum.sort_by(& &1["createdAt"])
  end

  @doc "Waits until no effect waits or runs (on `thread_id`, or anywhere): a drain, not a sleep."
  @spec drain(String.t() | nil, timeout) :: :ok | {:error, :timeout}
  def drain(thread_id \\ nil, timeout \\ 10_000) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:drain, thread_id}, timeout)
    else
      :ok
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp new_record(thread_id, type, args, lane) do
    at = Entities.now()

    %{
      "id" => Entities.new_id("effect"),
      "threadId" => thread_id,
      "type" => type,
      "lane" => lane,
      "status" => "pending",
      "attempts" => 0,
      "delays" => [],
      "error" => nil,
      "args" => args,
      "createdAt" => at,
      "updatedAt" => at
    }
  end

  defp execute_inline(record, payload, attempts_left) do
    will_retry = attempts_left > 1

    case execute(record, payload, will_retry) do
      {:retry, _message} when will_retry ->
        Process.sleep(delay(@max_attempts - attempts_left + 1))
        execute_inline(record, payload, attempts_left - 1)

      {:retry, message} ->
        {:error, message}

      other ->
        other
    end
  end

  # Runs one try of an effect. A raise out of a handler is a failure like any
  # other, so a broken effect cannot take the worker down with it.
  defp execute(record, payload, will_retry) do
    hook(:execute, record)
    HalC2.Orchestration.execute_effect(record, payload, will_retry)
  catch
    kind, reason ->
      {:retry,
       if(is_exception(reason),
         do: Exception.message(reason),
         else: Exception.format(kind, reason)
       )}
  end

  # Tests pause an effect at a stage: `{module, function, args}`, called with
  # the stage and the effect record.
  defp hook(stage, record) do
    case Application.get_env(:hal_c2, :effects_hook) do
      {m, f, a} -> apply(m, f, a ++ [stage, record])
      nil -> :ok
    end
  end

  defp persist(record) do
    if Process.whereis(HalC2.Store) do
      HalC2.Store.put_meta(
        "effect:#{record["threadId"]}:#{record["id"]}",
        JSON.encode!(record)
      )
    end

    record
  end

  defp forget(record),
    do: HalC2.Store.delete_meta("effect:#{record["threadId"]}:#{record["id"]}")

  @doc "Deletes a thread's recorded effects, done or not: its history dies with it."
  @spec drop_thread(String.t()) :: :ok
  def drop_thread(thread_id) do
    if Process.whereis(HalC2.Store) do
      HalC2.Store.path()
      |> HalC2.Store.metas("effect:#{thread_id}:")
      |> Map.keys()
      |> Enum.each(&HalC2.Store.delete_meta/1)
    end

    :ok
  end

  ## Worker

  @impl true
  def init(nil) do
    # Effect processes are linked (see `start_effect/2`), so their exits
    # arrive as messages instead of taking the worker down with them.
    Process.flag(:trap_exit, true)
    {:ok, %{queues: %{}, running: %{}, effects: %{}, drains: []}, {:continue, :sweep}}
  end

  # What a lost server process left behind: work tied to its provider
  # processes is cancelled, work that is safe to repeat runs again, and what
  # finished in an earlier boot has served its purpose.
  @impl true
  def handle_continue(:sweep, state) do
    records =
      if Process.whereis(HalC2.Store) do
        HalC2.Store.path()
        |> HalC2.Store.metas("effect:")
        |> Map.values()
        |> Enum.map(&JSON.decode!/1)
        |> Enum.sort_by(& &1["createdAt"])
      else
        []
      end

    records = prune(records)

    state =
      Enum.reduce(records, state, fn record, state ->
        case record["status"] do
          "done" ->
            forget(record)
            state

          status when status in ["pending", "running"] ->
            if process_bound?(record["type"]) do
              persist(%{
                record
                | "status" => "cancelled",
                  "error" => @process_ended,
                  "updatedAt" => Entities.now()
              })

              state
            else
              record = %{record | "status" => "pending"}
              persist(record)
              enqueue_record(state, record, nil, nil)
            end

          _ ->
            state
        end
      end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:enqueue, record, payload, waiter}, _from, state) do
    persist(record)
    {:reply, :ok, enqueue_record(state, record, payload, waiter)}
  end

  def handle_call({:run_now, record, payload}, from, state) do
    persist(record)
    {:noreply, enqueue_record(state, record, payload, from)}
  end

  def handle_call({:cancel, effect_id}, {caller, _}, state),
    do: {:reply, :ok, cancel_effect(state, effect_id, caller)}

  def handle_call({:cancel_matching, thread_id, type, run_id}, {caller, _}, state) do
    ids =
      for {id, effect} <- state.effects,
          effect.record["threadId"] == thread_id and effect.record["type"] == type and
            effect.record["args"]["runId"] == run_id,
          do: id

    {:reply, :ok, Enum.reduce(ids, state, &cancel_effect(&2, &1, caller))}
  end

  def handle_call({:cancel_thread, thread_id, except}, {caller, _}, state) do
    ids =
      for {id, effect} <- state.effects,
          effect.record["threadId"] == thread_id and effect.record["type"] not in except,
          do: id

    {:reply, :ok, Enum.reduce(ids, state, &cancel_effect(&2, &1, caller))}
  end

  def handle_call({:drain, thread_id}, from, state) do
    if drained?(state, thread_id),
      do: {:reply, :ok, state},
      else: {:noreply, %{state | drains: [{from, thread_id} | state.drains]}}
  end

  @impl true
  def handle_info({:effect_result, effect_id, result}, state) do
    case state.effects[effect_id] do
      nil -> {:noreply, state}
      effect -> {:noreply, settle(state, effect, result)}
    end
  end

  def handle_info({:retry, effect_id}, state) do
    case state.effects[effect_id] do
      nil -> {:noreply, state}
      effect -> {:noreply, start_effect(state, effect)}
    end
  end

  # A running effect's process ended without answering (killed from outside):
  # cancelled ones are already settled; others count as a failed try. The link
  # and the monitor both report it; whichever arrives second finds nothing.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, ended(state, Enum.find(state.effects, fn {_id, e} -> e.ref == ref end))}

  def handle_info({:EXIT, pid, _reason}, state),
    do: {:noreply, ended(state, Enum.find(state.effects, fn {_id, e} -> e.pid == pid end))}

  defp ended(state, nil), do: state

  defp ended(state, {_id, effect}),
    do: settle(state, %{effect | pid: nil, ref: nil}, {:retry, "the effect process ended"})

  # Settled failures are kept for diagnosis, not forever: the newest hundred
  # of a thread and none older than a week.
  defp prune(records) do
    cutoff = System.os_time(:millisecond) - @terminal_ttl_ms

    {terminal, live} =
      Enum.split_with(records, &(&1["status"] in ["failed", "cancelled"]))

    kept =
      terminal
      |> Enum.group_by(& &1["threadId"])
      |> Enum.flat_map(fn {_thread, rows} ->
        rows
        |> Enum.sort_by(& &1["updatedAt"], :desc)
        |> Enum.take(@kept_terminal)
        |> Enum.filter(&(updated_ms(&1) >= cutoff))
      end)

    for record <- terminal -- kept, do: forget(record)
    live ++ kept
  end

  defp updated_ms(%{"updatedAt" => iso}) do
    case DateTime.from_iso8601(to_string(iso || "")) do
      {:ok, at, _} -> DateTime.to_unix(at, :millisecond)
      _ -> 0
    end
  end

  defp enqueue_record(state, record, payload, waiter) do
    key = {record["threadId"], record["lane"]}
    effect = %{record: record, payload: payload, waiter: waiter, pid: nil, ref: nil}
    queue = :queue.in(record["id"], Map.get(state.queues, key, :queue.new()))

    %{state | queues: Map.put(state.queues, key, queue)}
    |> put_in([Access.key(:effects), record["id"]], effect)
    |> pump(key)
  end

  defp pump(state, key) do
    with nil <- state.running[key],
         {{:value, effect_id}, queue} <- :queue.out(Map.get(state.queues, key, :queue.new())),
         %{} = effect <- state.effects[effect_id] do
      %{
        state
        | queues: Map.put(state.queues, key, queue),
          running: Map.put(state.running, key, effect_id)
      }
      |> start_effect(effect)
    else
      _ -> state
    end
  end

  defp start_effect(state, effect) do
    record =
      persist(%{
        effect.record
        | "status" => "running",
          "attempts" => effect.record["attempts"] + 1,
          "updatedAt" => Entities.now()
      })

    will_retry = record["attempts"] < @max_attempts
    worker = self()
    key = {record["threadId"], record["lane"]}
    payload = effect.payload

    # Linked, so an effect dies with its worker instead of outliving a
    # restart that would sweep its record as if it had ended; monitored, so
    # its own end is reported whichever way it goes.
    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          Process.put(:hal_c2_effect_key, key)
          send(worker, {:effect_result, record["id"], execute(record, payload, will_retry)})
        end,
        [:link, :monitor]
      )

    effect = %{effect | record: record, pid: pid, ref: ref}
    put_in(state, [Access.key(:effects), record["id"]], effect)
  end

  defp settle(state, effect, result) do
    record = effect.record
    key = {record["threadId"], record["lane"]}
    attempts = record["attempts"]

    case result do
      {:retry, message} when attempts < @max_attempts ->
        wait = delay(record["attempts"])

        record =
          persist(%{
            record
            | "status" => "pending",
              "delays" => record["delays"] ++ [wait],
              "error" => message,
              "updatedAt" => Entities.now()
          })

        Process.send_after(self(), {:retry, record["id"]}, wait)
        if effect.ref, do: Process.demonitor(effect.ref, [:flush])
        effect = %{effect | record: record, pid: nil, ref: nil}
        put_in(state, [Access.key(:effects), record["id"]], effect)

      {:retry, message} ->
        finish(state, effect, key, "failed", {:error, message}, message)

      {:error, message} ->
        finish(state, effect, key, "failed", {:error, message}, message)

      outcome ->
        finish(state, effect, key, "done", outcome, nil)
    end
  end

  defp finish(state, effect, key, status, reply, error) do
    record = %{
      effect.record
      | "status" => status,
        "error" => error,
        "updatedAt" => Entities.now()
    }

    # A failure stays on record for diagnosis (pruned at boot); what ran to
    # done has served its purpose and its row goes.
    if status == "done", do: forget(record), else: persist(record)

    if effect.ref, do: Process.demonitor(effect.ref, [:flush])
    if effect.waiter, do: GenServer.reply(effect.waiter, reply)

    state = %{
      state
      | running: Map.delete(state.running, key),
        effects: Map.delete(state.effects, record["id"])
    }

    state |> pump(key) |> answer_drains()
  end

  # An effect cancelling itself on its way out (a turn start that gave up and
  # abandoned its run) is not killed for it: its answer is simply dropped.
  defp cancel_effect(state, effect_id, caller) do
    case state.effects[effect_id] do
      nil ->
        state

      effect ->
        record = effect.record
        key = {record["threadId"], record["lane"]}

        if effect.pid != nil and effect.pid != caller, do: Process.exit(effect.pid, :kill)
        if effect.ref, do: Process.demonitor(effect.ref, [:flush])
        if effect.waiter, do: GenServer.reply(effect.waiter, {:error, "cancelled"})

        persist(%{record | "status" => "cancelled", "updatedAt" => Entities.now()})

        queue = :queue.filter(&(&1 != effect_id), Map.get(state.queues, key, :queue.new()))

        state = %{
          state
          | queues: Map.put(state.queues, key, queue),
            running:
              if(state.running[key] == effect_id,
                do: Map.delete(state.running, key),
                else: state.running
              ),
            effects: Map.delete(state.effects, effect_id)
        }

        state |> pump(key) |> answer_drains()
    end
  end

  defp drained?(state, nil), do: state.effects == %{}

  defp drained?(state, thread_id),
    do:
      not Enum.any?(state.effects, fn {_id, effect} -> effect.record["threadId"] == thread_id end)

  defp answer_drains(state) do
    {ready, waiting} =
      Enum.split_with(state.drains, fn {_from, thread_id} -> drained?(state, thread_id) end)

    for {from, _thread_id} <- ready, do: GenServer.reply(from, :ok)
    %{state | drains: waiting}
  end

  @doc false
  def replay_safe_types, do: @replay_safe
end
