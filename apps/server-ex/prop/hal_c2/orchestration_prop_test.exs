defmodule HalC2.OrchestrationPropTest do
  @moduledoc """
  A state machine over two threads driven through the orchestration commands a client
  sends: create, rename, archive, unarchive and delete a thread; send a message that
  starts a turn, waits in the queue, steers the running turn or restarts it; have the
  MC send the agent a message of its own (a `notification`, as a delegated task's
  result is); send a message again with its message id, as a client retrying after a
  reconnect does, or send the same steer twice at once;
  cancel, edit, reorder and promote queued messages (and have Codex refuse to take a
  promoted one, also after the thread was archived while Codex was asked); resume a held queue; interrupt a turn, or the run of a message as a
  client that read it as active does (#403, #474);
  crash a provider runtime mid-turn; release a thread's provider session as
  IdleSessions does; and restart the MC mid-turn (boot recovery). A message can also
  stop its turn on a usage limit, which holds the queue behind it; the user can then
  choose to resume at the reset, and the limit recovery sweep at the reset resumes the
  held queue, or sends "Continue where you left off." when nothing was held.

  Each message names one of two Codex instances (`codex`, and `codex-work` from the
  settings); a message for the instance the running turn is not on never joins it, and
  the thread is on the instance of the run that started last.

  Turns run on the fake Codex app-server in `test/support/fake_codex.py`. Every
  message says "wait", so its turn runs until it is interrupted or steered, and the
  model knows exactly which turn runs; only a "usage limit" message, whose turn fails
  as it starts, and the continuation, which completes, do not. After each command the test waits on the
  threads' streams until nothing is starting and the runs the command ended have
  ended, then compares each thread's projection with the model: thread state, runs
  and their statuses in ordinal order (the order they started), the queue's order and
  positions, at most one active run, and every user message exactly once, in the run
  it belongs to. A message that steered a turn reached Codex once (the fake logs every
  `turn/steer`) and is in the transcript ahead of the answer it got. A message of the
  MC's own is in the transcript as a notification, never as a user message, and while
  it is queued it cannot be edited or made to steer.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @threads ~w(t1 t2)
  @instances ~w(codex codex-work)
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
        log = Path.join(home, "codex-requests.log")
        Process.put(:codex_log, log)
        Process.put(:reject_steer, Path.join(home, "reject-steer"))
        Process.put(:hold_steer, Path.join(home, "hold-steer"))
        Process.put(:refused_steers, [])
        Process.put(:steer_log, {0, []})

        Application.put_env(:hal_c2, :codex_command, [
          "env",
          "FAKE_CODEX_LOG=#{log}",
          "FAKE_CODEX_REJECT_STEER=#{Process.get(:reject_steer)}",
          "FAKE_CODEX_HOLD_STEER=#{Process.get(:hold_steer)}",
          "python3",
          "-u",
          @fake_codex
        ])

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
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          HalC2.Settings
        ])

        # Each instance's fake Codex names its threads and turns after the instance and
        # cannot resume another's thread, as a Codex in another home cannot.
        named = &[%{"name" => "FAKE_CODEX_INSTANCE", "value" => &1}]

        {:ok, _} =
          HalC2.Settings.put(
            %{
              "providerInstances" => %{
                "codex" => %{"environment" => named.("codex")},
                "codex-work" => %{
                  "driver" => "codex",
                  "enabled" => true,
                  "environment" => named.("codex-work")
                }
              }
            },
            0
          )

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

  # threads: id -> %{status: :live | :archived | :deleted, title, instance, runs, queue,
  #   messages}
  #   instance: the instance of the run that started last, else the one it was created on;
  #   runs: [%{msg, status, held, instance}] in ordinal order: a run is made last, and
  #     when it starts it goes after every run that left the queue, with the runs still
  #     queued after it in queue order (`in_start_order/2`);
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
       {:call, __MODULE__, :send,
        [
          tid,
          msg,
          oneof([:queue, :queue, :auto, :restart, :notice, :limit, :limit]),
          oneof(@instances)
        ]}},
      {2, {:call, __MODULE__, :steer_twice, [tid, msg, oneof(@instances)]}},
      {1, {:call, __MODULE__, :rename, [tid, oneof(["Alpha", "Beta"])]}},
      {1, {:call, __MODULE__, :recover, [tid]}},
      {1, {:call, __MODULE__, :sweep, []}},
      {1, {:call, __MODULE__, :archive, [tid]}},
      {1, {:call, __MODULE__, :unarchive, [tid]}},
      {1, {:call, __MODULE__, :delete, [tid]}},
      {3, {:call, __MODULE__, :interrupt, [tid]}},
      {1, {:call, __MODULE__, :resume, [tid]}},
      {1, {:call, __MODULE__, :release, [tid]}}
    ]

    # The test's own messages; the continuation's real id is not "resume:<msg>".
    sent =
      for {t, %{messages: m}} <- threads,
          id <- Map.keys(m),
          not String.starts_with?(id, "resume:"),
          do: {t, id}

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
             do: {:call, __MODULE__, :edit, [t, m, "wait #{m} edit #{k}"]}
           )},
          {2,
           let(
             [{t, m} <- oneof(sent), {_, before} <- oneof([{nil, nil} | sent])],
             do: {:call, __MODULE__, :reorder, [t, m, before]}
           )},
          {3,
           let(
             [{t, m} <- oneof(sent), how <- oneof([:taken, :taken, :refused])],
             do: {:call, __MODULE__, :promote, [t, m, how]}
           )},
          {2, let({t, m} <- oneof(sent), do: {:call, __MODULE__, :interrupt_run, [t, m]})}
        ]

    # A promote is worth aiming at a message that is still queued.
    queued = for {t, thread} <- threads, m <- thread.queue, do: {t, m}

    on_queued =
      if queued == [],
        do: [],
        else: [
          {3,
           let(
             [{t, m} <- oneof(queued), how <- oneof([:taken, :refused])],
             do: {:call, __MODULE__, :promote, [t, m, how]}
           )}
        ]

    # Archiving while Codex is asked needs Codex to be asked: a running turn that can
    # take the message.
    steerable = for {t, thread} <- threads, m <- thread.queue, steers?(thread, m), do: {t, m}

    on_queued =
      if steerable == [],
        do: on_queued,
        else: [
          {2,
           let({t, m} <- oneof(steerable), do: {:call, __MODULE__, :promote, [t, m, :archived]})}
          | on_queued
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

    # A limit stop is worth choosing to resume, and an armed resume worth reaching.
    limited = for {t, thread} <- threads, limited(thread) != nil, do: t
    armed = for {_, thread} <- threads, thread.recovery != nil, do: thread

    on_limits =
      if(limited == [], do: [], else: [{4, {:call, __MODULE__, :recover, [oneof(limited)]}}]) ++
        if armed == [], do: [], else: [{4, {:call, __MODULE__, :sweep, []}}]

    frequency(always ++ on_messages ++ on_queued ++ on_running ++ on_limits)
  end

  def precondition(%{threads: threads}, {:call, _, :crash, [tid]}),
    do: threads[tid] != nil and running(threads[tid]) != nil

  def precondition(%{threads: threads}, {:call, _, :release, [tid]}),
    do: threads[tid] != nil

  def precondition(%{threads: threads}, {:call, _, :recover, [tid]}),
    do: match?(%{status: :live}, threads[tid])

  def precondition(%{threads: threads}, {:call, _, :restart, []}),
    do: Enum.any?(threads, fn {_, t} -> running(t) != nil end)

  def precondition(%{threads: threads}, {:call, _, :promote, [tid, msg, :archived]}),
    do:
      match?(%{status: :live}, threads[tid]) and msg in threads[tid].queue and
        steers?(threads[tid], msg)

  def precondition(%{threads: threads}, {:call, _, fun, [tid, msg | _]})
      when fun in [:cancel, :edit, :reorder, :promote, :resend, :interrupt_run],
      do: Map.has_key?((threads[tid] || %{messages: %{}}).messages, msg)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :send, [tid, msg, mode, instance]}) do
    state = %{state | next: state.next + 1}

    case refusal(state, tid, :send) do
      nil -> update(state, tid, &sent(&1, msg, mode, instance))
      _ -> state
    end
  end

  # The second of two identical sends finds the first: they are one send.
  def next_state(state, result, {:call, m, :steer_twice, [tid, msg, instance]}),
    do: next_state(state, result, {:call, m, :send, [tid, msg, :auto, instance]})

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
          instance: "codex",
          runs: [],
          queue: [],
          messages: %{},
          recovery: nil
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

  # A stop pinned to a message's run ends only that run's turn: one that ended, or
  # never started, leaves whatever runs now.
  def next_state(state, _result, {:call, _, :interrupt_run, [tid, msg]}) do
    if pinned_running?(state, tid, msg),
      do: update(state, tid, &(&1 |> end_running(:interrupted) |> start_next())),
      else: state
  end

  def next_state(state, _result, {:call, _, :crash, [tid]}),
    do: update(state, tid, &(&1 |> end_running(:failed) |> start_next()))

  def next_state(state, _result, {:call, _, :restart, []}) do
    threads =
      Map.new(state.threads, fn {tid, thread} ->
        # Boot recovery opens the threads whose sidebar row shows a run in flight: one
        # running, or a latest run still queued. Their queues wait for the user to
        # resume them; an idle queue elsewhere starts nothing at boot anyway.
        opened? = running(thread) != nil or match?(%{status: :queued}, latest(thread))
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

  # Resume at the reset: armed for the limit stop that is the thread's latest run.
  def next_state(state, _result, {:call, _, :recover, [tid]}) do
    case limited(state.threads[tid]) do
      %{msg: msg} -> update(state, tid, &%{&1 | recovery: msg})
      nil -> state
    end
  end

  # At the reset, a live thread armed for its current limit stop resumes the queue the
  # stop held, or is sent a continuation (which completes) when it held none.
  def next_state(state, _result, {:call, _, :sweep, []}) do
    threads =
      Map.new(state.threads, fn {tid, thread} ->
        case limited(thread) do
          %{msg: msg} when thread.status == :live and thread.recovery == msg ->
            {tid, recovered(thread, msg)}

          _ ->
            {tid, thread}
        end
      end)

    %{state | threads: threads}
  end

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

  # Codex is asked to take the message, the thread is archived meanwhile, and then
  # Codex refuses: the message is not queued again, and the turn runs on.
  def next_state(state, _result, {:call, _, :promote, [tid, msg, :archived]}) do
    update(state, tid, fn thread ->
      %{thread | queue: List.delete(thread.queue, msg)}
      |> set_runs(&if(&1.msg == msg, do: %{&1 | status: :cancelled}, else: &1))
      |> cancel_queue()
      |> Map.put(:status, :archived)
    end)
  end

  def next_state(state, _result, {:call, _, :promote, [tid, msg, how]}) do
    case promote_refusal(state, tid, msg) do
      nil -> update(state, tid, &promoted(&1, msg, how))
      _ -> state
    end
  end

  def postcondition(state, {:call, _, fun, args}, {reply, projection}) do
    expected = expected_reply(state, fun, args)
    next = next_state(state, nil, {:call, __MODULE__, fun, args})
    wanted = Map.new(@threads, &{&1, model_projection(next.threads[&1])})

    wanted =
      if fun in [:archive, :unarchive, :delete],
        do: Map.put(wanted, :archived, archived(next)),
        else: wanted

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

      %{status: :archived, title: title} when command == :archive ->
        {:error, "#{title} is already archived."}

      %{status: status, title: title} when command == :unarchive and status != :archived ->
        {:error, "#{title} is not archived."}

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

  defp expected_reply(state, fun, [tid | _]) when fun in [:send, :steer_twice],
    do: refusal(state, tid, :send) || :ok

  defp expected_reply(state, :rename, [tid, _]), do: refusal(state, tid, :rename) || :ok

  defp expected_reply(state, fun, [tid])
       when fun in [:archive, :unarchive, :delete, :interrupt],
       do: refusal(state, tid, fun) || :ok

  defp expected_reply(state, :edit, [tid, msg, _]),
    do: refusal(state, tid, :queue) || agents_own(state, tid, msg) || :ok

  defp expected_reply(state, fun, [tid | _]) when fun in [:resume, :cancel, :reorder],
    do: refusal(state, tid, :queue) || :ok

  defp expected_reply(_state, :promote, [_tid, _msg, :archived]),
    do: {:error, :archived_meanwhile}

  defp expected_reply(state, :promote, [tid, msg, _how]),
    do: promote_refusal(state, tid, msg) || :ok

  defp expected_reply(state, :recover, [tid]),
    do:
      if(limited(state.threads[tid]),
        do: :ok,
        else: {:error, "The provider limit changed before recovery could be configured."}
      )

  defp expected_reply(_state, :resend, _args), do: :ok

  defp expected_reply(state, :interrupt_run, [tid, msg]),
    do: if(pinned_running?(state, tid, msg), do: :ok, else: {:error, "no running turn"})

  defp expected_reply(state, :release, [tid]),
    do: if(running(state.threads[tid]), do: {:error, :busy}, else: :ok)

  defp expected_reply(_state, _fun, _args), do: :ok

  defp reply_matches?({:error, :not_queued}, {:error, message}),
    do: message =~ ~r/^Queued run \S+ is not queued\.$/

  defp reply_matches?({:error, :agents_own}, {:error, message}),
    do: message =~ ~r/^Queued run \S+ is the agent's own message/

  defp reply_matches?({:error, :archived_meanwhile}, {:error, message}),
    do: message =~ ~r/not queued again: the thread was archived\.$/

  defp reply_matches?(expected, reply), do: expected == reply

  defp update(state, tid, fun), do: update_in(state.threads[tid], fun)

  defp set_runs(thread, fun), do: %{thread | runs: Enum.map(thread.runs, fun)}

  defp running(thread), do: Enum.find(thread.runs, &(&1.status == :running))

  defp pinned_running?(state, tid, msg),
    do:
      refusal(state, tid, :interrupt) == nil and
        match?(%{msg: ^msg}, running(state.threads[tid]))

  # A promote of this queued message asks the running turn's provider to take it.
  defp steers?(thread, msg) do
    run = running(thread)

    run != nil and not thread.messages[msg].notice and
      Enum.find(thread.runs, &(&1.msg == msg)).instance == run.instance
  end

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
      |> Map.put(:instance, Enum.find(thread.runs, &(&1.msg == next)).instance)
      |> put_in([:messages, next, :shown], true)
      |> started(next)
    else
      _ -> thread
    end
  end

  # A message's run starts and runs, or, for a "usage limit" message, fails at once and
  # holds every queued message for the user.
  defp started(thread, msg) do
    thread = in_start_order(thread, msg)

    if limit_text?(thread.messages[msg].text) do
      thread
      |> set_runs(fn run ->
        cond do
          run.msg == msg -> %{run | status: :failed}
          run.msg in thread.queue -> %{run | held: true}
          true -> run
        end
      end)
    else
      set_runs(thread, &if(&1.msg == msg, do: %{&1 | status: :running}, else: &1))
    end
  end

  defp limit_text?(text), do: String.starts_with?(text, "usage limit")

  # Runs are numbered in the order they start: the starting run takes the ordinal after
  # every run that left the queue (started, or cancelled while queued), and the runs
  # still queued move up behind it in queue order.
  defp in_start_order(thread, msg) do
    {[run], others} = Enum.split_with(thread.runs, &(&1.msg == msg))
    {waiting, left} = Enum.split_with(others, &(&1.status == :queued))
    position = thread.queue |> Enum.with_index() |> Map.new()
    waiting = Enum.sort_by(waiting, &Map.get(position, &1.msg))
    %{thread | runs: left ++ [run] ++ waiting}
  end

  # The thread's latest run, passing over runs held for the user that never started
  # (still queued, or cancelled while held).
  defp latest(thread),
    do:
      thread.runs
      |> Enum.reverse()
      |> Enum.find(&(not &1.held or &1.status not in [:queued, :cancelled]))

  # The thread's latest run when it is a limit stop, else nil.
  defp limited(nil), do: nil

  defp limited(thread) do
    case latest(thread) do
      %{status: :failed, msg: msg} = run ->
        if limit_text?(thread.messages[msg].text), do: run

      _ ->
        nil
    end
  end

  # The recovery at the reset: the held queue resumes, or a continuation runs to its end.
  defp recovered(thread, msg) do
    if Enum.any?(thread.runs, &(&1.msg in thread.queue and &1.held)) do
      thread
      |> set_runs(&if(&1.msg in thread.queue, do: %{&1 | held: false}, else: &1))
      |> start_next()
    else
      resume = "resume:#{msg}"
      run = %{msg: resume, status: :completed, held: false, instance: thread.instance}

      message = %{
        text: "Continue where you left off.",
        run: resume,
        shown: true,
        notice: false
      }

      %{thread | runs: thread.runs ++ [run]}
      |> in_start_order(resume)
      |> put_in([:messages, resume], message)
    end
  end

  defp sent(thread, msg, mode, instance) do
    active = running(thread)
    text = if mode == :limit, do: "usage limit #{msg}", else: "wait #{msg}"
    message = %{text: text, run: msg, shown: false, notice: mode == :notice}
    run = %{msg: msg, status: :queued, held: false, instance: instance}

    cond do
      active == nil ->
        %{thread | runs: thread.runs ++ [run], instance: instance}
        |> put_in([:messages, msg], %{message | shown: true})
        |> started(msg)

      mode == :auto and active.instance == instance ->
        # The fake ends a turn it is steered into.
        thread
        |> put_in([:messages, msg], %{message | run: active.msg, shown: true})
        |> end_running(:completed)
        |> start_next()

      mode == :restart ->
        %{thread | runs: thread.runs ++ [run], queue: [msg | thread.queue]}
        |> put_in([:messages, msg], message)
        |> end_running(:interrupted)
        |> start_next()

      true ->
        %{thread | runs: thread.runs ++ [run], queue: thread.queue ++ [msg]}
        |> put_in([:messages, msg], message)
    end
  end

  # A queued message steers the running turn, or goes first in the queue when no turn
  # runs. One for another instance, or one the provider refuses to take, interrupts the
  # running turn and goes first.
  defp promoted(thread, msg, how) do
    instance = Enum.find(thread.runs, &(&1.msg == msg)).instance

    case running(thread) do
      nil ->
        %{thread | queue: [msg | List.delete(thread.queue, msg)]}

      %{instance: other} when other != instance or how == :refused ->
        %{thread | queue: [msg | List.delete(thread.queue, msg)]}
        |> end_running(:interrupted)
        |> start_next()

      active ->
        %{thread | queue: List.delete(thread.queue, msg)}
        |> set_runs(&if(&1.msg == msg, do: %{&1 | status: :cancelled}, else: &1))
        |> update_in([:messages, msg], &%{&1 | run: active.msg, shown: true})
        |> end_running(:completed)
        |> start_next()
    end
  end

  defp archived(state),
    do: for({tid, %{status: :archived}} <- state.threads, do: tid) |> Enum.sort()

  defp model_projection(nil), do: nil

  defp model_projection(thread) do
    %{
      status: thread.status,
      title: thread.title,
      instance: thread.instance,
      runs:
        for(
          run <- thread.runs,
          do: {run.msg, Atom.to_string(run.status), run.held, run.instance}
        ),
      queue: thread.queue,
      foreign: [],
      messages:
        Map.new(thread.messages, fn {id, m} ->
          shown = if m.shown, do: {m.run, if(m.notice, do: "notification", else: "user_message")}
          {id, {m.text, m.run, shown}}
        end),
      steered: for({id, m} <- thread.messages, m.run != id, do: m.text) |> Enum.sort()
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

  def send(tid, msg, mode, instance) do
    ending = active_runs(tid)
    steers = active_runs(tid, instance)
    result = Orchestration.dispatch(message(tid, msg, mode, instance))
    # Only a run the message steered or restarted ends.
    reply(
      result,
      cond do
        not match?({:ok, _}, result) -> []
        mode == :restart -> ending
        mode == :auto -> steers
        true -> []
      end
    )
  end

  # The same steer sent twice at once, as a client retrying while the first is still on
  # its way: Codex holds the first (`hold-steer`, as a refused-archived promote does)
  # until the repeat has been decided, so the overlap does not depend on the
  # scheduler. Both are answered alike.
  def steer_twice(tid, msg, instance) do
    steers = active_runs(tid, instance)
    command = message(tid, msg, :auto, instance)
    File.touch!(Process.get(:hold_steer))
    first = Task.async(fn -> Orchestration.dispatch(command) end)

    results =
      case asked(tid, msg, first) do
        :asked ->
          repeat = Orchestration.dispatch(command)
          File.rm!(Process.get(:hold_steer))
          [Task.await(first, @wait_ms), repeat]

        {:done, one} ->
          File.rm!(Process.get(:hold_steer))
          [one, Orchestration.dispatch(command)]

        :timeout ->
          File.rm!(Process.get(:hold_steer))
          [Task.await(first, @wait_ms), Orchestration.dispatch(command)]
      end

    result =
      case Enum.uniq_by(results, &outcome/1) do
        [one] -> one
        both -> {:unexpected, both}
      end

    reply(result, if(match?({:ok, _}, result), do: steers, else: []))
  end

  # The same message again, as first sent; a message the thread has ends no run.
  def resend(tid, msg, mode),
    do: reply(Orchestration.dispatch(message(tid, msg, mode, "codex")), [])

  defp message(tid, msg, mode, instance) do
    extra =
      case mode do
        mode when mode in [:queue, :limit] ->
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
        "text" => if(mode == :limit, do: "usage limit #{msg}", else: "wait #{msg}"),
        "attachments" => [],
        "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"}
      },
      extra
    )
  end

  def rename(tid, title),
    do: thread_command(%{"type" => "thread.metadata.update", "threadId" => tid, "title" => title})

  def archive(tid), do: archive_command(%{"type" => "thread.archive", "threadId" => tid})
  def unarchive(tid), do: archive_command(%{"type" => "thread.unarchive", "threadId" => tid})
  def delete(tid), do: archive_command(%{"type" => "thread.delete", "threadId" => tid})
  def resume(tid), do: thread_command(%{"type" => "queue.resume", "threadId" => tid})

  # Resume at the reset, as the limit banner asks for the thread's current stop.
  def recover(tid) do
    shell = HalC2.Projection.Shell.thread_shell(current(tid))

    thread_command(%{
      "type" => "thread.metadata.update",
      "commandId" => "recover-#{System.unique_integer([:positive])}",
      "threadId" => tid,
      "limitRecovery" => %{
        "runId" => shell["latestRunId"],
        "resetAt" => shell["usageLimitResetAt"],
        "autoResume" => true
      }
    })
  end

  # The limit recovery sweep a week on, when every reset the fake reports has passed.
  def sweep do
    for tid <- @threads, do: HalC2.Streams.flush_shell(tid)
    HalC2.Orchestration.LimitRecovery.sweep(System.system_time(:millisecond) + 7 * 86_400_000)
    reply({:ok, %{}}, [])
  end

  def interrupt(tid) do
    ending = active_runs(tid)
    reply(Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => tid}), ending)
  end

  def interrupt_run(tid, msg) do
    run_id = run_of(tid, msg)
    ending = Enum.filter(active_runs(tid), &(&1 == run_id))

    reply(
      Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => tid, "runId" => run_id}),
      ending
    )
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

  # Codex holds the promoted message's `turn/steer` until the thread is archived, then
  # refuses it.
  def promote(tid, msg, :archived) do
    asked = steer_requests()
    File.touch!(Process.get(:hold_steer))
    File.touch!(Process.get(:reject_steer))

    task =
      Task.async(fn ->
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => tid,
          "queuedRunId" => run_of(tid, msg),
          "targetRunId" => List.first(active_runs(tid))
        })
      end)

    result =
      case asked(tid, msg, task) do
        {:done, result} ->
          File.rm!(Process.get(:hold_steer))
          result

        asked ->
          if asked == :asked,
            do:
              {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => tid})

          File.rm!(Process.get(:hold_steer))
          Task.await(task, @wait_ms)
      end

    File.rm!(Process.get(:reject_steer))
    Process.put(:refused_steers, Process.get(:refused_steers) ++ (steer_requests() -- asked))
    reply(result, [])
  end

  # A refused promote has Codex refuse every `turn/steer` it is sent meanwhile; their
  # texts are taken back off the ones Codex took (`provider_steers/1`).
  def promote(tid, msg, how) do
    ending = active_runs(tid)
    reject = Process.get(:reject_steer)
    asked = steer_requests()
    if how == :refused, do: File.touch!(reject)

    result =
      Orchestration.dispatch(%{
        "type" => "queued-message.promote-to-steer",
        "threadId" => tid,
        "queuedRunId" => run_of(tid, msg),
        "targetRunId" => List.first(ending)
      })

    if how == :refused do
      File.rm!(reject)
      Process.put(:refused_steers, Process.get(:refused_steers) ++ (steer_requests() -- asked))
    end

    reply(result, if(match?({:ok, _}, result), do: ending, else: []))
  end

  # `:asked` once the promote put the message in the turn, and so asks Codex; its reply
  # if it ended first.
  defp asked(tid, msg, %Task{ref: ref} = task) do
    if StreamState.get(current(tid), "turn-item")["turn-item:user:#{msg}"] do
      :asked
    else
      receive do
        {:hal_c2_stream, ^tid, _} ->
          asked(tid, msg, task)

        {^ref, result} ->
          Process.demonitor(ref, [:flush])
          {:done, result}
      after
        @wait_ms -> :timeout
      end
    end
  end

  def release(tid) do
    case Orchestration.release_session(tid) do
      :ok ->
        # Released means gone from the registry too, not only dead: the next message
        # looks the session up first.
        case Registry.lookup(HalC2.Codex.Registry, tid) do
          [] -> :ok
          held -> raise("the released session of #{tid} is still registered: #{inspect(held)}")
        end

        reply({:ok, %{}}, [])

      :busy ->
        reply({:error, :busy}, [])
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

  # The archived threads as a client that asks right after the command's reply gets
  # them (`orchestration.getArchivedShellSnapshot`): no waiting on the sidebar rows.
  defp archive_command(command) do
    result = Orchestration.dispatch(command)

    {:ok, %{"threads" => threads}} =
      Orchestration.handle("orchestration.getArchivedShellSnapshot", %{})

    {reply, projection} = reply(result, [])
    {reply, Map.put(projection, :archived, threads |> Enum.map(& &1["id"]) |> Enum.sort())}
  end

  # --- the real side ----------------------------------------------------------------

  defp subscribe, do: for(tid <- @threads, do: :ok = HalC2.Streams.subscribe(tid, self(), nil))

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp active_runs(tid, instance \\ nil),
    do:
      for(
        run <- runs(current(tid)),
        run["status"] in @active and instance in [nil, run["providerInstanceId"]],
        do: run["id"]
      )

  defp run_of(tid, msg) do
    case Enum.find(runs(current(tid)), &(&1["userMessageId"] == msg)) do
      %{"id" => id} -> id
      nil -> "run-of-#{msg}"
    end
  end

  # The command's reply, and every thread as it is once the command's effects landed.
  defp reply(result, ending) do
    reply = outcome(result)
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    {reply, Map.new(@threads, &{&1, settled(&1, ending, deadline)})}
  end

  defp outcome({:ok, %{}}), do: :ok
  defp outcome({:error, message}), do: {:error, message}
  defp outcome(other), do: {:unexpected, other}

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
    texts = StreamState.get(state, "message")

    # Only a "wait" message's turn runs on; the rest (a limit stop, the continuation) end.
    ending? = fn run ->
      run["status"] in @active and
        not String.contains?((texts[run["userMessageId"]] || %{})["text"] || "", "wait")
    end

    quiet? =
      not Enum.any?(runs, &(&1["status"] in ~w(preparing starting))) and
        not Enum.any?(runs, ending?) and
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
        # The continuation's id names the stop it continues; the model calls it
        # "resume:<the stop's message>".
        stops = Map.new(runs(state), &{&1["id"], &1["userMessageId"]})

        rename = fn
          "limit-resume:" <> rest = id ->
            case Regex.run(~r/^[^:]+:(run:[^:]+):/, rest) do
              [_, run] -> "resume:#{stops[run]}"
              nil -> id
            end

          id ->
            id
        end

        runs = Enum.map(runs(state), &Map.update(&1, "userMessageId", nil, rename))
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

        user_messages =
          for {id, %{"role" => "user"} = m} <- StreamState.get(state, "message"), do: {id, m}

        messages =
          for {id, m} <- user_messages, into: %{} do
            item = items["turn-item:user:#{id}"]
            steered? = by_id[m["runId"]]["userMessageId"] != rename.(id)

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

                # The fake answers a steer in the turn it joined, after it.
                steered? and not answered_after?(items, item, m["text"]) ->
                  {:unanswered, item}

                true ->
                  {by_id[item["runId"]]["userMessageId"], item["type"]}
              end

            {rename.(id), {m["text"], by_id[m["runId"]]["userMessageId"], shown}}
          end

        %{
          status:
            cond do
              thread["deletedAt"] -> :deleted
              thread["archivedAt"] -> :archived
              true -> :live
            end,
          title: thread["title"],
          instance: thread["modelSelection"]["instanceId"],
          runs:
            for(
              run <- runs,
              do:
                {run["userMessageId"], run["status"], run["queueHeld"] == true,
                 run["providerInstanceId"]}
            ),
          queue: queue,
          foreign: foreign(state, runs),
          messages: messages,
          steered: provider_steers(Enum.map(user_messages, fn {_, m} -> m["text"] end))
        }
    end
  end

  # The runs whose provider turn or provider thread another instance's Codex made: a
  # run's turn runs on its own instance, in a provider thread of that instance's. A run
  # names its provider turn through its active attempt; one not started yet has none.
  defp foreign(state, runs) do
    attempts = StreamState.get(state, "run-attempt")
    turns = StreamState.get(state, "provider-turn")
    threads = StreamState.get(state, "provider-thread")

    for %{"providerInstanceId" => instance} = run <- runs,
        turn = turns[(attempts[run["activeAttemptId"]] || %{})["providerTurnId"]],
        thread = threads[run["providerThreadId"]] || %{},
        not String.starts_with?(native(turn["nativeTurnRef"]), "#{instance}-turn-") or
          not String.starts_with?(native(thread["nativeThreadRef"]), "#{instance}-thread-") or
          thread["providerInstanceId"] != instance,
        do: {run["userMessageId"], instance, thread["id"], native(thread["nativeThreadRef"])}
  end

  defp native(ref), do: (ref || %{})["nativeId"] || ""

  defp answered_after?(items, item, text) do
    Enum.any?(Map.values(items), fn answer ->
      answer["text"] == "steered: " <> text and answer["runId"] == item["runId"] and
        answer["ordinal"] > item["ordinal"]
    end)
  end

  # The texts of the `turn/steer` requests Codex took for these messages, once for
  # every request. Every generated text names its message (`wait m3`, `wait m3 edit
  # 1`), so a text is one message's, and a message steered twice is in the list twice.
  defp provider_steers(texts) do
    texts = MapSet.new(texts)

    (steer_requests() -- Process.get(:refused_steers))
    |> Enum.filter(&MapSet.member?(texts, &1))
    |> Enum.sort()
  end

  # The texts of every `turn/steer` Codex was sent, in order. Each call reads only
  # the lines the log gained since the last (`:steer_log` holds where it stopped and
  # what it read), up to the last complete one.
  defp steer_requests do
    {offset, texts} = Process.get(:steer_log)

    added =
      case File.open(Process.get(:codex_log), [:read, :binary]) do
        {:ok, io} ->
          {:ok, _} = :file.position(io, offset)
          data = IO.binread(io, :eof)
          File.close(io)
          if is_binary(data), do: data, else: ""

        {:error, :enoent} ->
          ""
      end

    complete =
      case :binary.matches(added, "\n") do
        [] -> ""
        newlines -> binary_part(added, 0, elem(List.last(newlines), 0) + 1)
      end

    texts =
      texts ++
        for line <- String.split(complete, "\n", trim: true),
            %{"method" => "turn/steer", "params" => params} <- [JSON.decode!(line)],
            do: hd(params["input"])["text"]

    Process.put(:steer_log, {offset + byte_size(complete), texts})
    texts
  end
end
