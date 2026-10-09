defmodule HalC2.OrchestrationPropTest do
  @moduledoc """
  A state machine over two threads driven through the orchestration commands a client
  sends: create, rename, archive, unarchive and delete a thread; send a message that
  starts a turn, waits in the queue, steers the running turn or restarts it; have the
  MC send the agent a message of its own (a `notification`, as a delegated task's
  result is); send a message again with its message id, as a client retrying after a
  reconnect does;
  cancel, edit, reorder and promote queued messages; resume a held queue; interrupt a turn;
  crash a provider runtime mid-turn; release a thread's provider session as
  IdleSessions does; and restart the MC mid-turn (boot recovery).

  Turns run on the fake Codex app-server in `test/support/fake_codex.py`. Every
  message says "wait", so its turn runs until it is interrupted or steered, and the
  model knows exactly which turn runs. After each command the test waits on the
  threads' streams until nothing is starting and the runs the command ended have
  ended, then compares each thread's projection with the model: thread state, runs
  and their statuses in order, the queue's order and positions, at most one active
  run, and every user message exactly once, in the run it belongs to. A message of the
  MC's own is in the transcript as a notification, never as a user message, and while
  it is queued it cannot be edited or made to steer.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @threads ~w(t1 t2)
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000

  property "orchestration keeps the queue, runs and messages the model expects",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("orchestration")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        Process.put(:work, work)
        Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
            id: :claude_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
            id: :acp_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
            id: :pi_registry
          ),
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
        ])

        subscribe()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # threads: id -> %{status: :live | :archived | :deleted, title, runs, queue, messages}
  #   runs: [%{msg, status, held}] in the order they were made (their ordinals);
  #   queue: queued messages, first to start first;
  #   messages: msg -> %{text, run: the message whose run it joined, shown: in transcript,
  #     notice: the MC's own message to the agent}
  def initial_state, do: %{threads: %{}, next: 1}

  def command(%{threads: threads, next: next}) do
    tid = oneof(@threads)
    msg = "m#{next}"

    always = [
      {3, {:call, __MODULE__, :create, [tid]}},
      {8,
       {:call, __MODULE__, :send, [tid, msg, oneof([:queue, :queue, :auto, :restart, :notice])]}},
      {1, {:call, __MODULE__, :rename, [tid, oneof(["Alpha", "Beta"])]}},
      {1, {:call, __MODULE__, :archive, [tid]}},
      {1, {:call, __MODULE__, :unarchive, [tid]}},
      {1, {:call, __MODULE__, :delete, [tid]}},
      {3, {:call, __MODULE__, :interrupt, [tid]}},
      {1, {:call, __MODULE__, :resume, [tid]}},
      {1, {:call, __MODULE__, :release, [tid]}}
    ]

    sent = for {t, %{messages: m}} <- threads, id <- Map.keys(m), do: {t, id}

    on_messages =
      if sent == [],
        do: [],
        else: [
          {3, let({t, m} <- oneof(sent), do: {:call, __MODULE__, :cancel, [t, m]})},
          {2,
           let(
             [{t, m} <- oneof(sent), mode <- oneof([:queue, :auto, :restart])],
             do: {:call, __MODULE__, :resend, [t, m, mode]}
           )},
          {2,
           let(
             [{t, m} <- oneof(sent), k <- range(1, 3)],
             do: {:call, __MODULE__, :edit, [t, m, "wait edit #{k}"]}
           )},
          {2,
           let(
             [{t, m} <- oneof(sent), {_, before} <- oneof([{nil, nil} | sent])],
             do: {:call, __MODULE__, :reorder, [t, m, before]}
           )},
          {3, let({t, m} <- oneof(sent), do: {:call, __MODULE__, :promote, [t, m]})}
        ]

    running =
      for {t, thread} <- threads, Enum.any?(thread.runs, &(&1.status == :running)), do: t

    on_running =
      if running == [],
        do: [],
        else: [
          {2, {:call, __MODULE__, :crash, [oneof(running)]}},
          {2, {:call, __MODULE__, :restart, []}}
        ]

    frequency(always ++ on_messages ++ on_running)
  end

  def precondition(%{threads: threads}, {:call, _, :crash, [tid]}),
    do: threads[tid] != nil and running(threads[tid]) != nil

  def precondition(%{threads: threads}, {:call, _, :release, [tid]}),
    do: threads[tid] != nil

  def precondition(%{threads: threads}, {:call, _, :restart, []}),
    do: Enum.any?(threads, fn {_, t} -> running(t) != nil end)

  def precondition(%{threads: threads}, {:call, _, fun, [tid, msg | _]})
      when fun in [:cancel, :edit, :reorder, :promote, :resend],
      do: Map.has_key?((threads[tid] || %{messages: %{}}).messages, msg)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :send, [tid, msg, mode]}) do
    state = %{state | next: state.next + 1}

    case refusal(state, tid, :send) do
      nil -> update(state, tid, &sent(&1, msg, mode))
      _ -> state
    end
  end

  # A message the thread already has was sent: sending it again changes nothing, in
  # whatever state the first one is now (running, queued, steered, cancelled, edited).
  def next_state(state, _result, {:call, _, :resend, _}), do: state

  def next_state(state, _result, {:call, _, :create, [tid]}) do
    if Map.has_key?(state.threads, tid),
      do: state,
      else:
        put_in(state.threads[tid], %{
          status: :live,
          title: "Thread #{tid}",
          runs: [],
          queue: [],
          messages: %{}
        })
  end

  def next_state(state, _result, {:call, _, :rename, [tid, title]}) do
    case refusal(state, tid, :rename) do
      nil -> update(state, tid, &%{&1 | title: title})
      _ -> state
    end
  end

  def next_state(state, _result, {:call, _, :archive, [tid]}) do
    case refusal(state, tid, :archive) do
      nil -> update(state, tid, &(&1 |> cancel_queue() |> Map.put(:status, :archived)))
      _ -> state
    end
  end

  def next_state(state, _result, {:call, _, :unarchive, [tid]}) do
    case refusal(state, tid, :unarchive) do
      nil -> update(state, tid, &%{&1 | status: :live})
      _ -> state
    end
  end

  def next_state(state, _result, {:call, _, :delete, [tid]}) do
    case refusal(state, tid, :delete) do
      nil ->
        update(state, tid, fn thread ->
          thread
          |> cancel_queue()
          |> set_runs(&if(&1.status == :running, do: %{&1 | status: :cancelled}, else: &1))
          |> Map.put(:status, :deleted)
        end)

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :interrupt, [tid]}) do
    case refusal(state, tid, :interrupt) do
      nil -> update(state, tid, &(&1 |> end_running(:interrupted) |> start_next()))
      _ -> state
    end
  end

  def next_state(state, _result, {:call, _, :crash, [tid]}),
    do: update(state, tid, &(&1 |> end_running(:failed) |> start_next()))

  def next_state(state, _result, {:call, _, :restart, []}) do
    threads =
      Map.new(state.threads, fn {tid, thread} ->
        # Boot recovery opens the threads whose sidebar row shows a run in flight: one
        # running, or a latest run still queued. Their queues wait for the user to
        # resume them; an idle queue elsewhere starts nothing at boot anyway.
        opened? = running(thread) != nil or match?(%{status: :queued}, List.last(thread.runs))
        held = if opened?, do: MapSet.new(thread.queue), else: MapSet.new()

        thread =
          set_runs(thread, fn run ->
            cond do
              run.status == :running -> %{run | status: :interrupted}
              MapSet.member?(held, run.msg) -> %{run | held: true}
              true -> run
            end
          end)

        {tid, thread}
      end)

    %{state | threads: threads}
  end

  # The session goes and the next message starts it again; no run changes.
  def next_state(state, _result, {:call, _, :release, [_tid]}), do: state

  def next_state(state, _result, {:call, _, :resume, [tid]}) do
    case refusal(state, tid, :queue) do
      nil ->
        update(state, tid, fn thread ->
          thread
          |> set_runs(&if(&1.msg in thread.queue, do: %{&1 | held: false}, else: &1))
          |> start_next()
        end)

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :cancel, [tid, msg]}) do
    case refusal(state, tid, :queue) do
      nil ->
        update(state, tid, fn thread ->
          if msg in thread.queue,
            do:
              %{thread | queue: List.delete(thread.queue, msg)}
              |> set_runs(&if(&1.msg == msg, do: %{&1 | status: :cancelled}, else: &1)),
            else: thread
        end)

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :edit, [tid, msg, text]}) do
    case refusal(state, tid, :queue) do
      nil ->
        update(state, tid, fn thread ->
          if msg in thread.queue and not thread.messages[msg].notice,
            do: put_in(thread.messages[msg].text, text),
            else: thread
        end)

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :reorder, [tid, msg, before]}) do
    case refusal(state, tid, :queue) do
      nil ->
        update(state, tid, fn thread ->
          if msg in thread.queue do
            rest = List.delete(thread.queue, msg)

            queue =
              case Enum.find_index(rest, &(&1 == before)) do
                nil -> rest ++ [msg]
                index -> List.insert_at(rest, index, msg)
              end

            %{thread | queue: queue}
          else
            thread
          end
        end)

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :promote, [tid, msg]}) do
    case promote_refusal(state, tid, msg) do
      nil -> update(state, tid, &promoted(&1, msg))
      _ -> state
    end
  end

  def postcondition(state, {:call, _, fun, args}, {reply, projection}) do
    expected = expected_reply(state, fun, args)
    next = next_state(state, nil, {:call, __MODULE__, fun, args})
    wanted = Map.new(@threads, &{&1, model_projection(next.threads[&1])})

    reply_ok? = reply_matches?(expected, reply)

    unless reply_ok?,
      do: IO.puts("#{fun} #{inspect(args)}: expected #{inspect(expected)}, got #{inspect(reply)}")

    unless projection == wanted,
      do:
        IO.puts(
          "#{fun} #{inspect(args)}: projection\n  #{inspect(projection)}\nmodel\n  #{inspect(wanted)}"
        )

    reply_ok? and projection == wanted
  end

  # --- the model's rules ------------------------------------------------------------

  # Why the thread refuses the command, or nil.
  defp refusal(state, tid, command) do
    case state.threads[tid] do
      nil when command == :interrupt ->
        {:error, "no running turn"}

      nil ->
        {:error, "unknown thread #{tid}"}

      %{status: :deleted} when command == :interrupt ->
        {:error, "no running turn"}

      %{status: :deleted} when command == :delete ->
        nil

      %{status: :deleted} ->
        {:error, "Thread #{tid} is deleted."}

      %{status: :archived} when command == :archive ->
        {:error, "Thread #{tid} is already archived."}

      %{status: status} when command == :unarchive and status != :archived ->
        {:error, "Thread #{tid} is not archived."}

      thread when command == :interrupt ->
        if running(thread), do: nil, else: {:error, "no running turn"}

      _ ->
        nil
    end
  end

  defp promote_refusal(state, tid, msg) do
    case state.threads[tid] do
      nil ->
        {:error, "unknown thread #{tid}"}

      %{status: :live} = thread ->
        if msg in thread.queue, do: agents_own(state, tid, msg), else: {:error, :not_queued}

      _ ->
        {:error, "Thread #{tid} is not active."}
    end
  end

  # A queued message of the MC's own is refused an edit and a promotion.
  defp agents_own(state, tid, msg) do
    case state.threads[tid] do
      %{queue: queue, messages: %{^msg => %{notice: true}}} ->
        if msg in queue, do: {:error, :agents_own}

      _ ->
        nil
    end
  end

  defp expected_reply(state, :create, [tid]),
    do: if(state.threads[tid], do: {:error, "Thread #{tid} already exists."}, else: :ok)

  defp expected_reply(state, :send, [tid | _]), do: refusal(state, tid, :send) || :ok
  defp expected_reply(state, :rename, [tid, _]), do: refusal(state, tid, :rename) || :ok

  defp expected_reply(state, fun, [tid])
       when fun in [:archive, :unarchive, :delete, :interrupt],
       do: refusal(state, tid, fun) || :ok

  defp expected_reply(state, :edit, [tid, msg, _]),
    do: refusal(state, tid, :queue) || agents_own(state, tid, msg) || :ok

  defp expected_reply(state, fun, [tid | _]) when fun in [:resume, :cancel, :reorder],
    do: refusal(state, tid, :queue) || :ok

  defp expected_reply(state, :promote, [tid, msg]), do: promote_refusal(state, tid, msg) || :ok
  defp expected_reply(_state, :resend, _args), do: :ok

  defp expected_reply(state, :release, [tid]),
    do: if(running(state.threads[tid]), do: {:error, :busy}, else: :ok)

  defp expected_reply(_state, _fun, _args), do: :ok

  defp reply_matches?({:error, :not_queued}, {:error, message}),
    do: message =~ ~r/^Queued run \S+ is not queued\.$/

  defp reply_matches?({:error, :agents_own}, {:error, message}),
    do: message =~ ~r/^Queued run \S+ is the agent's own message/

  defp reply_matches?(expected, reply), do: expected == reply

  defp update(state, tid, fun), do: update_in(state.threads[tid], fun)

  defp set_runs(thread, fun), do: %{thread | runs: Enum.map(thread.runs, fun)}

  defp running(thread), do: Enum.find(thread.runs, &(&1.status == :running))

  defp end_running(thread, status),
    do: set_runs(thread, &if(&1.status == :running, do: %{&1 | status: status}, else: &1))

  defp cancel_queue(thread) do
    queued = MapSet.new(thread.queue)

    %{thread | queue: []}
    |> set_runs(&if(MapSet.member?(queued, &1.msg), do: %{&1 | status: :cancelled}, else: &1))
  end

  # The thread's first queued message that is not held starts, when nothing runs. An
  # archived thread starts nothing from its queue until it is unarchived.
  defp start_next(thread) do
    held = for run <- thread.runs, run.held, into: MapSet.new(), do: run.msg

    with :live <- thread.status,
         nil <- running(thread),
         next when next != nil <- Enum.find(thread.queue, &(not MapSet.member?(held, &1))) do
      %{thread | queue: List.delete(thread.queue, next)}
      |> set_runs(&if(&1.msg == next, do: %{&1 | status: :running}, else: &1))
      |> put_in([:messages, next, :shown], true)
    else
      _ -> thread
    end
  end

  defp sent(thread, msg, mode) do
    active = running(thread)
    message = %{text: "wait #{msg}", run: msg, shown: false, notice: mode == :notice}

    cond do
      active == nil ->
        %{thread | runs: thread.runs ++ [%{msg: msg, status: :running, held: false}]}
        |> put_in([:messages, msg], %{message | shown: true})

      mode == :auto ->
        # The fake ends a turn it is steered into.
        thread
        |> put_in([:messages, msg], %{message | run: active.msg, shown: true})
        |> end_running(:completed)
        |> start_next()

      mode == :restart ->
        %{
          thread
          | runs: thread.runs ++ [%{msg: msg, status: :queued, held: false}],
            queue: [msg | thread.queue]
        }
        |> put_in([:messages, msg], message)
        |> end_running(:interrupted)
        |> start_next()

      true ->
        %{
          thread
          | runs: thread.runs ++ [%{msg: msg, status: :queued, held: false}],
            queue: thread.queue ++ [msg]
        }
        |> put_in([:messages, msg], message)
    end
  end

  # A queued message steers the running turn, or goes first in the queue when no turn
  # runs.
  defp promoted(thread, msg) do
    case running(thread) do
      nil ->
        %{thread | queue: [msg | List.delete(thread.queue, msg)]}

      active ->
        %{thread | queue: List.delete(thread.queue, msg)}
        |> set_runs(&if(&1.msg == msg, do: %{&1 | status: :cancelled}, else: &1))
        |> update_in([:messages, msg], &%{&1 | run: active.msg, shown: true})
        |> end_running(:completed)
        |> start_next()
    end
  end

  defp model_projection(nil), do: nil

  defp model_projection(thread) do
    %{
      status: thread.status,
      title: thread.title,
      runs: for(run <- thread.runs, do: {run.msg, Atom.to_string(run.status), run.held}),
      queue: thread.queue,
      messages:
        Map.new(thread.messages, fn {id, m} ->
          shown = if m.shown, do: {m.run, if(m.notice, do: "notification", else: "user_message")}
          {id, {m.text, m.run, shown}}
        end)
    }
  end

  # --- commands ---------------------------------------------------------------------

  def create(tid) do
    reply(
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => tid,
        "projectId" => "project-1",
        "title" => "Thread #{tid}",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => Process.get(:work)
      }),
      []
    )
  end

  def send(tid, msg, mode) do
    ending = active_runs(tid)
    result = Orchestration.dispatch(message(tid, msg, mode))
    # Only a run the message steered or restarted ends.
    reply(
      result,
      if(match?({:ok, _}, result) and mode in [:auto, :restart], do: ending, else: [])
    )
  end

  # The same message again, as first sent; a message the thread has ends no run.
  def resend(tid, msg, mode), do: reply(Orchestration.dispatch(message(tid, msg, mode)), [])

  defp message(tid, msg, mode) do
    extra =
      case mode do
        :queue ->
          %{"dispatchMode" => %{"type" => "queue_after_active"}}

        # As `Delegation` sends a task's result: for the agent, once the thread is free.
        :notice ->
          %{
            "dispatchMode" => %{"type" => "queue_after_active"},
            "createdBy" => "system",
            "creationSource" => "server",
            "notification" => %{
              "source" => %{"kind" => "delegated_task", "taskIds" => ["task-#{msg}"]},
              "outcome" => "completed",
              "summary" => "#{msg} finished"
            }
          }

        :auto ->
          %{"dispatchMode" => %{"type" => "start_immediately"}, "deliveryIntent" => "auto"}

        :restart ->
          %{"dispatchMode" => %{"type" => "start_immediately"}, "deliveryIntent" => "restart"}
      end

    Map.merge(
      %{
        "type" => "message.dispatch",
        "threadId" => tid,
        "messageId" => msg,
        "text" => "wait #{msg}",
        "attachments" => []
      },
      extra
    )
  end

  def rename(tid, title),
    do: thread_command(%{"type" => "thread.metadata.update", "threadId" => tid, "title" => title})

  def archive(tid), do: thread_command(%{"type" => "thread.archive", "threadId" => tid})
  def unarchive(tid), do: thread_command(%{"type" => "thread.unarchive", "threadId" => tid})
  def delete(tid), do: thread_command(%{"type" => "thread.delete", "threadId" => tid})
  def resume(tid), do: thread_command(%{"type" => "queue.resume", "threadId" => tid})

  def interrupt(tid) do
    ending = active_runs(tid)
    reply(Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => tid}), ending)
  end

  def cancel(tid, msg),
    do:
      thread_command(%{
        "type" => "queued-run.cancel",
        "threadId" => tid,
        "runId" => run_of(tid, msg)
      })

  def edit(tid, msg, text),
    do:
      thread_command(%{
        "type" => "queued-run.edit",
        "threadId" => tid,
        "runId" => run_of(tid, msg),
        "text" => text
      })

  def reorder(tid, msg, before),
    do:
      thread_command(%{
        "type" => "queued-run.reorder",
        "threadId" => tid,
        "runId" => run_of(tid, msg),
        "beforeRunId" => before && run_of(tid, before)
      })

  def promote(tid, msg) do
    ending = active_runs(tid)

    result =
      Orchestration.dispatch(%{
        "type" => "queued-message.promote-to-steer",
        "threadId" => tid,
        "queuedRunId" => run_of(tid, msg),
        "targetRunId" => List.first(ending)
      })

    reply(result, if(match?({:ok, _}, result), do: ending, else: []))
  end

  def release(tid) do
    case Orchestration.release_session(tid) do
      :ok -> reply({:ok, %{}}, [])
      :busy -> reply({:error, :busy}, [])
    end
  end

  # The runtime driving the thread's turn dies, as a crash in its adapter would.
  def crash(tid) do
    ending = active_runs(tid)

    case Registry.lookup(HalC2.Codex.Registry, tid) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end

    reply({:ok, %{}}, ending)
  end

  # The MC stops with turns running and boots again: provider runtimes go without
  # ending their turns, the streams come back from the store, and boot recovery
  # settles what was running.
  def restart do
    HalC2.Prop.restart_service(HalC2.Codex.Supervisor)
    HalC2.Prop.restart_service(HalC2.Orchestration.TurnWatch)
    HalC2.Prop.restart_service(HalC2.Streams)
    # The streams wrote their sidebar rows as they stopped.
    _ = :sys.get_state(HalC2.Shell)
    subscribe()
    HalC2.Orchestration.Recovery.run()
    HalC2.Orchestration.Recovery.continue()
    reply({:ok, %{}}, [])
  end

  defp thread_command(command), do: reply(Orchestration.dispatch(command), [])

  # --- the real side ----------------------------------------------------------------

  defp subscribe, do: for(tid <- @threads, do: :ok = HalC2.Streams.subscribe(tid, self(), nil))

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp active_runs(tid),
    do: for(run <- runs(current(tid)), run["status"] in @active, do: run["id"])

  defp run_of(tid, msg) do
    case Enum.find(runs(current(tid)), &(&1["userMessageId"] == msg)) do
      %{"id" => id} -> id
      nil -> "run-of-#{msg}"
    end
  end

  # The command's reply, and every thread as it is once the command's effects landed.
  defp reply(result, ending) do
    reply =
      case result do
        {:ok, %{}} -> :ok
        {:error, message} -> {:error, message}
        other -> {:unexpected, other}
      end

    deadline = System.monotonic_time(:millisecond) + @wait_ms
    {reply, Map.new(@threads, &{&1, settled(&1, ending, deadline)})}
  end

  # Waits on the thread's stream until no run is starting and the runs in `ending` have
  # ended. A run's end starts the next queued one off the runtime's process, so when
  # one of this thread's runs ended, it also waits until a thread with nothing running
  # has no queued run that could start (an archived one starts none).
  defp settled(tid, ending, deadline) do
    flush(tid)
    state = current(tid)
    runs = runs(state)
    by_id = Map.new(runs, &{&1["id"], &1})
    ending = Enum.filter(ending, &Map.has_key?(by_id, &1))
    archived? = (StreamState.get(state, "thread")[tid] || %{})["archivedAt"] != nil

    quiet? =
      not Enum.any?(runs, &(&1["status"] in ~w(preparing starting))) and
        Enum.all?(ending, &(by_id[&1]["status"] not in @active)) and
        (ending == [] or archived? or Enum.any?(runs, &(&1["status"] in ~w(running waiting))) or
           not Enum.any?(runs, &(&1["status"] == "queued" and &1["queueHeld"] != true)))

    if quiet? do
      projection(state, tid)
    else
      receive do
        {:hal_c2_stream, ^tid, _} -> settled(tid, ending, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          {:timeout, projection(state, tid)}
      end
    end
  end

  defp flush(tid) do
    receive do
      {:hal_c2_stream, ^tid, _} -> flush(tid)
    after
      0 -> :ok
    end
  end

  defp projection(state, tid) do
    case StreamState.get(state, "thread")[tid] do
      nil ->
        nil

      thread ->
        runs = runs(state)
        by_id = Map.new(runs, &{&1["id"], &1})
        items = StreamState.get(state, "turn-item")
        queued = Enum.filter(runs, &(&1["status"] == "queued"))
        positions = queued |> Enum.map(& &1["queuePosition"]) |> Enum.sort()

        # Positions are 1..n over the queued runs and nil on the rest.
        queue =
          if positions == Enum.to_list(1..length(queued)//1) and
               Enum.all?(runs, &(&1["status"] == "queued" or &1["queuePosition"] == nil)),
             do: queued |> Enum.sort_by(& &1["queuePosition"]) |> Enum.map(& &1["userMessageId"]),
             else:
               {:bad_positions,
                Enum.map(runs, &{&1["userMessageId"], &1["status"], &1["queuePosition"]})}

        messages =
          for {id, %{"role" => "user"} = m} <- StreamState.get(state, "message"), into: %{} do
            item = items["turn-item:user:#{id}"]

            # Where the transcript has the message, and as what; a notification says
            # what the message reports and none of its text.
            shown =
              cond do
                item == nil ->
                  nil

                item["type"] == "notification" and item["summary"] != m["notification"]["summary"] ->
                  {:bad_item, item}

                item["type"] == "notification" and Map.has_key?(item, "text") ->
                  {:bad_item, item}

                true ->
                  {by_id[item["runId"]]["userMessageId"], item["type"]}
              end

            {id, {m["text"], by_id[m["runId"]]["userMessageId"], shown}}
          end

        %{
          status:
            cond do
              thread["deletedAt"] -> :deleted
              thread["archivedAt"] -> :archived
              true -> :live
            end,
          title: thread["title"],
          runs:
            for(run <- runs, do: {run["userMessageId"], run["status"], run["queueHeld"] == true}),
          queue: queue,
          messages: messages
        }
    end
  end
end
