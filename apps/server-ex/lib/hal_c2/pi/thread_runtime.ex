defmodule HalC2.Pi.ThreadRuntime do
  @moduledoc """
  Runs one thread's turns on Pi's RPC mode (`pi --mode rpc`, `HalC2.Pi`) and writes
  them into the thread's log.

  One Pi process serves the thread while its access mode stays the same (HAL-C2's Pi
  extension reads the mode when Pi starts). The thread's native conversation is
  Pi's session file: a new process `switch_session`s to it, a rewind `fork`s it
  before the first dropped turn, and a forked thread starts from a copy made with
  `pi --fork`. A message is a `prompt` (HAL-C2's `$skill`s become Pi's `/skill:`
  commands, `/compact` is Pi's `compact`); Pi's events stream text, thinking,
  tools, retries and compactions into items, and `agent_settled` ends the turn
  with the session's entries (the turn's native ref, the conversation head) and
  its context usage. Extension dialogs are approvals (`confirm`) and questions
  (`select`, `input`, `editor`). Interrupt is `abort`.

  Work Pi starts by itself between turns (an extension waking it) is a "wake". A
  message sent while Pi is at that work takes it over: the work so far joins the
  message's turn, and the message goes in as a `followUp`, as does one Pi turns back
  for being busy.

  ## Wakes

  A wake (`state.wake`, `%{open, buffer, ids}`) is Pi's work by itself, from the
  `agent_start` no turn asked for to Pi's settle (`open` until then), kept as events
  (`buffer`, newest first) for a run to show. The runtime asks the thread for that run
  with a *delivery* (`deliver_wake/1`): a wake message whose id is its run's
  `turn.ids.message`. `ids` lists the deliveries still pending, sent or still trying,
  neither run nor refused; each could still bring a run for this wake.

  - A wake settled before its run came may never get one (the user can cancel it from
    the queue, which the runtime does not hear). Pi starting by itself again adds that
    work, less the old settle, to the same wake with a delivery of its own.
  - Pi exiting cuts an open wake short: an `:exited` mark closes its part so far, and
    a new Pi's work after it is the next part.
  - A run of a pending delivery takes the wake's oldest part, up to the first mark (and
    ends failed there) or all of it (and follows Pi to its settle), and its id leaves
    `ids`. A run of any other delivery shows nothing.
  - A user turn takes over an open wake's part after the last mark (`take_wake/1`);
    what is before it waits for its runs.
  - A refusal (`{:wake_refused, id}`, at any time, a turn running or not) drops `id`.
  - A run stopped before it started drops its part unseen, and stops Pi if that part
    is Pi's work in progress.

  The invariant: a wake with work in `buffer` has a nonempty `ids` naming only its
  pending deliveries. Once its last delivery is refused, or stopped work is given up,
  its work shows in no turn: a settled wake goes, and one Pi is still at keeps
  `buffer: nil, ids: []` to swallow Pi's events until its settle. A run that leaves a
  part and no delivery asks for another (`left_wake/2`).
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.JsonRpc.Connection
  alias HalC2.Subprocess.Durable
  alias HalC2.Orchestration
  alias HalC2.Orchestration.Entities

  @state_version 13
  # Extension failures queued between turns: only the newest are kept, so an
  # extension failing on a timer while idle cannot grow state without bound.
  @queued_extension_errors 20
  @registry HalC2.Pi.Registry

  # How long a call to Pi waits on its answer; the session's stats, read as a turn
  # settles, wait less, so a slow Pi does not hold the turn's end.
  @call_ms 60_000
  @stats_ms 2_000
  # Pi does not bound its answer to a steer, so the runtime gives it this long and
  # then takes it as taken (`steer_timeout/2`): a little over the 30s Codex gives a
  # steer, so one Pi is merely slow to answer is not cut off sooner than another
  # provider's would be.
  @steer_answer_ms 33_000
  # How long a turn may show no Pi activity at all before the runtime asks Pi
  # whether it is working (`turn_watchdog/2`): a prompt an extension command
  # handled without the agent never settles, and a Pi gone silent never does
  # either. Three failed checks in a row stop the session.
  @turn_watchdog_ms 4_000
  @turn_watchdog_failures 3
  # Idle checks in a row that settle a turn. A command of an extension's,
  # which Pi may handle without its agent, settles after two; anything else
  # only after about a minute, since Pi also reads idle while its extensions'
  # `input` and `before_agent_start` hooks (or a provider's auth refresh) run
  # before its agent starts, and a prompt template or `/skill:` expands into
  # an agent prompt that runs those hooks too.
  @turn_idle_command 2
  @turn_idle_message 15
  # The grace a stopped compaction gets to end on the abort before Pi is
  # restarted: `abort` does not stop a compaction, so a turn stopped while
  # Pi compacts would otherwise never end (`compact_restart/1`).
  @compact_restart_ms 2_000

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 120_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, run_id) do
    case lookup(thread_id) do
      nil -> {:error, "no active Pi turn in this thread"}
      pid -> GenServer.call(pid, {:interrupt, run_id}, 15_000)
    end
  end

  @doc """
  A `prompt` with `streamingBehavior: "steer"`, built from `%{text, attachments}`
  like a turn's: Pi delivers it before the running turn's next model call, or
  starts a run if the turn settled meanwhile. Either way the turn ends at the
  `agent_settled` after Pi's answer to the steer, so new work it started is the turn's.
  Returns once Pi answered: its refusal is the error. A refusal that ends the turn
  returns once the turn is recorded (`settle/1`), so the wait covers Pi's answer and that.
  A steer Pi has not answered in its answer budget is taken as taken: Pi still holds it,
  and may act on it, so the message is the turn's.

  The wait has no budget of its own. A refusal can be held behind steers sent
  after this one (`steered/3`), each with its own answer budget, and then
  behind the turn's settling, so no fixed caller timeout can outlast every
  staggered pair — one that expired would report a refused steer as taken.
  Every steer is eventually replied (answered, taken on its answer timer,
  released with the held refusals, or answered as the turn ends), and a
  runtime that stops surfaces as this call's exit, which the caller must treat
  as a refusal. That is why Pi alone does not steer through `HalC2.RuntimeSteer`:
  its answer timer, not a call timeout, says when Pi is taken to hold a steer.
  """
  @spec steer(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case lookup(thread_id) do
      nil -> {:error, "no active Pi turn in this thread"}
      pid -> GenServer.call(pid, {:steer, run_id, message}, :infinity)
    end
  end

  defp steer_answer_ms, do: Application.get_env(:hal_c2, :pi_steer_answer_ms, @steer_answer_ms)

  defp turn_watchdog_ms,
    do: Application.get_env(:hal_c2, :pi_turn_watchdog_ms, @turn_watchdog_ms)

  defp compact_restart_ms,
    do: Application.get_env(:hal_c2, :pi_compact_restart_ms, @compact_restart_ms)

  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case lookup(thread_id) do
      nil -> {:error, "No pending Pi extension request #{request_id}"}
      pid -> GenServer.call(pid, {:respond, request_id, response})
    end
  end

  @doc """
  Rewinds Pi's session: Pi forks it before the first dropped turn's user message,
  and the thread continues in the new session file.
  """
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, plan),
    do: thread_id |> ensure() |> GenServer.call({:rollback, plan}, 120_000)

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id, name: {:via, Registry, {@registry, thread_id}})

  defp lookup(thread_id) do
    with registry when registry != nil <- Process.whereis(@registry),
         [{pid, _}] <- Registry.lookup(@registry, thread_id) do
      pid
    else
      _ -> nil
    end
  end

  defp ensure(thread_id) do
    case DynamicSupervisor.start_child(HalC2.Plugins.sessions("acp"), {__MODULE__, thread_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # --- server ------------------------------------------------------------------

  @doc "Goes on with the program an earlier MC left running (`HalC2.Subprocess.Durable`)."
  def adopt(thread_id, survivor),
    do: GenServer.call(ensure(thread_id), {:adopt, survivor}, 30_000)

  @impl true
  def init(thread_id) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       conn: nil,
       instance: nil,
       mode: nil,
       # Pi's session file, the thread's native conversation.
       session: nil,
       model: nil,
       thinking: nil,
       # The model and thinking Pi itself starts the session with: what choosing
       # "Pi default" again restores.
       baseline_model: nil,
       baseline_thinking: nil,
       restore_thinking: false,
       # A thinking level the user chose for the thread, kept across a model
       # change Pi would otherwise answer with the new model's own level.
       user_thinking: nil,
       # The thread title last sent to Pi as its session name.
       session_name: nil,
       context_window: nil,
       # The session's last entry when the turn started: `get_entries` since it.
       leaf: nil,
       skills: [],
       # The names of the session's extension commands (from `get_commands`;
       # `nil` while unknown): only these settle quickly (`idle_checks/2`).
       extension_commands: nil,
       turn: nil,
       # A `/compact` runs as a call rather than a prompt. One steered into a
       # running turn also holds its caller until the compaction answers.
       compact: nil,
       compact_steer: nil,
       # The task refs of compactions Pi is still finishing after their turn
       # ended (`abort` does not stop one): while any is out, its late
       # `compaction_start`/`compaction_end` events are dropped. Only the
       # task's own reply or `:DOWN` forgets a ref — a dropped
       # `compaction_end` cannot say which compaction ended, and a compaction
       # can end without one (it fails, or sends no events), where the reply
       # is the only end it gets. Pi sends `compaction_end` before answering,
       # so by the reply nothing is left to drop.
       abandoned_compacts: MapSet.new(),
       items: %{},
       buffer: %{},
       flush_timer: nil,
       interrupted: false,
       # Whether Pi has shown any work for this turn yet; until it does, the
       # turn watchdog asks whether it is working at all (`turn_watchdog/2`).
       turn_active: false,
       # Whether Pi is compacting right now, between its compaction events:
       # a stop then restarts Pi once the grace runs out (`compact_restart/2`).
       compacting: false,
       # Pi takes no prompt while it compacts (it rejects one, steers included):
       # the turn's prompt and steers sent meanwhile wait here, the steers as
       # `{caller, steer}`, until the compaction ends (`release_held/1`). The
       # prompt is `:unsent`, or `:rejected` when Pi turned it back (its turn's
       # watchdog already runs).
       prompt_held: false,
       held_steers: [],
       failure: nil,
       message: 0,
       compactions: 0,
       # Extension failures Pi reported while no turn was running, shown on the next
       # turn (`event/3`), and how many this turn has shown so far.
       extension_errors: [],
       ext_errors: 0,
       retry: nil,
       live_tokens: nil,
       # Open dialogs: request id -> {:confirm, ui id, key} | {:question, ui id, native}.
       requests: %{},
       # Confirmations the user allowed for the session.
       allowed: MapSet.new(),
       # Steers Pi has not answered yet (`Connection.request/5`), labelled
       # `{caller, timer}` (`steer_timeout/2`), and whether Pi settled while one was out
       # and nothing it took has started since.
       steers: :gen_server.reqids_new(),
       settled: false,
       # Callers of steers Pi refused while that settle waits on other steers, or left
       # unanswered as it exited, with their answers: they hear once the turn ends, or
       # runs on (`steered/3`).
       refused: [],
       # Pi at work by itself between turns: `%{open, buffer, ids}` (see Wakes above).
       wake: nil
     }}
  end

  # A program an earlier MC left running: this runtime goes on from its checkpoint.
  @impl true
  def handle_call({:adopt, %{dir: dir, snapshot: snapshot}}, _from, state) do
    Process.flag(:trap_exit, true)

    with {:ok, conn} <-
           Connection.start_link(
             adopt: %{dir: dir, offset: snapshot.offset, channel: snapshot.channel},
             handler: self(),
             dialect: :pi,
             log: snapshot.state.thread_id,
             program: "pi"
           ),
         {:ok, restored} <- code_change(nil, snapshot.state, nil) do
      {:reply, :ok,
       Durable.restored(%{restored | steers: :gen_server.reqids_new()}, :conn, conn, snapshot)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  # The run of a wake: nothing is sent to Pi. The part of the wake it takes (Wakes,
  # above) is replayed into it, and it follows Pi to its settle.
  def handle_call({:start_turn, %{wake: true} = turn}, _from, state) do
    {part, left} = wake_part(state.wake, turn.ids.message)
    state = %{begin_turn(state, turn) | wake: nil, turn_active: true}

    case started(state) do
      :ok ->
        {:reply, :ok, state |> replay_wake(part) |> left_wake(left)}

      # The run ended before it started: its part shows in no turn, and Pi stops it
      # if it is still at it.
      :ended when part != nil and part.open ->
        if state.conn, do: Connection.notify(state.conn, "abort", %{})
        {:reply, :ok, %{state | turn: nil, wake: %{open: true, buffer: nil, ids: []}}}

      :ended ->
        {:reply, :ok, left_wake(%{state | turn: nil}, left)}
    end
  end

  def handle_call({:start_turn, turn}, _from, state) do
    conn = state.conn
    state = begin_turn(state, turn)
    turn = state.turn

    with {:ok, state} <- ensure_session(state, turn),
         {:ok, state} <- select_model(state, turn.model),
         {:ok, state} <- select_thinking(state, option(turn, "thinking")) do
      # A run that ended while the session opened never reaches Pi.
      case started(state) do
        :ok ->
          {state, took} = take_wake(state)

          # A new process ended the wake the turn took over: the message is Pi's next.
          turn =
            if took and state.conn == conn, do: Map.put(turn, :follow_up, :sent), else: turn

          state = %{state | turn: turn}

          {:reply, :ok,
           state |> sync_session_name() |> send_prompt(turn) |> show_extension_errors()}

        :ended ->
          {:reply, :ok, %{state | turn: nil}}
      end
    else
      {:error, reason, state} ->
        Logger.warning("pi turn failed to start: #{inspect(reason)}")
        finish(state, "failed", "Pi could not start: #{format(reason)}")
        # A Pi that could not finish setting up its session is not left running.
        {:reply, :ok, stop_session(%{state | turn: nil})}
    end
  end

  # IdleSessions' release: a runtime that took a turn since the thread looked idle keeps it.
  # It leaves the registry before it answers: the registry drops a dead runtime's key
  # only when it gets to its exit, so a lookup right after the release would find a pid
  # that is gone. `terminate/2` runs after that, with the key free: a turn may start a
  # new runtime meanwhile, so for a moment two run for the thread, and nothing in
  # `terminate/2` may count on having the thread to itself. Pi at work by itself (an
  # open wake) keeps it too; a settled wake whose run never came does not, and a run
  # that comes after all shows nothing.
  def handle_call(:release, _from, %{turn: nil, wake: wake} = state)
      when wake == nil or not wake.open do
    Registry.unregister(@registry, state.thread_id)
    {:stop, {:shutdown, :released}, :ok, state}
  end

  def handle_call(:release, _from, state), do: {:reply, :busy, state}

  # Pinned to a run, the interrupt stops only that run's turn: a different
  # turn that began since the caller read the run is not the caller's to stop.
  def handle_call({:interrupt, run_id}, _from, %{turn: %{ids: %{run: other}}} = state)
      when is_binary(run_id) and run_id != other,
      do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:interrupt, _run_id}, from, state), do: handle_call(:interrupt, from, state)

  # A turn whose prompt still waits on a compaction has not reached Pi: it
  # ends here, and its prompt is never sent.
  def handle_call(:interrupt, _from, %{turn: turn, prompt_held: held} = state)
      when turn != nil and held != false,
      do: {:reply, :ok, end_turn(%{state | interrupted: true}, "interrupted", nil)}

  def handle_call(:interrupt, _from, %{turn: turn} = state) when turn != nil do
    Connection.notify(state.conn, "abort", %{})
    # Steers still waiting on a compaction stay in the stopped turn, unsent.
    state = answer_held_steers(state, :ok)

    # `abort` does not stop a compaction: a turn that IS the compaction, one
    # Pi is compacting through, or one waiting behind an abandoned compaction
    # only ends once it ends. Give it the grace to stop, then restart Pi
    # (`handle_info` for `:compact_restart`).
    if compaction_out?(state) do
      Process.send_after(self(), {:compact_restart, turn.ids.run}, compact_restart_ms())
    end

    {:reply, :ok, %{cancel_requests(state) | interrupted: true}}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  # A `/compact` turn is not a prompt Pi can steer.
  # Its caller hears once Pi answered (`steered/3`).
  def handle_call({:steer, run_id, steer}, from, %{turn: turn, compact: nil} = state)
      when turn != nil and not state.interrupted and turn.ids.run == run_id do
    case compact_command(steer.text) do
      {:ok, params} ->
        # Steering with `/compact` compacts instead of prompting: it is not sent
        # to the model as a message. It runs as a task like a turn-level
        # `/compact`, so a long compaction neither blocks this runtime (Pi's
        # events, respond and interrupt keep moving) nor hits the call budget;
        # the caller hears when the task answers (`handle_info` for `compact`).
        conn = state.conn
        task = Task.async(fn -> Connection.call(conn, "compact", params, :infinity) end)
        {:noreply, %{state | compact: task.ref, compact_steer: from}}

      :error when state.compacting ->
        {:noreply, %{state | held_steers: state.held_steers ++ [{from, steer}]}}

      :error ->
        {:noreply, send_steer(state, from, steer)}
    end
  end

  def handle_call({:steer, _run_id, _message}, _from, state),
    do: {:reply, {:error, "Pi cannot be steered now"}, state}

  def handle_call({:rollback, _plan}, _from, %{turn: turn} = state) when turn != nil,
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:rollback, _plan}, _from, %{wake: %{open: true}} = state),
    do:
      {:reply,
       {:error,
        "Pi is still working on its own. Wait for it to finish, or stop it, before rewinding."},
       state}

  def handle_call({:rollback, plan}, _from, state) do
    entry = plan.first_dropped

    session = %{
      instance: plan.instance,
      runtime_mode: state.mode || "approval-required",
      cwd: plan.cwd,
      project_id: plan[:project_id],
      native_thread_id: plan.native_thread_id,
      thread_id: plan.thread_id
    }

    with true <- is_binary(entry) || {:error, "Pi has no native turn to rewind to.", state},
         {:ok, state} <- open(state, session),
         {:ok, forked} <- call(state, "fork", %{"entryId" => entry}),
         :ok <-
           if(is_map(forked) and forked["cancelled"] == true,
             do: {:error, "A Pi extension cancelled the session fork"},
             else: :ok
           ),
         {:ok, pi} <- call(state, "get_state", %{}),
         {:ok, entries} <- call(state, "get_entries", %{}) do
      file = pi["sessionFile"]
      head = entries["leafId"]
      # A settled wake's work is the discarded conversation's: its run shows none of it.
      state = %{state | session: file, leaf: head, wake: nil}

      {:reply,
       {:ok,
        %{
          "nativeThreadRef" => Entities.provider_ref(file, plan.driver),
          "nativeConversationHeadRef" => head && Entities.provider_ref(head, plan.driver)
        }}, state}
    else
      {:error, reason, state} -> {:reply, {:error, format(reason)}, state}
      {:error, reason} -> {:reply, {:error, format(reason)}, state}
    end
  end

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "No pending Pi extension request #{request_id}"}, state}

      {{:confirm, ui_id, key}, requests} ->
        decision = response["decision"] || "decline"

        reply =
          case decision do
            d when d in ["accept", "acceptForSession", "acceptAlways"] -> %{"confirmed" => true}
            "decline" -> %{"confirmed" => false}
            _ -> %{"cancelled" => true}
          end

        with :ok <- deliver_ui(state, ui_id, reply) do
          allowed =
            if decision in ["acceptForSession", "acceptAlways"],
              do: MapSet.put(state.allowed, key),
              else: state.allowed

          state = %{state | requests: requests, allowed: allowed}
          {:reply, :ok, resolve_request(state, request_id, decision)}
        else
          error -> {:reply, error, state}
        end

      {{:question, ui_id, native}, requests} ->
        value = if is_map(response["answers"]), do: answer(response["answers"][native])

        {reply, status} =
          if response["dismissed"] || value == nil,
            do: {%{"cancelled" => true}, "cancelled"},
            else: {%{"value" => value}, "resolved"}

        with :ok <- deliver_ui(state, ui_id, reply) do
          state = %{state | requests: requests}
          {:reply, :ok, resolve_request(state, request_id, response, status)}
        else
          error -> {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_info({:json_rpc, _conn, {:checkpoint, checkpoint}}, state),
    do: {:noreply, Durable.checkpoint(checkpoint, __MODULE__, state, &flush(&1, :timer))}

  def handle_info(:durable_save, state),
    do: {:noreply, Durable.save_due(state, &flush(&1, :timer))}

  # A `/compact` an earlier MC sent came back: its task went with that MC.
  def handle_info({:json_rpc, _conn, {:response_after_restart, "compact", reply}}, state) do
    if state.compact, do: send(self(), {state.compact, reply})
    {:noreply, state}
  end

  def handle_info({:json_rpc, _conn, {:response_after_restart, _method, _reply}}, state),
    do: {:noreply, state}

  @impl true
  def handle_info({:json_rpc, conn, {:notification, type, event}}, %{conn: conn} = state) do
    cond do
      # A compaction abandoned when its turn ended: Pi finishes it anyway,
      # and its events land in whatever turn runs then (or between turns).
      # They are that stopped turn's, so they are dropped while its task is
      # still out; only its reply or `:DOWN` forgets it (`forget_abandoned/2`).
      MapSet.size(state.abandoned_compacts) > 0 and
          type in ["compaction_start", "compaction_end"] ->
        {:noreply, state}

      state.turn ->
        # Anything but the prompt's own acknowledgement is Pi at work on the
        # turn; the watchdog only watches a turn that has shown none.
        state = if type == "response", do: state, else: %{state | turn_active: true}
        state = event(type, event, state)
        {:noreply, if(type == "compaction_end", do: release_held(state), else: state)}

      # A compaction between turns (an extension's, or Pi's own after a turn
      # settled) shows in no turn, but the next prompt waits for it.
      type in ["compaction_start", "compaction_end"] ->
        {:noreply, %{state | compacting: type == "compaction_start"}}

      # An extension that fails between turns is shown on the next turn.
      type == "extension_error" ->
        queued = Enum.take(state.extension_errors ++ [event], -@queued_extension_errors)
        {:noreply, %{state | extension_errors: queued}}

      state.wake != nil ->
        {:noreply, buffer_wake(state, type, event)}

      type == "agent_start" ->
        {:noreply, wake(state, type, event)}

      true ->
        {:noreply, state}
    end
  end

  # The thread would not run delivery `id` (Wakes, above), whether a turn runs or not.
  # Once none is left that could show the wake, its work shows in no turn. A refusal of
  # a delivery no wake waits on is nobody's.
  def handle_info({:wake_refused, id}, %{wake: %{ids: ids} = wake} = state) do
    cond do
      id not in ids ->
        {:noreply, state}

      ids == [id] ->
        {:noreply, %{state | wake: if(wake.open, do: %{wake | buffer: nil, ids: []})}}

      true ->
        {:noreply, %{state | wake: %{wake | ids: List.delete(ids, id)}}}
    end
  end

  def handle_info({:wake_refused, _id}, state), do: {:noreply, state}

  # A `/compact` came back. One steered into a running turn only answers its
  # caller; the turn runs on and settles as it would have (a settle Pi sent
  # meanwhile is owed, in `settled`). A turn-level one is the turn, so it settles.
  def handle_info({ref, result}, %{compact: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | compact: nil}

    case state.compact_steer do
      nil ->
        state =
          case result do
            {:error, reason} when not state.interrupted ->
              %{state | failure: compact_failure(reason)}

            _ ->
              state
          end

        {:noreply, settle(state)}

      from ->
        case result do
          {:ok, _} -> GenServer.reply(from, :ok)
          {:error, reason} -> GenServer.reply(from, {:error, compact_failure(reason)})
          _ -> GenServer.reply(from, {:error, "Pi compact failed."})
        end

        {:noreply, settle_held(%{state | compact_steer: nil})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{compact: ref} = state) do
    # The compaction task went away without its result (its result is flushed
    # in the clause above): treat as a failed compact so no caller waits.
    send(self(), {ref, {:error, "Pi compact failed."}})
    {:noreply, state}
  end

  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state) do
    # With a turn open, `end_turn/3` already answered every outstanding steer;
    # without one there should be none, but answer any left rather than drop them.
    # The MC ending Pi on the way down leaves the run for the next boot's recovery
    # (`HalC2.Orchestration.Recovery.stopping?/0`).
    state =
      if state.turn && not HalC2.Orchestration.Recovery.stopping?(),
        do:
          end_turn(
            state,
            "failed",
            if(state.interrupted,
              do: "Pi process was stopped.",
              else: "Pi process exited unexpectedly."
            )
          ),
        else: %{state | steers: unanswered(state.steers, "failed")}

    if state.compact_steer, do: GenServer.reply(state.compact_steer, {:error, "Pi exited"})

    {:noreply,
     %{
       state
       | conn: nil,
         wake: exited_wake(state.wake),
         compact: nil,
         compact_steer: nil,
         abandoned_compacts: MapSet.new(),
         compacting: false
     }}
  end

  def handle_info(:flush, state),
    do: {:noreply, Durable.flushed(state, flush(%{state | flush_timer: nil}, :timer))}

  def handle_info({:steer_timeout, from}, state), do: {:noreply, steer_timeout(state, from)}

  # A turn that has shown no work since its prompt: ask Pi whether it is
  # working. Idle checks in a row (`idle_checks/1`; at least two, so work Pi
  # sent while a check was out is read in between and counts as activity)
  # mean an extension handled the prompt without the agent, so the turn
  # settles; busy means work is on its way, so ask again later; three checks
  # Pi does not answer stop the session and fail it.
  def handle_info({:turn_watchdog, run, failures, idle}, state) when is_boolean(idle),
    do: handle_info({:turn_watchdog, run, failures, if(idle, do: 1, else: 0)}, state)

  def handle_info({:turn_watchdog, run, failures, idle}, state) do
    if state.turn && state.turn.ids.run == run && !state.turn_active && state.conn do
      {:noreply, turn_watchdog(state, run, failures, idle)}
    else
      {:noreply, state}
    end
  end

  # The grace after a stop while Pi compacted: if the stopped turn is still
  # open behind a compaction (Pi's abort does not stop one), end it and
  # restart Pi, so the thread takes its next message on a fresh process. A
  # turn that ended in the grace leaves Pi alone, and an abandoned
  # compaction with it, to finish in the background.
  def handle_info({:compact_restart, run}, state) do
    if state.turn && state.turn.ids.run == run && state.conn && compaction_out?(state),
      do: {:noreply, state |> end_turn("interrupted", nil) |> stop_session()},
      else: {:noreply, state}
  end

  def handle_info(message, state) do
    state = forget_abandoned(state, message)

    case :gen_server.check_response(message, state.steers, true) do
      {reply, {from, timer, steer}, steers} ->
        Process.cancel_timer(timer)
        {:noreply, steered(%{state | steers: steers}, from, reply, steer)}

      _ ->
        {:noreply, state}
    end
  end

  # An abandoned compaction's task answered, or died without answering: Pi
  # sends `compaction_end` before it answers the call and the Connection
  # delivers that notification before the task can forward the reply, so by
  # now its events have been dropped and nothing of it is still out. This is
  # also the only end a compaction that fails (or sends no events) ever gets.
  # A prompt Pi rejected while it finished one waits on that answer too.
  defp forget_abandoned(state, {ref, _result}) when is_reference(ref) do
    if MapSet.member?(state.abandoned_compacts, ref) do
      Process.demonitor(ref, [:flush])
      release_held(%{state | abandoned_compacts: MapSet.delete(state.abandoned_compacts, ref)})
    else
      state
    end
  end

  defp forget_abandoned(state, {:DOWN, ref, :process, _pid, _reason}) do
    if MapSet.member?(state.abandoned_compacts, ref),
      do:
        release_held(%{state | abandoned_compacts: MapSet.delete(state.abandoned_compacts, ref)}),
      else: state
  end

  defp forget_abandoned(state, _message), do: state

  defp turn_watchdog(state, run, failures, idle) do
    case pi_working(state) do
      {:ok, true} ->
        Process.send_after(self(), {:turn_watchdog, run, 0, 0}, turn_watchdog_ms())
        state

      {:ok, false} ->
        if idle + 1 >= idle_checks(state.turn, state.extension_commands) do
          settle(state)
        else
          Process.send_after(self(), {:turn_watchdog, run, 0, idle + 1}, turn_watchdog_ms())
          state
        end

      :error when failures + 1 >= @turn_watchdog_failures ->
        state |> end_turn("failed", "Pi stopped answering.") |> stop_session()

      :error ->
        Process.send_after(self(), {:turn_watchdog, run, failures + 1, 0}, turn_watchdog_ms())
        state
    end
  end

  defp idle_checks(%{text: "/" <> command}, extension_commands)
       when is_list(extension_commands) do
    [name | _] = String.split(command, [" ", "\n"], parts: 2)
    if name in extension_commands, do: @turn_idle_command, else: @turn_idle_message
  end

  defp idle_checks(_turn, _extension_commands), do: @turn_idle_message

  # Whether Pi is busy right now: streaming or compacting by its own
  # account, or finishing a compaction this runtime knows is still out. Pi
  # reports `isStreaming: false` while a prompt waits behind a compaction,
  # so that is work the turn queues behind, not idleness. A check Pi does
  # not answer (an error, a timeout, a dead connection) is a failed check.
  defp pi_working(state) do
    case Connection.call(state.conn, "get_state", %{}, @stats_ms) do
      {:ok, pi} when is_map(pi) ->
        {:ok, pi["isStreaming"] == true or pi["isCompacting"] == true or compaction_out?(state)}

      {:ok, _} ->
        {:ok, compaction_out?(state)}

      _ ->
        :error
    end
  catch
    :exit, _ -> :error
  end

  # Whether a compaction is still running in Pi as far as this runtime
  # knows: a `/compact` task out (the turn's or a steer's), one Pi started
  # in this turn and has not ended, or one a stopped turn abandoned.
  defp compaction_out?(state),
    do: state.compact != nil or state.compacting or MapSet.size(state.abandoned_compacts) > 0

  @impl true
  def terminate(_reason, state) do
    Durable.leaving(state, &flush(&1, :timer))
    if state.conn, do: Connection.stop(state.conn)
    :ok
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here.
  defp migrate(%{v: @state_version} = state), do: state

  defp migrate(%{v: 11} = state), do: state |> Map.merge(%{v: 12, wake: nil}) |> migrate()
  # A wake's deliveries were refs, which name nothing once the runtime is gone.
  defp migrate(%{v: 12} = state), do: state |> Map.merge(%{v: 13, wake: nil}) |> migrate()

  # Steers out at the upgrade are labelled with no steer: one Pi rejects is not resent.
  defp migrate(%{v: 10} = state) do
    steers =
      for {request, {from, timer}} <- :gen_server.reqids_to_list(state.steers),
          reduce: :gen_server.reqids_new(),
          do: (steers -> :gen_server.reqids_add(request, {from, timer, nil}, steers))

    state
    |> Map.merge(%{v: 11, steers: steers, prompt_held: false, held_steers: []})
    |> migrate()
  end

  defp migrate(%{v: 1} = state),
    do: state |> Map.merge(%{v: 2, steers: :gen_server.reqids_new(), settled: false}) |> migrate()

  defp migrate(%{v: 9} = state),
    do: state |> Map.merge(%{v: 10, extension_commands: nil}) |> migrate()

  defp migrate(%{v: 8} = state),
    do: state |> Map.merge(%{v: 9, compacting: false}) |> migrate()

  defp migrate(%{v: 7} = state),
    do: state |> Map.merge(%{v: 8, turn_active: false}) |> migrate()

  # A count of abandoned compactions becomes the set of their task refs; a
  # restored state's tasks went with the runtime that held them, so it starts empty.
  defp migrate(%{v: 6} = state),
    do: state |> Map.merge(%{v: 7, abandoned_compacts: MapSet.new()}) |> migrate()

  defp migrate(%{v: 5} = state),
    do: state |> Map.merge(%{v: 6, abandoned_compacts: 0}) |> migrate()

  defp migrate(%{v: 4} = state),
    do: state |> Map.merge(%{v: 5, compact_steer: nil}) |> migrate()

  defp migrate(%{v: 3} = state) do
    state
    |> Map.merge(%{
      v: 4,
      baseline_model: nil,
      baseline_thinking: nil,
      restore_thinking: false,
      user_thinking: nil,
      session_name: nil,
      extension_errors: [],
      ext_errors: 0
    })
    |> migrate()
  end

  # Steers out at the upgrade get their answer budget from now.
  defp migrate(%{v: 2} = state) do
    steers =
      for {request, from} <- :gen_server.reqids_to_list(state.steers),
          reduce: :gen_server.reqids_new() do
        steers ->
          timer = Process.send_after(self(), {:steer_timeout, from}, steer_answer_ms())
          :gen_server.reqids_add(request, {from, timer}, steers)
      end

    state |> Map.merge(%{v: 3, steers: steers, refused: []}) |> migrate()
  end

  # Stops the session's Pi process, leaving the runtime to open a fresh one.
  defp stop_session(state) do
    if state.conn, do: Connection.stop(state.conn)

    %{
      state
      | conn: nil,
        session: nil,
        model: nil,
        thinking: nil,
        baseline_model: nil,
        baseline_thinking: nil,
        session_name: nil,
        compact: nil,
        compact_steer: nil,
        abandoned_compacts: MapSet.new(),
        compacting: false
    }
  end

  # The thread's title becomes the Pi session's name, so Pi's own session list
  # shows it under that name. Best effort: naming never blocks a turn.
  defp sync_session_name(state) do
    title =
      HalC2.Streams.read(
        state.thread_id,
        &get_in(HalC2.StreamState.get(&1, "thread"), [state.thread_id, "title"])
      )

    if is_binary(title) and String.trim(title) != "" and title != state.session_name do
      case call(state, "set_session_name", %{"name" => title}) do
        {:ok, _} -> %{state | session_name: title}
        {:error, _} -> state
      end
    else
      state
    end
  end

  # --- session -------------------------------------------------------------------

  defp ensure_session(state, turn) do
    turn = Map.merge(turn, %{instance: Entities.instance(turn.ids), thread_id: state.thread_id})

    with {:ok, forked} <- fork_first(state, turn),
         {:ok, state} <- open(state, forked) do
      if state.session != turn.native_thread_id, do: record_session(state, state.session)
      {:ok, state}
    end
  end

  # A forked thread's first turn starts from a copy of the source's session, cut
  # before the turn after the fork point, made by a short-lived Pi of its own.
  defp fork_first(state, %{fork: %{thread: source} = fork} = turn) when is_binary(source) do
    with {:ok, argv, env} <-
           HalC2.Pi.launch(turn.instance, bare: true, extra: ["--fork", source])
           |> launch_error(state),
         {:ok, conn} <- connect(argv, env, turn.cwd, state) do
      try do
        with {:ok, before} <- before(conn, fork),
             {:ok, _} <- cut(conn, before),
             {:ok, %{"sessionFile" => file}} when is_binary(file) and file != source <-
               Connection.call(conn, "get_state", %{}) do
          {:ok, %{turn | native_thread_id: file}}
        else
          {:error, reason} -> {:error, reason, state}
          _ -> {:error, "Pi could not fork the session", state}
        end
      after
        Connection.stop(conn)
      end
    end
  end

  defp fork_first(_state, turn), do: {:ok, turn}

  # The turn after the fork point, where the copy is cut. A turn still running in the
  # source has no recorded entry yet, so it is found in the copy: the first message the
  # user sent after the session's last entry when the fork point settled. Messages
  # inside the fork point's own turn, steers among them, stay. A fork point recorded
  # before heads were looks after its own message instead. A copy that cannot be read
  # so is kept whole.
  defp before(_conn, %{before: before}) when is_binary(before), do: {:ok, before}
  defp before(conn, %{head: head}) when is_binary(head), do: first_user_since(conn, head)
  defp before(conn, %{turn: point}) when is_binary(point), do: first_user_since(conn, point)
  defp before(_conn, _fork), do: {:ok, nil}

  defp first_user_since(conn, entry) do
    case Connection.call(conn, "get_entries", %{"since" => entry}, @call_ms) do
      {:ok, %{"entries" => entries}} when is_list(entries) ->
        {:ok,
         Enum.find_value(entries, fn entry ->
           if get_in(entry, ["message", "role"]) == "user", do: entry["id"]
         end)}

      _ ->
        {:ok, nil}
    end
  end

  defp cut(_conn, nil), do: {:ok, nil}
  defp cut(conn, entry), do: Connection.call(conn, "fork", %{"entryId" => entry}, @call_ms)

  # HAL-C2's extension reads the access mode when Pi starts, so a new mode is a new Pi.
  defp open(%{conn: conn, instance: instance, mode: mode} = state, turn)
       when conn != nil and instance == turn.instance and mode == turn.runtime_mode do
    switch(state, turn.native_thread_id)
  end

  defp open(state, turn) do
    if state.conn, do: Connection.stop(state.conn)

    state = %{
      state
      | conn: nil,
        session: nil,
        model: nil,
        thinking: nil,
        baseline_model: nil,
        baseline_thinking: nil,
        session_name: nil
    }

    mcp = HalC2.Mcp.for_agent(turn.thread_id, turn.instance)

    with {:ok, argv, env} <-
           HalC2.Pi.launch(turn.instance, runtime_mode: turn.runtime_mode, mcp: mcp)
           |> launch_error(state),
         env = HalC2.ProjectEnvironment.for_turn(turn, env, argv),
         {:ok, conn} <- connect(argv, env, turn.cwd, state) do
      state = %{state | conn: conn, instance: turn.instance, mode: turn.runtime_mode}

      # The session's skills are given a few seconds: a Pi that cannot list them
      # in time does not hold up the thread, and the lookup is retried the first
      # time a message mentions a skill (`prompt_skills/2`). Unknown is `nil`.
      {skills, extension_commands} =
        case pi_call_within(conn, "get_commands", %{}, skills_ms()) do
          {:ok, data} -> {skill_names(data), HalC2.Pi.extension_commands(data)}
          _ -> {nil, nil}
        end

      state = %{state | skills: skills, extension_commands: extension_commands}
      switch(state, turn.native_thread_id)
    end
  end

  defp launch_error({:error, message}, state), do: {:error, message, state}
  defp launch_error(ok, _state), do: ok

  defp connect(argv, env, cwd, state) do
    case Connection.start_link(
           cmd: argv,
           handler: self(),
           cd: cwd,
           env: env,
           dialect: :pi,
           durable: state.thread_id,
           # A request open when Pi exits fails with Pi's exit code.
           program: "pi"
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Continues the thread's session file, or the new session Pi started with.
  defp switch(%{session: file} = state, file) when is_binary(file), do: {:ok, state}

  defp switch(state, file) do
    with {:ok, switched} <-
           if(is_binary(file),
             do: open_call(state, "switch_session", %{"sessionPath" => file}),
             else: {:ok, nil}
           ),
         :ok <- session_switch(switched),
         {:ok, pi} <- open_call(state, "get_state", %{}),
         :ok <- persisted(pi),
         {:ok, entries} <- open_call(state, "get_entries", %{}) do
      state =
        remember_model(
          %{
            state
            | session: pi["sessionFile"],
              leaf: entries["leafId"],
              thinking: pi["thinkingLevel"]
          },
          pi["model"]
        )

      # The first model and thinking Pi reports for this process are its own:
      # what "Pi default" means for the session.
      {:ok,
       if(state.baseline_model,
         do: state,
         else: %{state | baseline_model: state.model, baseline_thinking: state.thinking}
       )}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp session_switch(%{"cancelled" => true}),
    do: {:error, "A Pi extension cancelled the session switch"}

  defp session_switch(_switched), do: :ok

  # A session Pi does not keep in a file cannot be resumed, forked or rewound.
  defp persisted(%{"sessionFile" => file}) when is_binary(file) and file != "", do: :ok
  defp persisted(_pi), do: {:error, "get_state returned no persisted sessionFile"}

  defp remember_model(state, %{"provider" => provider, "id" => id} = model),
    do: %{state | model: "#{provider}/#{id}", context_window: positive(model["contextWindow"])}

  defp remember_model(state, _model), do: state

  defp call(state, type, params), do: Connection.call(state.conn, type, params, @call_ms)

  # A call that opens a session, bounded by the minute a reopening gets: Pi
  # not answering it in time means the session could not be opened (and the
  # failed start then stops that Pi, in `handle_call` for `:start_turn`).
  defp open_call(state, type, params) do
    case Connection.call(state.conn, type, params, open_ms()) do
      {:error, reason} ->
        {:error, "Pi RPC #{type} failed: #{reason |> format() |> String.trim_trailing(".")}."}

      reply ->
        reply
    end
  catch
    :exit, _ -> {:error, "Pi session could not be opened"}
  end

  defp open_ms, do: Application.get_env(:hal_c2, :pi_open_ms, @call_ms)

  # "Pi default" leaves the model to the user's own Pi settings: the model and
  # thinking this Pi process started the session with (the baseline).
  defp select_model(state, "default") do
    # Going back to Pi's own model drops a level chosen for another model.
    state = %{state | user_thinking: nil}

    cond do
      state.baseline_model == nil or state.model == state.baseline_model ->
        {:ok, %{state | restore_thinking: true}}

      true ->
        case set_model(state, state.baseline_model) do
          {:ok, state} -> {:ok, %{state | restore_thinking: true}}
          error -> error
        end
    end
  end

  defp select_model(state, model)
       when is_binary(model) and model != "" and model != state.model do
    set_model(state, model)
  end

  defp select_model(state, _model), do: {:ok, state}

  defp set_model(state, model) do
    with [provider, id] when provider != "" and id != "" <-
           String.split(model, "/", parts: 2),
         {:ok, _} <- call(state, "set_model", %{"provider" => provider, "modelId" => id}),
         {:ok, pi} <- call(state, "get_state", %{}) do
      # Pi applies the new model's own thinking level when the model changes;
      # remember what it now reports so a level the user chose is re-applied.
      {:ok, remember_model(%{state | model: model, thinking: pi["thinkingLevel"]}, pi["model"])}
    else
      {:error, reason} -> {:error, "could not select #{model}: #{format(reason)}", state}
      _ -> {:error, "Pi model '#{model}' must use provider/model format", state}
    end
  end

  defp select_thinking(state, level) when is_binary(level) and level != state.thinking do
    case call(state, "set_thinking_level", %{"level" => level}) do
      {:ok, _} -> {:ok, %{state | thinking: level, user_thinking: level, restore_thinking: false}}
      {:error, reason} -> {:error, "could not set thinking to #{level}: #{format(reason)}", state}
    end
  end

  # A level the user chose is remembered even when Pi already reports it.
  defp select_thinking(state, level) when is_binary(level) do
    {:ok, %{state | user_thinking: level, restore_thinking: false}}
  end

  # After a model change Pi reports the new model's own level; a level the user
  # chose for the thread is applied again over it.
  defp select_thinking(%{user_thinking: chosen} = state, level)
       when not is_binary(level) and is_binary(chosen) and chosen != state.thinking and
              not state.restore_thinking do
    case call(state, "set_thinking_level", %{"level" => chosen}) do
      {:ok, _} ->
        {:ok, %{state | thinking: chosen}}

      {:error, reason} ->
        {:error, "could not set thinking to #{chosen}: #{format(reason)}", state}
    end
  end

  # Choosing "Pi default" again with no level of the user's own restores Pi's
  # configured level instead of keeping the one a previous pick applied.
  defp select_thinking(%{restore_thinking: true, baseline_thinking: baseline} = state, level)
       when not is_binary(level) and is_binary(baseline) and baseline != state.thinking do
    case call(state, "set_thinking_level", %{"level" => baseline}) do
      {:ok, _} ->
        {:ok, %{state | thinking: baseline, restore_thinking: false}}

      {:error, reason} ->
        {:error, "could not set thinking to #{baseline}: #{format(reason)}", state}
    end
  end

  defp select_thinking(state, _level), do: {:ok, %{state | restore_thinking: false}}

  # The composer's options arrive as option id -> value (`Orchestration` turn fields).
  defp option(turn, id) do
    case (Map.get(turn, :options) || %{})[id] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp send_prompt(state, turn, watchdog? \\ true) do
    case compact_command(turn.text) do
      {:ok, params} ->
        conn = state.conn
        task = Task.async(fn -> Connection.call(conn, "compact", params, :infinity) end)
        %{state | compact: task.ref}

      :error when state.compacting ->
        %{state | prompt_held: :unsent}

      :error ->
        {state, payload} =
          prompt_payload(
            state,
            turn.text,
            Map.get(turn, :attachments, []),
            Map.get(turn, :history)
          )

        payload =
          if Map.get(turn, :follow_up),
            do: Map.put(payload, "streamingBehavior", "followUp"),
            else: payload

        Connection.notify(state.conn, "prompt", payload)

        if watchdog?,
          do: Process.send_after(self(), {:turn_watchdog, turn.ids.run, 0, 0}, turn_watchdog_ms())

        state
    end
  end

  defp send_steer(state, from, steer) do
    {state, payload} = prompt_payload(state, steer.text, steer.attachments)
    params = Map.put(payload, "streamingBehavior", "steer")
    timer = Process.send_after(self(), {:steer_timeout, from}, steer_answer_ms())
    steers = Connection.request(state.conn, "prompt", params, {from, timer, steer}, state.steers)
    %{state | steers: steers}
  end

  # Pi 1.4 rejects any prompt while it compacts. One that raced a compaction
  # Pi had already started waits for it like one sent knowing it ran.
  @compacting_rejection "Cannot submit a prompt while compaction is in progress"

  defp compaction_rejection?(reason) when is_binary(reason),
    do: String.starts_with?(reason, @compacting_rejection)

  defp compaction_rejection?(%{"message" => message}), do: compaction_rejection?(message)
  defp compaction_rejection?(_reason), do: false

  # Holds what the rejection turned back until the compaction ends. Pi sent
  # `compaction_start` before rejecting, so it is known here — unless it was
  # an abandoned compaction's (dropped), whose task's answer then releases it.
  defp hold_rejected(state) do
    if MapSet.size(state.abandoned_compacts) > 0,
      do: state,
      else: %{state | compacting: true}
  end

  # Once Pi is done compacting, the held prompt and steers go out, in the
  # order they were sent. A stopped turn's held steers were already answered.
  defp release_held(state) do
    if state.turn == nil or state.conn == nil or state.compacting or
         MapSet.size(state.abandoned_compacts) > 0 do
      state
    else
      state =
        if state.prompt_held,
          do:
            send_prompt(%{state | prompt_held: false}, state.turn, state.prompt_held == :unsent),
          else: state

      Enum.reduce(state.held_steers, %{state | held_steers: []}, fn {from, steer}, state ->
        send_steer(state, from, steer)
      end)
    end
  end

  defp answer_held_steers(state, answer) do
    for {from, _steer} <- state.held_steers, do: GenServer.reply(from, answer)
    %{state | held_steers: []}
  end

  # A `/compact` message (a message that only starts with it is an ordinary one),
  # as the params of Pi's `compact` command.
  defp compact_command(text) do
    case Regex.run(~r/^\/compact(?:\s+(.*))?$/s, String.trim(text || "")) do
      [_ | instructions] ->
        case instructions do
          [text] when text != "" -> {:ok, %{"customInstructions" => text}}
          _ -> {:ok, %{}}
        end

      nil ->
        :error
    end
  end

  defp compact_failure(reason) do
    case format(reason) do
      "" -> "Pi compact failed."
      "Pi request failed" -> "Pi compact failed."
      message -> message
    end
  end

  # The Pi `prompt` params for a message: HAL-C2's `$skill`s as Pi's own commands,
  # images Pi takes natively inline (still named by their saved path, so Pi can
  # read, copy or edit the file), every other file as the path it is saved at,
  # and a file whose saved copy cannot be found named as unavailable. An attachment's
  # `path` is the MC's own saved copy (`HalC2.Attachments`), never a client's path.
  # A turn's handoff (`history`) goes after its `/skill:` commands (`HalC2.Pi.message/3`).
  # Only the user's words are read for commands and `$skill` mentions, not the handoff.
  defp prompt_payload(state, text, attachments, history \\ nil) do
    said = HalC2.Pi.said(text, history)
    {state, skills} = state |> prompt_commands(said) |> prompt_skills(said)
    expanded = HalC2.Pi.message(text || "", history, skills)
    attachments = attachments || []

    images =
      for {mime, data} <- HalC2.Attachments.native_images(attachments),
          do: %{"type" => "image", "data" => data, "mimeType" => mime}

    lines =
      Enum.flat_map(attachments, fn attachment ->
        cond do
          is_binary(Map.get(attachment, :path)) ->
            ["[Attachment saved at #{attachment.path}]"]

          is_binary(Map.get(attachment, :name)) ->
            [~s([Attachment "#{attachment.name}" is unavailable])]

          true ->
            []
        end
      end)

    message = if lines == [], do: expanded, else: expanded <> "\n\n" <> Enum.join(lines, "\n")

    payload =
      if images == [],
        do: %{"message" => message},
        else: %{"message" => message, "images" => images}

    {state, payload}
  end

  # The session's skills, looked up again the first time a message mentions one
  # when the lookup at session start could not finish (`open/2`).
  defp prompt_skills(%{skills: nil} = state, text) do
    if is_binary(text) and String.contains?(text, "$") do
      case pi_call_within(state.conn, "get_commands", %{}, skills_ms()) do
        {:ok, data} ->
          skills = skill_names(data)
          commands = HalC2.Pi.extension_commands(data)
          {%{state | skills: skills, extension_commands: commands}, skills}

        _ ->
          {%{state | skills: []}, []}
      end
    else
      {state, []}
    end
  end

  defp prompt_skills(state, _text), do: {state, state.skills || []}

  # A session whose command lookup timed out at start knows no extension commands, so a
  # `/command` would wait out an ordinary message's idle checks: it looks them up again.
  defp prompt_commands(%{extension_commands: nil} = state, "/" <> _command) do
    case pi_call_within(state.conn, "get_commands", %{}, skills_ms()) do
      {:ok, data} ->
        %{
          state
          | skills: skill_names(data),
            extension_commands: HalC2.Pi.extension_commands(data)
        }

      _ ->
        %{state | extension_commands: []}
    end
  end

  defp prompt_commands(state, _text), do: state

  defp skill_names(data),
    do: data |> HalC2.Pi.parse_commands() |> elem(1) |> Enum.map(& &1["name"])

  defp skills_ms, do: Application.get_env(:hal_c2, :pi_skills_ms, 4_000)

  # A call to Pi given `ms` to answer, from a task so abandoning it does not take
  # the runtime with it. An answer that comes later is dropped by the connection.
  defp pi_call_within(conn, type, params, ms) do
    task = Task.async(fn -> Connection.call(conn, type, params, :infinity) end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :timeout}
    end
  end

  defp record_session(state, file) do
    ids = state.turn.ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "nativeThreadRef", Entities.provider_ref(file, ids.driver))
        )
      ]
    end)
  end

  # --- wakes ---------------------------------------------------------------------

  defp begin_turn(state, turn) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:#{turn.ids.driver}:#{turn.ids.run}")

    %{
      state
      | turn: %{turn | ids: ids},
        items: %{},
        interrupted: false,
        turn_active: false,
        failure: nil,
        message: 0,
        compactions: 0,
        ext_errors: 0,
        retry: nil,
        live_tokens: nil
    }
  end

  # Pi started work by itself: a wake of its own, whose run its delivery asks for.
  defp wake(state, type, event) do
    {state, id} = deliver_wake(state)
    %{state | wake: %{open: true, buffer: [{type, event}], ids: [id]}}
  end

  # Asks the thread for a run of the wake: a message from the agent, whose run
  # (`handle_call({:start_turn, %{wake: true}})`) queues behind any other and carries
  # the message's id. Off this process, since starting the run calls back into it.
  defp deliver_wake(state) do
    runtime = self()
    id = HalC2.Orchestration.Entities.new_id("message")

    HalC2.Orchestration.Wake.deliver(
      state.thread_id,
      %{
        "text" => "Pi continued on its own.",
        # Its run replays what Pi already sent rather than sending this.
        "providerWake" => true,
        "notification" => %{
          "source" => %{"kind" => "background_task"},
          "outcome" => "updated",
          "summary" => "Pi continued on its own"
        }
      },
      instance: state.instance,
      message_id: id,
      on_dropped: fn -> send(runtime, {:wake_refused, id}) end
    )

    {state, id}
  end

  # Pi at work by itself again after a wake that ended before its run came: the work
  # joins that wake, less its settle, with a delivery of its own.
  defp buffer_wake(%{wake: %{open: false} = earlier} = state, "agent_start", event) do
    kept = Enum.reject(earlier.buffer, &match?({"agent_settled", _}, &1))
    {state, id} = deliver_wake(state)

    %{
      state
      | wake: %{open: true, buffer: [{"agent_start", event} | kept], ids: [id | earlier.ids]}
    }
  end

  # Pi's settle ends the work; a wake the thread refused keeps nothing of it.
  defp buffer_wake(%{wake: %{buffer: nil}} = state, type, _event),
    do: if(type == "agent_settled", do: %{state | wake: nil}, else: state)

  defp buffer_wake(%{wake: wake} = state, type, event),
    do: %{
      state
      | wake: %{
          wake
          | open: wake.open and type != "agent_settled",
            buffer: [{type, event} | wake.buffer]
        }
    }

  # Pi exited: a wake it was at is cut short there; one with nothing for a run to show
  # is gone.
  defp exited_wake(%{open: true, buffer: [_ | _] = buffer} = wake),
    do: %{wake | open: false, buffer: [:exited | buffer]}

  defp exited_wake(%{buffer: [_ | _]} = wake), do: wake
  defp exited_wake(_wake), do: nil

  # The part of the wake delivery `id`'s run takes: `%{events, open, cut}`, the oldest
  # events up to the first `:exited` mark (`cut`) or all of them, or nil for a run no
  # wake waits on. Returns it with the wake left for the other deliveries, if any.
  defp wake_part(%{ids: ids, buffer: [_ | _] = buffer} = wake, id) do
    if id in ids do
      {events, rest} = buffer |> Enum.reverse() |> Enum.split_while(&(&1 != :exited))
      part = %{events: events, open: wake.open and rest == [], cut: rest != []}

      case rest do
        [:exited, _ | _] ->
          {part, %{wake | buffer: Enum.reverse(tl(rest)), ids: List.delete(ids, id)}}

        _ ->
          {part, nil}
      end
    else
      {nil, wake}
    end
  end

  defp wake_part(wake, _id), do: {nil, wake}

  # Puts back the wake a run left: one with work but no delivery left asks for another.
  defp left_wake(state, %{ids: [], buffer: [_ | _]} = wake) do
    {state, id} = deliver_wake(state)
    %{state | wake: %{wake | ids: [id]}}
  end

  defp left_wake(state, wake), do: %{state | wake: wake}

  # Shows the run's part of the wake (nothing, for a run no wake waits on): to its
  # settle, or to where Pi exited, which fails the run, or Pi is still at it.
  defp replay_wake(state, part) do
    part = part || %{events: [], open: false, cut: false}

    state =
      Enum.reduce(part.events, state, fn {type, event}, state ->
        if state.turn, do: event(type, event, state), else: state
      end)

    cond do
      state.turn == nil -> state
      part.cut -> end_turn(state, "failed", "Pi process exited unexpectedly.")
      part.open and state.conn != nil -> state
      true -> end_turn(state, "completed", nil)
    end
  end

  # A turn that starts while Pi is at work by itself takes the work over: what Pi did
  # so far joins the turn, and its message follows the work (`send_prompt/3`). Work Pi
  # did before an exit mark stays, with its deliveries, for its own run; with none, the
  # wake is gone, its runs show nothing, and work Pi starts by itself after the turn is
  # a wake of its own. A settled wake is left alone.
  defp take_wake(%{wake: %{open: true} = wake} = state) do
    {taken, cut} = Enum.split_while(wake.buffer || [], &(&1 != :exited))

    # What Pi did by itself is not Pi taking the prompt: it confirms no handoff.
    replaying = Map.merge(state, %{turn_active: true, replaying: true})

    state =
      taken
      |> Enum.reverse()
      |> Enum.reduce(replaying, fn {type, event}, state -> event(type, event, state) end)
      |> Map.delete(:replaying)

    {%{state | wake: if(cut != [], do: %{wake | open: false, buffer: cut})}, true}
  end

  defp take_wake(state), do: {state, false}

  defp busy_rejection?(reason) when is_binary(reason),
    do: String.contains?(String.downcase(reason), "already processing")

  defp busy_rejection?(%{"message" => message}), do: busy_rejection?(message)
  defp busy_rejection?(_reason), do: false

  # --- events --------------------------------------------------------------------

  # The prompt's acknowledgement: a refused prompt ends the turn.
  # The turn's prompt, turned back by a compaction: sent again once it ends, or
  # never, if the user stopped the turn meanwhile.
  defp event("response", %{"command" => "prompt", "success" => false} = event, state) do
    cond do
      # Pi is at work it started by itself, which HAL-C2 has not heard of yet: the
      # message waits for it to finish.
      busy_rejection?(event["error"]) and !Map.get(state.turn, :follow_up) and
          not state.interrupted ->
        turn = Map.put(state.turn, :follow_up, :sent)
        send_prompt(%{state | turn: turn}, turn, false)

      not compaction_rejection?(event["error"]) ->
        end_turn(state, "failed", detail(nonblank(event["error"]) || "Pi rejected the prompt."))

      state.interrupted ->
        end_turn(state, "interrupted", nil)

      true ->
        hold_rejected(%{state | prompt_held: :rejected})
    end
  end

  # Pi took a message that follows the work it was at.
  defp event(
         "response",
         %{"command" => "prompt", "success" => true},
         %{turn: %{follow_up: :sent}} = state
       ),
       do: put_in(state.turn.follow_up, :taken)

  defp event("message_start", %{"message" => %{"role" => "assistant"}}, state),
    do: %{state | message: state.message + 1}

  defp event("message_update", event, state) do
    state = live_usage(state, event["usage"] || get_in(event, ["message", "usage"]))

    case event["assistantMessageEvent"] do
      %{"type" => "text_delta", "delta" => delta} when is_binary(delta) ->
        native = "#{state.turn.ids.run}:message:#{state.message}"
        state |> ensure_item(native, :assistant) |> buffer(native, "text", delta)

      %{"type" => "thinking_delta", "delta" => delta} when is_binary(delta) ->
        native = "#{state.turn.ids.run}:thinking:#{state.message}"
        state |> ensure_item(native, :reasoning) |> buffer(native, "text", delta)

      _ ->
        state
    end
  end

  defp event("message_end", %{"message" => %{"stopReason" => "error"} = message}, state) do
    if state.failure,
      do: state,
      else: %{state | failure: model_failure(message["errorMessage"])}
  end

  # Pi aborted the turn itself (for an extension, a compaction or a session
  # replacement), not at the user's stop: the turn still reads as interrupted.
  defp event("message_end", %{"message" => %{"stopReason" => "aborted"}}, state),
    do: %{state | interrupted: true}

  defp event("tool_execution_start", %{"toolCallId" => id} = event, state) do
    {kind, fields} = tool_shape(event["toolName"], event["args"] || %{})
    state |> flush() |> ensure_item(tool_native(state, id), kind, fields)
  end

  # Pi's example subagent extension reports its tasks as the tool runs.
  defp event(
         "tool_execution_update",
         %{"toolCallId" => id, "toolName" => "subagent"} = event,
         state
       ) do
    state =
      if Map.has_key?(state.items, tool_native(state, id)),
        do: state,
        else: event("tool_execution_start", event, state)

    subagents(state, id, event["partialResult"], false)
  end

  defp event("tool_execution_end", %{"toolCallId" => id, "toolName" => "subagent"} = event, state) do
    state = tool_end(state, id, event)
    subagents(state, id, event["result"], true)
  end

  defp event("tool_execution_end", %{"toolCallId" => id} = event, state),
    do: tool_end(state, id, event)

  defp event("compaction_start", _event, state) do
    n = state.compactions + 1
    native = "compaction:#{state.turn.ids.provider_turn}:#{n}"

    state
    |> flush()
    |> Map.put(:compactions, n)
    |> Map.put(:compacting, true)
    |> ensure_item(native, :compaction, %{"driver" => "pi", "title" => "Compacting context..."})
  end

  defp event("compaction_end", event, state) do
    # An overflow can surface as a model error before Pi compacts and tries
    # again: that failure clears only when Pi says the compaction will retry.
    state = if event["willRetry"] == true, do: %{state | failure: nil}, else: state

    state =
      if Map.has_key?(
           state.items,
           "compaction:#{state.turn.ids.provider_turn}:#{state.compactions}"
         ),
         do: state,
         else: event("compaction_start", event, state)

    # Pi is done compacting, also when it started before this turn did.
    state = %{state | compacting: false}
    native = "compaction:#{state.turn.ids.provider_turn}:#{state.compactions}"
    result = if is_map(event["result"]), do: event["result"], else: %{}

    {status, title, summary} =
      cond do
        event["aborted"] == true ->
          {"cancelled", "Context compaction stopped", result["summary"]}

        # No result is a failed compaction; its reason, cut to 1,000 characters,
        # or a plain one when Pi gave none.
        is_binary(event["errorMessage"]) or not is_map(event["result"]) ->
          reason = nonblank(event["errorMessage"]) || "Pi context compaction failed."
          {"failed", "Context compaction failed", String.slice(reason, 0, 1_000)}

        true ->
          {"completed", "Context compacted", result["summary"]}
      end

    finish_item(state, native, status, fn entity ->
      entity
      |> Map.put("title", title)
      |> put_present("summary", summary)
      |> put_present("beforeTokenCount", result["tokensBefore"])
      |> put_present("afterTokenCount", result["estimatedTokensAfter"])
    end)
  end

  defp event("auto_retry_start", event, state) do
    attempt = max(1, event["attempt"] || 1)

    retry = %{
      "attempt" => attempt,
      "maxAttempts" => max(attempt, event["maxAttempts"] || attempt),
      "retryDelayMs" => max(0, event["delayMs"] || 0)
    }

    failure = provider_failure(event["errorMessage"] || "Pi provider request failed.", true)
    retry_item(state, "running", "Provider retry", failure, retry)
  end

  defp event("auto_retry_end", %{"success" => true} = event, state) do
    state = %{state | failure: nil}

    case state.retry do
      nil ->
        state

      %{failure: failure, retry: retry} ->
        retry = Map.put(retry, "attempt", event["attempt"] || retry["attempt"])
        retry_item(state, "completed", "Provider recovered", failure, retry)
    end
  end

  defp event("auto_retry_end", event, state) do
    message = event["finalError"] || "Pi auto-retry failed."
    attempt = max(1, event["attempt"] || 1)
    previous = (state.retry && state.retry.retry) || %{}

    retry = %{
      "attempt" => attempt,
      "maxAttempts" => previous["maxAttempts"] || attempt,
      "retryDelayMs" => previous["retryDelayMs"]
    }

    state = retry_item(state, "failed", "Provider error", provider_failure(message, false), retry)
    %{state | failure: message}
  end

  defp event("extension_error", event, state), do: extension_error(state, event)

  defp event("extension_ui_request", %{"id" => ui_id, "method" => method} = request, state) do
    dialog(method, ui_id, request, state)
  end

  # The work a turn took over settled before Pi took the message: Pi runs the message
  # next, as a run of its own, and the turn follows that.
  defp event("agent_settled", _event, %{turn: %{follow_up: :sent}} = state)
       when not state.interrupted,
       do: state

  # A settle while a steered compaction runs is owed until it answers.
  defp event("agent_settled", _event, %{compact_steer: from} = state) when from != nil,
    do: if(state.interrupted, do: settle(state), else: %{state | settled: true})

  # A steer Pi has not answered may have reached it after this settle, and start new
  # work: the turn waits for the answer (`steered/3`). An interrupted turn ends here.
  defp event("agent_settled", _event, %{compact: nil} = state) do
    if state.interrupted or
         (:gen_server.reqids_size(state.steers) == 0 and state.held_steers == []),
       do: settle(state),
       else: %{state | settled: true}
  end

  defp event(_type, _event, state), do: state

  defp tool_end(state, id, event) do
    native = tool_native(state, id)

    state =
      if Map.has_key?(state.items, native),
        do: state,
        else: event("tool_execution_start", event, state)

    %{kind: kind} = state.items[native]
    output = result_text(event["result"])
    images = if kind == :tool, do: tool_images(state.thread_id, event["result"]), else: []

    # A Stop aborts in-flight tools, and Pi reports those as error ends: they
    # read as interrupted, matching the run, rather than failed.
    status =
      cond do
        event["isError"] == true and state.interrupted -> "interrupted"
        event["isError"] == true -> "failed"
        true -> "completed"
      end

    finish_item(state, native, status, fn entity ->
      case kind do
        :command ->
          exit_code =
            get_in(event, ["result", "details", "exitCode"]) ||
              get_in(event, ["result", "exitCode"]) ||
              get_in(event, ["result", "structuredContent", "exitCode"])

          entity
          |> Map.put("output", output)
          |> then(&if(is_integer(exit_code), do: Map.put(&1, "exitCode", exit_code), else: &1))

        :file ->
          Map.put(entity, "diffStr", output)

        _ ->
          entity
          |> Map.put("output", output)
          |> then(&if(images == [], do: &1, else: Map.put(&1, "attachments", images)))
          |> then(&put_details(&1, get_in(event, ["result", "details"])))
      end
    end)
  end

  # Extension failures queued between turns, shown at the head of this turn.
  defp show_extension_errors(state) do
    Enum.reduce(
      state.extension_errors,
      %{state | extension_errors: []},
      &extension_error(&2, &1, confirms: false)
    )
  end

  # A failing extension is named in the work log: a failed entry titled after
  # the extension, saying during which step it failed and why. One kept from between
  # turns is the MC's to show, not Pi taking the prompt.
  defp extension_error(state, event, opts \\ []) do
    n = state.ext_errors + 1
    native = "extension-error:#{state.turn.ids.run}:#{n}"
    name = extension_name(event["extensionPath"])
    step = nonblank(event["event"])
    detail = nonblank(event["error"])

    message =
      [
        "#{name} failed#{if step, do: " during #{step}"}.",
        detail && String.slice(detail, 0, 2_000)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n\n")

    fields = %{"title" => name, "failure" => provider_failure(message, false)}

    state
    |> flush()
    |> Map.put(:ext_errors, n)
    |> ensure_item(native, :error, fields, opts)
    |> finish_item(native, "failed", &Map.merge(&1, fields))
  end

  # An extension is named by its file, or by its folder when the file is the
  # folder's entry point (`index`).
  defp extension_name(path) when is_binary(path) do
    parts =
      path
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")
      |> String.split("/", trim: true)

    file = parts |> List.last() |> to_string() |> String.replace(~r/\.[^.]+$/, "")

    cond do
      file in ["", "index"] and length(parts) > 1 -> Enum.at(parts, -2)
      file == "" -> "Pi extension"
      true -> file
    end
  end

  defp extension_name(_path), do: "Pi extension"

  defp tool_native(state, id), do: "#{state.turn.ids.run}:tool:#{id}"

  defp tool_shape(name, args) when name in ["bash", "powershell"],
    do: {:command, %{"input" => args["command"] || "", "output" => ""}}

  defp tool_shape(name, args) when name in ["edit", "write"] do
    case args["path"] || args["file_path"] do
      path when is_binary(path) -> {:file, %{"fileName" => path}}
      _ -> {:tool, %{"toolName" => name, "input" => args}}
    end
  end

  defp tool_shape(name, args), do: {:tool, %{"toolName" => name || "tool", "input" => args}}

  # Pi's example subagent extension reports the tasks it handed out in its result's
  # details. Each shows as its own subagent entry, and none gets a child thread: Pi
  # runs them without a session. A result of another shape stays the tool's output.
  defp subagents(state, call, result, ended?) do
    case result do
      %{"details" => %{"results" => tasks}} when is_list(tasks) ->
        tasks
        |> Enum.with_index()
        |> Enum.reduce(state, fn {task, n}, state -> subagent(state, call, task, n, ended?) end)

      _ ->
        state
    end
  end

  defp subagent(state, call, %{"agent" => agent, "task" => prompt} = task, n, ended?)
       when is_binary(agent) and is_binary(prompt) do
    native = "#{tool_native(state, call)}:subagent:#{task["step"] || n}"

    state =
      ensure_item(state, native, :subagent, %{
        "origin" => "provider_native",
        "driver" => "pi",
        "providerInstanceId" => Entities.instance(state.turn.ids),
        "childThreadId" => nil,
        "title" => agent,
        "prompt" => prompt,
        "model" => if(is_binary(task["model"]), do: task["model"]),
        "result" => nil
      })

    %{node: node} = item = state.items[native]
    finished? = ended? or task["finished"] == true
    output = subagent_output(task)

    fields =
      if finished?,
        do: %{
          "subagentId" => node,
          "result" => if(output != "", do: String.slice(output, 0, 10_000))
        },
        else: %{"subagentId" => node, "progress" => String.slice(output, 0, 200)}

    fields = Map.reject(fields, &(&1 == {"progress", ""}))

    cond do
      item[:done] ->
        state

      finished? ->
        state
        |> finish_item(native, subagent_status(task), &Map.merge(&1, fields))
        |> put_in([Access.key!(:items), native, :done], true)

      # Pi reports every task with each update: one whose progress has not
      # changed is not written again.
      item[:shown] == fields ->
        state

      true ->
        commit(state, fn stream ->
          [Orchestration.upsert(stream, "turn-item", item.id, &Map.merge(&1, fields))]
        end)

        put_in(state.items[native][:shown], fields)
    end
  end

  defp subagent(state, _call, _task, _n, _ended?), do: state

  defp subagent_status(%{"stopReason" => "aborted"}), do: "interrupted"
  defp subagent_status(%{"stopReason" => "error"}), do: "failed"
  defp subagent_status(%{"exitCode" => code}) when is_integer(code) and code != 0, do: "failed"
  defp subagent_status(_task), do: "completed"

  # What a subagent said last, or why it failed.
  defp subagent_output(task) do
    failed? =
      task["stopReason"] in ["error", "aborted"] or
        (is_integer(task["exitCode"]) and task["exitCode"] != 0)

    failure =
      if failed?,
        do: Enum.find([task["errorMessage"], task["stderr"]], &(is_binary(&1) and &1 != ""))

    failure ||
      (task["messages"] || [])
      |> List.wrap()
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %{"role" => "assistant", "content" => content} ->
          case if(is_binary(content), do: content, else: result_text(%{"content" => content})) do
            "" -> nil
            text -> text
          end

        _ ->
          nil
      end)
  end

  defp result_text(%{"content" => content}) when is_list(content) do
    for(%{"type" => "text", "text" => text} <- content, do: text) |> Enum.join("\n")
  end

  defp result_text(_result), do: ""

  # Images a tool returned are stored with the thread like pasted ones, so the item
  # carries their ids, not their bytes. One that is not a valid image is left out.
  defp tool_images(thread_id, %{"content" => content}) when is_list(content) do
    for {%{"type" => "image", "data" => data, "mimeType" => mime}, n} <-
          Enum.with_index(content, 1),
        is_binary(data) and is_binary(mime),
        image = %{
          "name" => "tool-image-#{n}",
          "mimeType" => mime,
          "dataUrl" => "data:#{mime};base64,#{data}"
        },
        {:ok, %{"attachments" => stored}} <-
          [HalC2.Attachments.persist(%{"threadId" => thread_id, "attachments" => [image]})],
        attachment <- stored,
        do: attachment
  end

  defp tool_images(_thread_id, _result), do: []

  # A tool's structured results, kept unless they are empty or too large to send
  # with the thread.
  @max_details_chars 64_000
  defp put_details(entity, details) when details in [nil, %{}, []], do: entity

  defp put_details(entity, details) do
    if byte_size(JSON.encode!(details)) <= @max_details_chars,
      do: Map.put(entity, "details", details),
      else: entity
  end

  defp provider_failure(message, retryable),
    do: %{
      "class" => "provider_error",
      "message" => message,
      "code" => nil,
      "retryable" => retryable
    }

  # A provider retry is one item per turn (`terminal-failure:<provider turn>`).
  defp retry_item(state, status, title, failure, retry) do
    native = "terminal-failure:#{state.turn.ids.provider_turn}"
    fields = %{"title" => title, "failure" => failure, "retry" => retry}
    state = state |> flush() |> ensure_item(native, :error, fields)
    state = %{state | retry: %{failure: failure, retry: retry}}

    if status == "running" do
      %{id: item_id} = state.items[native]
      at = Entities.now()

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "turn-item",
            item_id,
            &Map.merge(&1, Map.merge(fields, %{"status" => "running", "updatedAt" => at}))
          )
        ]
      end)

      state
    else
      finish_item(state, native, status, &Map.merge(&1, fields))
    end
  end

  # Pi attaches the message's usage to streaming updates; the meter moves when it changes.
  defp live_usage(%{context_window: window} = state, %{"totalTokens" => used} = usage)
       when is_integer(window) and window > 0 and is_integer(used) and used > 0 do
    if used == state.live_tokens do
      state
    else
      token_usage(state, %{
        "usedTokens" => used,
        "maxTokens" => window,
        "inputTokens" => usage["input"],
        "cachedInputTokens" => usage["cacheRead"],
        "outputTokens" => usage["output"]
      })
      |> Map.put(:live_tokens, used)
    end
  end

  defp live_usage(state, _usage), do: state

  defp token_usage(state, usage) do
    usage =
      usage
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Map.new()
      |> Map.put("updatedAt", Entities.now())

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-turn",
          state.turn.ids.provider_turn,
          &Map.put(&1, "tokenUsage", usage)
        )
      ]
    end)

    state
  end

  # --- extension dialogs ---------------------------------------------------------

  # A notice from an extension shows as a notice in the thread, not folded
  # into the tool calls.
  defp dialog("notify", ui_id, request, state) do
    native = "#{state.turn.ids.run}:ui:#{ui_id}"
    message = request["message"] || request["title"] || ""

    state
    |> flush()
    |> ensure_item(native, :notice, %{"title" => message, "message" => message})
    |> finish_item(
      native,
      "completed",
      &Map.merge(&1, %{"title" => message, "message" => message})
    )
  end

  # HAL-C2's extension asks before a tool the access mode does not allow.
  defp dialog("confirm", ui_id, request, state) do
    title = request["title"] || ""
    message = request["message"]
    key = "#{String.length(title)}:#{title}#{message}"

    if MapSet.member?(state.allowed, key) do
      ui_reply(state, ui_id, %{"confirmed" => true})
      state
    else
      kind = if title =~ ~r/^Allow (edit|write)\?$/, do: "file-change", else: "command"
      prompt = String.slice(if(message in [nil, ""], do: title, else: message), 0, 4_000)
      native = "#{state.turn.ids.run}:ui:#{ui_id}"

      {state, request_id} =
        open_request(flush(state), native, kind, prompt, nil, %{"title" => title})

      %{state | requests: Map.put(state.requests, request_id, {:confirm, ui_id, key})}
    end
  end

  defp dialog(method, ui_id, request, state) when method in ["select", "input", "editor"] do
    native = "#{state.turn.ids.run}:ui:#{ui_id}"
    title = nonblank(request["title"]) || "Pi"

    options =
      case method do
        "select" ->
          for option <- request["options"] || [] do
            label = if option in [nil, ""], do: "Empty value", else: option
            %{"label" => label, "description" => nonblank(option) || label, "value" => option}
          end

        _ ->
          [
            %{
              "label" => "Submit empty value",
              "description" => "Send an empty string to the extension.",
              "value" => ""
            }
          ]
      end

    # What the question reads, and its header: a message or a placeholder is
    # the question under the title; with only a title to say, the title is the
    # question, once, under a plain "Question" header.
    message = nonblank(request["message"])
    placeholder = nonblank(request["placeholder"])

    {header, text} =
      cond do
        message -> {title, message}
        placeholder -> {title, placeholder}
        true -> {"Question", title}
      end

    # An editor dialog's current text is the answer's starting point, whole and
    # exactly as Pi sent it (`initialAnswer`). It is also quoted with the question,
    # cut to 2,000 characters, for a client that does not prefill its composer.
    prefill = if method == "editor", do: request["prefill"]
    shown = nonblank(prefill)

    text =
      if shown,
        do: text <> "\n\nCurrent value:\n" <> String.slice(shown, 0, 2_000),
        else: text

    question = %{"id" => native, "header" => header, "question" => text, "options" => options}

    question =
      if method == "editor",
        do: Map.put(question, "initialAnswer", if(is_binary(prefill), do: prefill, else: "")),
        else: question

    {state, request_id} = open_question(flush(state), native, [question])
    %{state | requests: Map.put(state.requests, request_id, {:question, ui_id, native})}
  end

  defp dialog(_method, _ui_id, _request, state), do: state

  defp ui_reply(state, ui_id, reply),
    do: Connection.notify(state.conn, "extension_ui_response", Map.put(reply, "id", ui_id))

  # A user's answer: one Pi did not get leaves its request open to be sent again.
  defp deliver_ui(state, ui_id, reply) do
    case state.conn &&
           Connection.deliver(state.conn, "extension_ui_response", Map.put(reply, "id", ui_id)) do
      :ok -> :ok
      _ -> {:error, "Pi did not get the answer. Send it again."}
    end
  end

  defp answer([value | _]), do: answer(value)
  defp answer(value) when is_binary(value), do: value
  defp answer(_value), do: nil

  defp cancel_requests(state) do
    Enum.reduce(state.requests, %{state | requests: %{}}, fn {request_id, request}, state ->
      ui_id = elem(request, 1)
      ui_reply(state, ui_id, %{"cancelled" => true})
      resolve_request(state, request_id, nil, "cancelled")
    end)
  end

  # --- end of turn -----------------------------------------------------------------

  # Pi's answer to a steer, which its caller hears. One it took joins the running work,
  # or starts new work that settles after this answer, so the refusals held for that
  # settle are heard now, while the turn runs. One it refused starts nothing, so a settle
  # that waited on it alone ends the turn now, before the caller hears the refusal: it
  # finds the turn over and sends the message on its own (`HalC2.Orchestration`). A
  # refusal while the settle waits on other steers is held until they are answered, and
  # a steer Pi exited without answering until its exit ends the turn (`:EXIT`).
  # A steer Pi turned back for a compaction waits for it to end, then goes again;
  # in a stopped turn it stays unsent, in that turn.
  defp steered(state, from, {:reply, {:error, reason}} = reply, steer) do
    cond do
      steer == nil or state.turn == nil or not compaction_rejection?(reason) ->
        steered(state, from, reply)

      state.interrupted ->
        GenServer.reply(from, :ok)
        state

      true ->
        hold_rejected(%{state | held_steers: state.held_steers ++ [{from, steer}]})
    end
  end

  defp steered(state, from, reply, _steer), do: steered(state, from, reply)

  defp steered(state, from, reply) do
    {answer, gone?} =
      case reply do
        {:reply, {:ok, _}} -> {:ok, false}
        {:reply, {:error, :closed}} -> {{:error, "Pi exited"}, true}
        {:reply, {:error, %{"exitCode" => _}}} -> {{:error, "Pi exited"}, true}
        {:reply, {:error, reason}} -> {{:error, format(reason)}, false}
        # The connection itself is gone.
        {:error, _down} -> {{:error, "Pi exited"}, true}
      end

    held? =
      state.turn != nil and
        (gone? or (state.settled and :gen_server.reqids_size(state.steers) > 0))

    cond do
      answer == :ok ->
        GenServer.reply(from, :ok)
        refusals(%{state | settled: false})

      held? ->
        %{state | refused: [{from, answer} | state.refused]}

      true ->
        state = settle_held(state)
        # A turn the user stopped keeps the message, as `unanswered/2` keeps an
        # unanswered steer's: an error here would find the run interrupted (the
        # settle above may have recorded it) and send the message on its own.
        GenServer.reply(from, if(state.interrupted, do: :ok, else: answer))
        state
    end
  end

  # A steer Pi has not answered in its budget is taken as taken, as a Codex steer whose
  # answer is late is (`HalC2.Orchestration`): Pi still holds it and may act on it, so
  # its message is the turn's. A settle that waited on it alone ends the turn now, and
  # Pi's late answer is dropped. Unlike an answered steer (`steered/3`), a timed-out
  # one does not clear `settled` or release the held refusals while other steers are
  # still out. Dropping it here also abandons its entry in the connection's pending
  # map (and the `send_request` monitor on it) until Pi answers or its process
  # exits — one entry per timed-out steer for the connection's lifetime, the same
  # deliberate cost the ACP runtime spells out above its `answer/3`. An answer
  # proves Pi took the steer into work that settles again; a timeout proves
  # nothing, so the owed settle stays. The held refusals then hear
  # once the last steer out resolves (each bounded by its own answer timer, an
  # answer, or Pi's exit), which is the first moment it is known whether the turn
  # ended — releasing them sooner would tell a declined steer's sender it was
  # refused while the run still shows active, and it would not be sent on its own.
  defp steer_timeout(state, from) do
    {late, others} =
      state.steers
      |> :gen_server.reqids_to_list()
      |> Enum.split_with(&match?({_, {^from, _, _}}, &1))

    if late == [] do
      state
    else
      GenServer.reply(from, :ok)

      steers =
        for {request, label} <- others,
            reduce: :gen_server.reqids_new(),
            do: (steers -> :gen_server.reqids_add(request, label, steers))

      settle_held(%{state | steers: steers})
    end
  end

  defp settle_held(state) do
    if state.turn != nil and state.settled and :gen_server.reqids_size(state.steers) == 0 and
         state.held_steers == [],
       do: settle(state),
       else: state
  end

  # The turn's entries from Pi's listing since the turn started: `{:ok, user,
  # retained}`. `user` is the turn's first user entry, `:none` when the turn left
  # nothing on Pi's branch, or `:unknown`. `get_entries` lists in the order
  # entries were written, abandoned branches included, so the turn is the walk
  # from the new leaf up its parents to where the turn started. A walk that never
  # gets there means the turn moved Pi's leaf back (an extension's `navigateTree`):
  # `retained` then lists every user entry still on Pi's branch, from a walk of the
  # whole session to its root. A session switched away has no old leaf in its
  # tree, so is not a rewind. A Pi listing entries without parents is read in order.
  defp turn_entries(state, entries, head) do
    if Enum.all?(entries, &Map.has_key?(&1, "parentId")) do
      case walk(index(entries), head, state.leaf) do
        :loop ->
          :error

        {:reached, seen, users} ->
          {:ok, turn_user(seen, users), nil}

        {:left, seen, users} ->
          {:ok, turn_user(seen, users), retained(state, head)}
      end
    else
      user = Enum.find(entries, &(get_in(&1, ["message", "role"]) == "user"))
      {:ok, if(user, do: user["id"], else: :unknown), nil}
    end
  end

  defp turn_user(_seen, [user | _]), do: user
  defp turn_user(0, []), do: :none
  defp turn_user(_seen, []), do: :unknown

  defp retained(%{leaf: nil}, _head), do: nil

  defp retained(state, head) do
    with {:ok, %{"entries" => entries}} when is_list(entries) <- call(state, "get_entries", %{}),
         index = index(entries),
         true <- Map.has_key?(index, state.leaf),
         {:reached, _seen, users} <- walk(index, head, nil) do
      MapSet.new(users)
    else
      _ -> nil
    end
  end

  defp index(entries), do: Map.new(entries, &{&1["id"], &1})

  # Walks Pi's tree from `id` up its parents until `stop`: `{:reached | :left,
  # entries passed, their user entries oldest first}`, or `:loop` for a parent
  # chain that loops (corrupted session data).
  defp walk(index, id, stop, seen \\ MapSet.new(), users \\ [])

  defp walk(_index, stop, stop, seen, users), do: {:reached, MapSet.size(seen), users}

  defp walk(index, id, stop, seen, users) do
    case index do
      %{^id => entry} ->
        if MapSet.member?(seen, id) do
          :loop
        else
          users = if get_in(entry, ["message", "role"]) == "user", do: [id | users], else: users
          walk(index, entry["parentId"], stop, MapSet.put(seen, id), users)
        end

      _ ->
        {:left, MapSet.size(seen), users}
    end
  end

  # Pi moved its conversation back by itself: the finished runs on this provider
  # thread whose turns are no longer on Pi's branch become `rolled_back`, and their
  # checkpoints `stale`, as a revert leaves them (`HalC2.Orchestration.Rollback`);
  # the files stay as they are. A run whose place in Pi's session was never learned
  # goes with everything after the last run Pi kept; one that left nothing there (a
  # command) goes only from after the first run Pi dropped. The turn that rewound stays.
  defp retire_rewound(stream, ids, retained) do
    turns =
      for turn <- HalC2.StreamState.list(stream, "provider-turn"),
          turn["providerThreadId"] == ids.provider_thread,
          into: %{},
          do:
            {turn["ordinal"],
             case turn["nativeTurnRef"] do
               nil -> :none
               ref -> ref["nativeId"] || :unknown
             end}

    settled =
      for run <- HalC2.StreamState.list(stream, "run"),
          run["id"] != ids.run,
          run["status"] in ~w(completed failed interrupted),
          Map.has_key?(turns, run["ordinal"]),
          do: {run, turns[run["ordinal"]]}

    ordinals = fn keep? ->
      for {run, native} <- settled, is_binary(native), keep?.(native), do: run["ordinal"]
    end

    kept = Enum.max(ordinals.(&(&1 in retained)), fn -> 0 end)
    dropped = Enum.min(ordinals.(&(&1 not in retained)), fn -> :infinity end)

    off =
      for {run, native} <- settled,
          off_branch?(native, run["ordinal"], {kept, dropped, retained}),
          do: run

    off_ids = MapSet.new(off, & &1["id"])
    at = Entities.now()
    rolled_back = &Map.merge(&1, %{"status" => "rolled_back", "completedAt" => at})

    stale =
      for checkpoint <- HalC2.StreamState.list(stream, "checkpoint"),
          checkpoint["status"] == "ready",
          checkpoint["runId"] in off_ids,
          do:
            Orchestration.upsert(
              stream,
              "checkpoint",
              checkpoint["id"],
              &Map.put(&1, "status", "stale")
            )

    stale ++
      Enum.flat_map(off, fn run ->
        [
          Orchestration.upsert(stream, "run", run["id"], rolled_back),
          run["rootNodeId"] &&
            Orchestration.upsert(stream, "node", run["rootNodeId"], rolled_back)
        ]
      end)
  end

  # `dropped` is `:infinity` when Pi dropped no run of a known place: a number is
  # less than any atom.
  defp off_branch?(:none, ordinal, {_kept, dropped, _retained}), do: ordinal > dropped
  defp off_branch?(:unknown, ordinal, {kept, _dropped, _retained}), do: ordinal > kept
  defp off_branch?(native, _ordinal, {_kept, _dropped, retained}), do: native not in retained

  # The held refusals' callers hear them, once the turn ended or runs on — except
  # from a turn the user stopped, whose callers hear `:ok` so their messages stay
  # in the stopped turn instead of being sent on their own (`unanswered/2`).
  defp refusals(state) do
    for {from, answer} <- Enum.reverse(state.refused),
        do: GenServer.reply(from, if(state.interrupted, do: :ok, else: answer))

    %{state | refused: []}
  end

  # The session's entries since the turn started name the turn (its user message)
  # and the conversation's new head; the session's stats give its context usage.
  # A turn that moved Pi's leaf off the branch it started on (an extension's
  # `navigateTree`) retires the runs Pi no longer has (`retire_rewound/3`).
  defp settle(state) do
    ids = state.turn.ids
    driver = ids.driver

    state =
      with {:ok, %{"entries" => entries} = data} when is_list(entries) <-
             call(state, "get_entries", %{"since" => state.leaf}),
           head = data["leafId"],
           {:ok, user, retained} <- turn_entries(state, entries, head) do
        # The head is where the next turn's messages start: a fork from this turn
        # is cut at the first user message after it. A turn that left nothing on
        # Pi's branch has no native turn: a rewind past it needs no fork.
        turn_refs =
          %{
            "nativeTurnRef" =>
              case user do
                :none -> nil
                id when is_binary(id) -> Entities.provider_ref(id, driver)
                _ -> :keep
              end,
            "nativeHeadRef" => head && Entities.provider_ref(head, driver)
          }
          |> Map.reject(fn {key, ref} -> ref == :keep or (key == "nativeHeadRef" and !ref) end)

        commit(state, fn stream ->
          [
            turn_refs != %{} &&
              Orchestration.upsert(
                stream,
                "provider-turn",
                ids.provider_turn,
                &Map.merge(&1, turn_refs)
              ),
            head &&
              Orchestration.upsert(
                stream,
                "provider-thread",
                ids.provider_thread,
                &Map.put(&1, "nativeConversationHeadRef", Entities.provider_ref(head, driver))
              )
            | if(retained, do: retire_rewound(stream, ids, retained), else: [])
          ]
        end)

        %{state | leaf: head || state.leaf}
      else
        _ -> state
      end

    state =
      case Connection.call(state.conn, "get_session_stats", %{}, @stats_ms) do
        {:ok, %{"contextUsage" => %{"tokens" => used, "contextWindow" => window}} = stats}
        when is_integer(used) and is_integer(window) and window > 0 ->
          totals = stats["tokens"] || %{}

          token_usage(state, %{
            "usedTokens" => used,
            "maxTokens" => window,
            "inputTokens" => totals["input"],
            "cachedInputTokens" => totals["cacheRead"],
            "outputTokens" => totals["output"]
          })

        _ ->
          state
      end

    cond do
      state.interrupted -> end_turn(state, "interrupted", nil)
      state.failure -> end_turn(state, "failed", state.failure)
      true -> end_turn(state, "completed", nil)
    end
  catch
    :exit, _ ->
      end_turn(
        state,
        "failed",
        if(state.interrupted,
          do: "Pi process was stopped.",
          else: "Pi process exited unexpectedly."
        )
      )
  end

  defp end_turn(state, status, failure) do
    state = state |> flush() |> close_open_items(status) |> cancel_requests()
    finish(state, status, failure)
    state = refusals(state)
    state = answer_compact_steer(state, status)

    state =
      answer_held_steers(
        state,
        if(status == "interrupted", do: :ok, else: {:error, "the turn ended"})
      )

    %{
      state
      | turn: nil,
        items: %{},
        steers: unanswered(state.steers, status),
        settled: false,
        prompt_held: false,
        compact: nil,
        compact_steer: nil,
        # A compaction this turn saw start is over or abandoned with it: its
        # late end lands between turns or is dropped, and must not keep
        # the next turn's checks thinking Pi still compacts.
        compacting: false,
        # A compaction still out when its turn ends is abandoned: Pi
        # finishes it anyway, and its late events are dropped on arrival
        # (`handle_info` for notifications) while its task is out, so they
        # show in no later turn.
        abandoned_compacts:
          if(state.compact,
            do: MapSet.put(state.abandoned_compacts, state.compact),
            else: state.abandoned_compacts
          )
    }
  end

  # A steered compaction still running when its turn ends (Pi's `abort` does
  # not stop a compaction): its caller hears what an unanswered steer hears,
  # and the task's late result falls into the catch-all. Pi still finishes
  # the compaction and emits its events; `end_turn/3` keeps its task ref as
  # abandoned so those are dropped while it is out, and its reply (or
  # `:DOWN`) forgets it. Nothing of it leaks into the next turn.
  defp answer_compact_steer(%{compact_steer: nil} = state, _status), do: state

  defp answer_compact_steer(state, status) do
    GenServer.reply(
      state.compact_steer,
      if(status == "interrupted", do: :ok, else: {:error, "the turn ended"})
    )

    state
  end

  # Steers whose turn ended before Pi answered them: their callers hear the turn is
  # gone, and send the message on its own. A turn the user stopped is the exception:
  # the message was handed to Pi for that turn, so it stays in the stopped turn,
  # unanswered — sending it on its own would start new work the moment the user
  # asked for none. (Before the steer was a tracked request it had already been
  # answered `:ok` when an interrupt landed, and stayed the same way.)
  defp unanswered(steers, status) do
    answer = if status == "interrupted", do: :ok, else: {:error, "the turn ended"}

    for {_request, {from, timer, _steer}} <- :gen_server.reqids_to_list(steers) do
      Process.cancel_timer(timer)
      GenServer.reply(from, answer)
    end

    :gen_server.reqids_new()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_n), do: nil

  defp format(reason) when is_binary(reason), do: detail(reason)
  defp format(%{"message" => message}) when is_binary(message), do: detail(message)
  defp format(reason), do: detail(inspect(reason))

  @detail_chars 200

  # A failure Pi explains at length, cut to what a banner can show.
  defp detail(text) do
    if String.length(text) > @detail_chars,
      do: String.slice(text, 0, @detail_chars) <> "…",
      else: text
  end

  # A model error with no reason of its own, and a model at capacity, in the
  # words the thread's error banner reads.
  defp model_failure(message) do
    case nonblank(message) do
      nil ->
        "Pi reported a model error."

      message ->
        if String.contains?(String.downcase(message), "at capacity"),
          do: "Provider overloaded: #{message}",
          else: message
    end
  end

  defp nonblank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp nonblank(_value), do: nil
end
