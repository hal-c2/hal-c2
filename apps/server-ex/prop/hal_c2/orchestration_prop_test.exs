defmodule HalC2.OrchestrationPropTest do
  @moduledoc """
  A state machine over two threads driven through the orchestration commands a client
  sends: create, rename, archive, unarchive and delete a thread; send a message that
  starts a turn, waits in the queue, steers the running turn or restarts it; have the
  MC send the agent a message of its own (a `notification`, as a delegated task's
  result is); send a message again with its message id, as a client retrying after a
  reconnect does, or send the same steer twice at once, which Codex takes or refuses:
  the repeat hears it is still being sent, and the first hears how it went;
  cancel, edit, reorder and promote queued messages (and have Codex refuse to take a
  promoted one, also after the thread was archived while Codex was asked); send a
  queued message now on an idle thread, held or not; resume a held queue; interrupt a turn, or the run of a message as a
  client that read it as active does (#403, #474), or as an agent does, which records
  the agent and its reason as who stopped the run;
  crash a provider runtime mid-turn, or end only its provider stream (the app-server
  exiting), which fails the run, unless the MC is shutting down, when the run is left
  for the next boot's recovery to settle; stop a run nothing drives any more, which
  settles it as interrupted with its checkpoint; release a thread's provider session as
  IdleSessions does; stop a thread as the plugin that started it does, after which no
  message queued at the stop ever starts, on it or on a task delegated from it, and the
  thread goes on as any other once the stop has passed it, also while a task below it
  is held up; and restart the MC mid-turn (boot recovery), also after a turn that had
  ended and was still capturing its checkpoint, which completes. A message can also
  stop its turn on a usage limit, which holds the queue behind it; the user can then
  choose to resume at the reset, and the limit recovery sweep at the reset resumes the
  held queue, or sends "Continue where you left off." when nothing was held.

  Codex can ask the user a question in its running turn, one it waits on or one
  answered by message, which the user answers, answers with a number where text
  belongs, or dismisses. A question Codex waits on is cancelled when the turn it was
  asked in ends however it ends, and expires at a restart, after which an answer hears
  the reason; one answered by message outlives both, and its answer reaches the agent
  as the user's message, steering the running turn or starting the next. A closed
  question refuses an answer and a dismissal.

  A thread can hold a proposed plan, which a message to it or to the other thread
  implements (the composer's "Implement it" and "Implement in a new thread"): the plan
  is completed once, and a second message for it is refused, also one sent while Codex
  still holds the first one's steer. A message that was refused gives its plan back,
  and a resend of one that implemented a plan is a resend like any other. The plan
  records the message that implemented it: a send that stops after claiming the plan,
  as at a crash, sends when it is resent, and only that message may.

  Each message names one of two Codex instances (`codex`, and `codex-work` from the
  settings); a message for the instance the running turn is not on never joins it, and
  the thread is on the instance of the run that started last. The agent can switch the
  thread to an instance, as `hal_c2_thread_configure` does: the turn in progress
  finishes where it is, and the MC's own messages, which name no instance, run on the
  one the thread is on when they start, never taking it back (#1048).

  Turns run on the fake Codex app-server in `test/support/fake_codex.py`, through the
  bundled Codex plugin as on an MC. Every
  message says "wait", so its turn runs until it is interrupted or steered, and the
  model knows exactly which turn runs; only a "usage limit" message, whose turn fails
  as it starts, and the continuation, which completes, do not. After each command the test waits on the
  threads' streams until nothing is starting and the runs the command ended have
  ended, then compares each thread's projection with the model: thread state, runs
  and their statuses in ordinal order (the order they started), the queue's order and
  positions, at most one active run, and every user message exactly once, in the run
  it belongs to, and the run a restart or a promote interrupted names the message's
  run (`steeredByRunId`). A message that steered a turn reached Codex once (the fake logs every
  `turn/steer`) and is in the transcript ahead of the answer it got. A message of the
  MC's own is in the transcript as a notification, never as a user message; it queues
  ahead of the user's messages, and while it is queued it cannot be edited, moved or
  made to steer, nor a message moved ahead of it. A message the user queues while the
  queue is held is held too, and the queue of an archived thread cannot be resumed.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @plugin "prop-plugin"
  @threads ~w(t1 t2)
  @instances ~w(codex codex-work)
  # An instance switched to but turned off in settings, which refuses the switch.
  @disabled "codex-off"
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000
  @restarts [:restart, :restart_stuck, :restart_capturing, :end_stream_leaving]

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
        Process.put(:hold_interrupt, Path.join(home, "hold-interrupt"))
        Process.put(:refused_steers, [])
        Process.put(:steer_log, {0, []})

        Application.put_env(:hal_c2, :bundled_plugins, [HalC2.Plugins.Bundled.Codex])

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
          HalC2.Orchestration.Effects,
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
          HalC2.Settings,
          HalC2.Plugins
        ])

        # A call behind the plugin host's first scan: Codex runs as the bundled plugin
        # it is on an MC, so its runtime is the plugin's module.
        _ = :sys.get_state(HalC2.Plugins)

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
                },
                @disabled => %{"driver" => "codex", "enabled" => false}
              }
            },
            0
          )

        subscribe()
        {history, state, result} = run_commands(__MODULE__, cmds)
        File.rm(Process.get(:hold_interrupt))
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)
        Application.delete_env(:hal_c2, :bundled_plugins)

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
  #   held_up: the thread whose last stop left a task held up, whose next commands favour it
  #   plans: plan -> %{status, by: the message that implemented it}
  #   off: the project turned codex-work off (every thread is project-1's)
  # lost: {thread, msg} -> {plan's thread, plan}, sends that stopped after claiming the plan
  # off: the project's own switch has codex-work off
  def initial_state, do: %{threads: %{}, next: 1, held_up: nil, lost: %{}, off: false}

  def command(%{threads: threads, next: next, held_up: held_up, lost: lost, off: off}) do
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
      {2,
       {:call, __MODULE__, :steer_twice,
        [tid, msg, oneof(@instances), oneof([:taken, :taken, :refused])]}},
      {1, {:call, __MODULE__, :rename, [tid, oneof(["Alpha", "Beta"])]}},
      {2, {:call, __MODULE__, :switch, [tid, oneof(@instances)]}},
      {1, {:call, __MODULE__, :switch, [tid, @disabled]}},
      {1, {:call, __MODULE__, :recover, [tid]}},
      {1, {:call, __MODULE__, :sweep, []}},
      {1, {:call, __MODULE__, :archive, [tid]}},
      {1, {:call, __MODULE__, :unarchive, [tid]}},
      {1, {:call, __MODULE__, :delete, [tid]}},
      {3, {:call, __MODULE__, :interrupt, [tid]}},
      {2, {:call, __MODULE__, :interrupt_by_agent, [tid]}},
      {2, {:call, __MODULE__, :stop, [tid, oneof([:alone, :with_task, :with_held_up_task])]}},
      {1, {:call, __MODULE__, :resume, [tid]}},
      {1, {:call, __MODULE__, :release, [tid]}},
      {2, {:call, __MODULE__, :turn, [oneof([:off, :on])]}}
    ]

    # A message started and one queued behind it, and the end of the first, while the task
    # is still held up: too rare a run of commands to draw otherwise.
    after_held_up =
      if held_up,
        do: [
          {20,
           {:call, __MODULE__, :send, [held_up, msg, oneof([:queue, :auto]), oneof(@instances)]}},
          {10, {:call, __MODULE__, :interrupt, [held_up]}}
        ],
        else: []

    # The test's own messages; the continuation's real id is not "resume:<msg>".
    sent =
      for {t, %{messages: m}} <- threads,
          id <- Map.keys(m),
          not String.starts_with?(id, "resume:"),
          not String.starts_with?(id, "async-answer:"),
          do: {t, id}

    # A resend repeats the plan the message implemented.
    plan_of = fn t, m -> Map.get(threads[t].messages[m], :plan) end

    on_messages =
      if sent == [],
        do: [],
        else: [
          {3, let({t, m} <- oneof(sent), do: {:call, __MODULE__, :cancel, [t, m]})},
          {2,
           let(
             [{t, m} <- oneof(sent), mode <- oneof([:queue, :auto, :restart])],
             do: {:call, __MODULE__, :resend, [t, m, mode, plan_of.(t, m)]}
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

    live = for {t, %{status: :live}} <- threads, do: t

    plans =
      for {t, %{status: s} = thread} <- threads,
          s != :deleted,
          p <- Map.keys(thread.plans),
          do: {t, p}

    implemented = for {t, m} <- sent, plan_of.(t, m), do: {t, m}

    on_plans =
      if(live == [],
        do: [],
        else: [{4, {:call, __MODULE__, :propose, [oneof(live), "plan-#{next}"]}}]
      ) ++
        if(plans == [],
          do: [],
          else: [
            {12,
             let(
               [{pt, p} <- oneof(plans), mode <- oneof([:queue, :auto]), i <- oneof(@instances)],
               do: {:call, __MODULE__, :implement, [tid, msg, mode, i, pt, p]}
             )},
            {8,
             let(
               [{pt, p} <- oneof(plans), t <- oneof(live ++ [tid])],
               do: {:call, __MODULE__, :implement_twice, [t, msg, pt, p]}
             )},
            {4,
             let(
               {pt, p} <- oneof(plans),
               do: {:call, __MODULE__, :implement_lost, [tid, msg, pt, p]}
             )}
          ]
        ) ++
        if(lost == %{},
          do: [],
          else: [
            {8,
             let(
               [{{t, m}, {pt, p}} <- oneof(Map.to_list(lost)), mode <- oneof([:queue, :auto])],
               do: {:call, __MODULE__, :implement, [t, m, mode, "codex", pt, p]}
             )}
          ]
        ) ++
        if(implemented == [],
          do: [],
          else: [
            {8,
             let(
               [{t, m} <- oneof(implemented), mode <- oneof([:queue, :auto])],
               do: {:call, __MODULE__, :resend, [t, m, mode, plan_of.(t, m)]}
             )}
          ]
        )

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
           )},
          {4, let({t, m} <- oneof(queued), do: {:call, __MODULE__, :start_queued, [t, m]})}
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
          {4, {:call, __MODULE__, :end_stream, [oneof(running)]}},
          {4, {:call, __MODULE__, :end_stream_leaving, [oneof(running)]}},
          {4, {:call, __MODULE__, :stop_undriven, [oneof(running)]}},
          {2, {:call, __MODULE__, :restart, []}},
          {1, {:call, __MODULE__, :restart_stuck, [oneof(running)]}},
          {1, {:call, __MODULE__, :restart_capturing, [oneof(running)]}},
          {14,
           {:call, __MODULE__, :ask, [oneof(running), oneof([:live, :message]), "ask-#{next}"]}}
        ]

    asked = for {t, thread} <- threads, rid <- Map.keys(thread.requests), do: {t, rid}

    on_requests =
      if asked == [],
        do: [],
        else: [
          {12,
           let(
             [{t, r} <- oneof(asked), how <- oneof([:full, :full, :number])],
             do: {:call, __MODULE__, :answer, [t, r, how]}
           )},
          {5, let({t, r} <- oneof(asked), do: {:call, __MODULE__, :dismiss, [t, r]})}
        ]

    # A limit stop is worth choosing to resume, and an armed resume worth reaching.
    limited = for {t, thread} <- threads, limited(thread) != nil, do: t
    armed = for {_, thread} <- threads, thread.recovery != nil, do: thread

    on_limits =
      if(limited == [], do: [], else: [{4, {:call, __MODULE__, :recover, [oneof(limited)]}}]) ++
        if armed == [], do: [], else: [{4, {:call, __MODULE__, :sweep, []}}]

    # A switch away while the MC's own message waits, which then starts on the instance
    # switched to: too rare a run of commands to draw otherwise (#1048).
    switchable =
      for {t, %{status: :live} = thread} <- threads,
          Enum.any?(thread.queue, &thread.messages[&1].notice),
          do: {t, hd(@instances -- [thread.instance])}

    on_notices =
      if switchable == [],
        do: [],
        else: [{6, let({t, i} <- oneof(switchable), do: {:call, __MODULE__, :switch, [t, i]})}]

    # codex-work turned off under a turn queued or running on it, then that message
    # promoted, or a question there answered by message: too rare to draw otherwise.
    work = for {t, th} <- threads, m <- th.queue, instance_of(th, m) == "codex-work", do: {t, m}
    on_work? = Enum.any?(threads, fn {_, th} -> th.instance == "codex-work" end)

    on_off =
      cond do
        not off and (work != [] or on_work?) ->
          [{6, {:call, __MODULE__, :turn, [:off]}}]

        off and work != [] ->
          [
            {6,
             let(
               [{t, m} <- oneof(work), how <- oneof([:taken, :refused])],
               do: {:call, __MODULE__, :promote, [t, m, how]}
             )}
          ]

        true ->
          []
      end

    frequency(
      always ++
        on_off ++
        after_held_up ++
        on_messages ++
        on_queued ++ on_running ++ on_requests ++ on_limits ++ on_notices ++ on_plans
    )
  end

  def precondition(%{threads: threads}, {:call, _, :crash, [tid]}),
    do: threads[tid] != nil and running(threads[tid]) != nil

  def precondition(%{threads: threads}, {:call, _, fun, [tid]})
      when fun in [:end_stream, :end_stream_leaving, :stop_undriven],
      do: threads[tid] != nil and running(threads[tid]) != nil

  def precondition(%{threads: threads}, {:call, _, :release, [tid]}),
    do: threads[tid] != nil

  def precondition(%{threads: threads}, {:call, _, :recover, [tid]}),
    do: match?(%{status: :live}, threads[tid])

  def precondition(%{threads: threads}, {:call, _, :restart, []}),
    do: Enum.any?(threads, fn {_, t} -> running(t) != nil end)

  def precondition(%{threads: threads}, {:call, _, :restart_stuck, [tid]}),
    do: threads[tid] != nil and running(threads[tid]) != nil

  # A queue behind the turn would wait on the user at boot, as after any restart. A
  # question the ended turn waited on was cancelled at its end, not expired at boot.
  def precondition(%{threads: threads}, {:call, _, :restart_capturing, [tid]}),
    do:
      threads[tid] != nil and running(threads[tid]) != nil and threads[tid].queue == [] and
        not Enum.any?(
          Map.values(threads[tid].requests),
          &(&1.kind == :live and &1.status == "pending")
        )

  # The provider asks in the turn it runs.
  def precondition(%{threads: threads}, {:call, _, :ask, [tid, _, _]}),
    do: match?(%{status: :live}, threads[tid]) and running(threads[tid]) != nil

  # An answer by message joins the running turn when it runs on the thread's instance,
  # or starts the thread's next when nothing runs and nothing is held.
  def precondition(%{threads: threads}, {:call, _, :answer, [tid, rid, how]}) do
    case threads[tid] do
      %{status: :live, requests: %{^rid => request}} = thread ->
        how != :full or request.kind == :live or request.status != "pending" or
          (not held_queue?(thread) and
             case running(thread) do
               nil -> thread.queue == []
               run -> run.instance == thread.instance
             end)

      _ ->
        false
    end
  end

  def precondition(%{threads: threads}, {:call, _, :dismiss, [tid, rid]}),
    do: match?(%{status: :live, requests: %{^rid => _}}, threads[tid])

  def precondition(%{threads: threads}, {:call, _, :propose, [tid, _]}),
    do: match?(%{status: :live}, threads[tid])

  # A plan is implemented from a thread of its project; one that was deleted is gone.
  def precondition(%{threads: threads}, {:call, _, :implement, [tid, _, _, _, pt, plan]}),
    do: threads[tid] != nil and planned?(threads, pt, plan)

  def precondition(%{threads: threads}, {:call, _, :implement_lost, [tid, _, pt, plan]}),
    do: threads[tid] != nil and planned?(threads, pt, plan)

  def precondition(%{threads: threads}, {:call, _, :implement_twice, [tid, _, pt, plan]}),
    do: match?(%{status: :live}, threads[tid]) and planned?(threads, pt, plan)

  def precondition(%{threads: threads}, {:call, _, :promote, [tid, msg, :archived]}),
    do:
      match?(%{status: :live}, threads[tid]) and msg in threads[tid].queue and
        steers?(threads[tid], msg) and
        off_refusal(threads[tid], instance_of(threads[tid], msg)) == nil

  def precondition(%{threads: threads}, {:call, _, fun, [tid, msg | _]})
      when fun in [:cancel, :edit, :reorder, :promote, :resend, :interrupt_run, :start_queued],
      do: Map.has_key?((threads[tid] || %{messages: %{}}).messages, msg)

  # An agent switches the thread it runs in; one put away has no agent to switch it.
  def precondition(%{threads: threads}, {:call, _, :switch, [tid, _]}),
    do: match?(%{status: :live}, threads[tid])

  def precondition(_state, _call), do: true

  defp planned?(threads, pt, plan),
    do: match?(%{status: status, plans: %{^plan => _}} when status != :deleted, threads[pt])

  # A restart finds every question the provider waited on expired; whatever else
  # ended a turn cancelled the ones it waited on. One answered by message outlives both.
  def next_state(state, result, {:call, _, fun, _} = call) do
    state
    |> then(&if(fun in @restarts, do: expire_requests(&1), else: &1))
    |> step(result, call)
    |> close_requests()
  end

  defp step(state, _result, {:call, _, :ask, [tid, kind, rid]}) do
    run = running(state.threads[tid])

    %{state | next: state.next + 1}
    |> update(tid, &put_in(&1.requests[rid], %{kind: kind, status: "pending", run: run.msg}))
  end

  # An answer by message goes to the agent as the user's message: into the running
  # turn, or as the thread's next one.
  defp step(state, _result, {:call, _, :answer, [tid, rid, :full]}) do
    case state.threads[tid].requests[rid] do
      %{status: "pending", kind: :message} ->
        if off_refusal(state.threads[tid], state.threads[tid].instance),
          do: state,
          else: answered(state, tid, rid, :message)

      %{status: "pending", kind: kind} ->
        answered(state, tid, rid, kind)

      _ ->
        state
    end
  end

  defp step(state, _result, {:call, _, :answer, _}), do: state

  defp step(state, _result, {:call, _, :dismiss, [tid, rid]}) do
    case state.threads[tid].requests[rid] do
      %{status: "pending"} -> update(state, tid, &put_in(&1.requests[rid].status, "cancelled"))
      _ -> state
    end
  end

  defp step(state, _result, {:call, _, :send, [tid, msg, mode, instance]}) do
    state = %{state | next: state.next + 1}

    case send_refusal(state, tid, mode, instance) do
      nil -> update(state, tid, &sent(&1, msg, mode, instance))
      _ -> state
    end
  end

  # The project's switch is every thread's: each is project-1's.
  defp step(state, _result, {:call, _, :turn, [how]}) do
    off = how == :off
    %{state | off: off, threads: Map.new(state.threads, fn {t, th} -> {t, %{th | off: off}} end)}
  end

  # The second of two identical sends finds the first: they are one send. A steer Codex
  # refuses leaves the thread as it was.
  defp step(state, result, {:call, m, :steer_twice, [tid, msg, instance, how]}) do
    if steer_refused?(state, tid, instance, how),
      do: %{state | next: state.next + 1},
      else: step(state, result, {:call, m, :send, [tid, msg, :auto, instance]})
  end

  # A message the thread already has was sent: sending it again changes nothing, in
  # whatever state the first one is now (running, queued, steered, cancelled, edited).
  defp step(state, _result, {:call, _, :resend, _}), do: state

  defp step(state, _result, {:call, _, :propose, [tid, plan]}),
    do: update(%{state | next: state.next + 1}, tid, &put_in(&1.plans[plan], open_plan()))

  # A message that implements a plan is sent as any other and completes it. One the
  # thread refuses gives back the plan it claimed, also one that claimed it before.
  defp step(state, result, {:call, m, :implement, [tid, msg, mode, instance, pt, plan]}) do
    case implement_refusal(state, tid, msg, pt, plan, instance) do
      nil ->
        state
        |> step(result, {:call, m, :send, [tid, msg, mode, instance]})
        |> update(pt, &put_in(&1.plans[plan], %{status: "completed", by: msg}))
        |> update(
          tid,
          &update_in(&1, [:messages, msg], fn sent -> Map.put(sent, :plan, {pt, plan}) end)
        )
        |> Map.update!(:lost, &Map.delete(&1, {tid, msg}))

      {:error, "Proposed plan" <> _} ->
        %{state | next: state.next + 1}

      _ ->
        %{state | next: state.next + 1}
        |> update(pt, fn thread ->
          if thread.plans[plan].by == msg,
            do: put_in(thread.plans[plan], open_plan()),
            else: thread
        end)
        |> Map.update!(:lost, &Map.delete(&1, {tid, msg}))
    end
  end

  # The send stops once it has claimed the plan: the plan is completed by a message the
  # thread does not have.
  defp step(state, _result, {:call, _, :implement_lost, [tid, msg, pt, plan]}) do
    state = %{state | next: state.next + 1}

    case implement_refusal(state, tid, msg, pt, plan, "codex") do
      {:error, "Proposed plan" <> _} ->
        state

      _ ->
        state
        |> update(pt, &put_in(&1.plans[plan], %{status: "completed", by: msg}))
        |> Map.update!(:lost, &Map.put(&1, {tid, msg}, {pt, plan}))
    end
  end

  # The second message is refused whatever the first's outcome.
  defp step(state, result, {:call, m, :implement_twice, [tid, msg, pt, plan]}),
    do: step(state, result, {:call, m, :implement, [tid, msg, :auto, "codex", pt, plan]})

  defp step(state, _result, {:call, _, :create, [tid]}) do
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
          recovery: nil,
          requests: %{},
          plans: %{},
          off: state.off
        })
  end

  defp step(state, _result, {:call, _, :rename, [tid, title]}) do
    case refusal(state, tid, :rename) do
      nil -> update(state, tid, &%{&1 | title: title})
      _ -> state
    end
  end

  defp step(state, _result, {:call, _, :archive, [tid]}) do
    case refusal(state, tid, :archive) do
      nil -> update(state, tid, &(&1 |> cancel_queue() |> Map.put(:status, :archived)))
      _ -> state
    end
  end

  defp step(state, _result, {:call, _, :unarchive, [tid]}) do
    case refusal(state, tid, :unarchive) do
      nil -> update(state, tid, &%{&1 | status: :live})
      _ -> state
    end
  end

  defp step(state, _result, {:call, _, :delete, [tid]}) do
    case refusal(state, tid, :delete) do
      nil ->
        update(state, tid, fn thread ->
          thread
          |> cancel_queue()
          |> set_runs(&if(&1.status == :running, do: %{&1 | status: :cancelled}, else: &1))
          |> Map.update!(:requests, &cancel_pending/1)
          |> Map.put(:status, :deleted)
        end)

      _ ->
        state
    end
  end

  # An agent's stop ends the turn as the user's does; who asked is the wrapper's
  # to check on the run's interrupt items (`interrupt_by_agent/1`).
  defp step(state, result, {:call, module, :interrupt_by_agent, [tid]}),
    do: step(state, result, {:call, module, :interrupt, [tid]})

  defp step(state, _result, {:call, _, :interrupt, [tid]}) do
    case refusal(state, tid, :interrupt) do
      nil ->
        # The stop of a limit stop is the user giving up the resume scheduled for it.
        update(state, tid, fn thread ->
          thread = if limit_stop(thread), do: %{thread | recovery: nil}, else: thread
          thread |> end_running(:interrupted) |> start_next()
        end)

      _ ->
        state
    end
  end

  # A plugin's stop ends the turn and starts nothing: what was queued is cancelled.
  defp step(state, _result, {:call, _, :stop, [tid, how]}) do
    case state.threads[tid] do
      %{status: status} = thread when status != :deleted ->
        held_up = if how == :with_held_up_task and running(thread), do: tid

        %{state | held_up: held_up}
        |> update(tid, &(&1 |> cancel_queue() |> end_running(:interrupted)))

      _ ->
        %{state | held_up: nil}
    end
  end

  # A stop pinned to a message's run ends only that run's turn: one that ended, or
  # never started, leaves whatever runs now.
  defp step(state, _result, {:call, _, :interrupt_run, [tid, msg]}) do
    cond do
      pinned_running?(state, tid, msg) ->
        update(state, tid, &(&1 |> end_running(:interrupted) |> start_next()))

      # Stopping the limit stop's own run gives up the resume scheduled for it.
      pinned_limited?(state, tid, msg) ->
        update(state, tid, &%{&1 | recovery: nil})

      true ->
        state
    end
  end

  defp step(state, _result, {:call, _, :crash, [tid]}),
    do: update(state, tid, &(&1 |> end_running(:failed) |> start_next()))

  # The provider's stream ending mid-turn fails the run, as its runtime crashing does.
  defp step(state, result, {:call, module, :end_stream, [tid]}),
    do: step(state, result, {:call, module, :crash, [tid]})

  # One ending while the MC shuts down leaves the run; the next boot interrupts it.
  defp step(state, result, {:call, module, :end_stream_leaving, [_tid]}),
    do: step(state, result, {:call, module, :restart, []})

  # A stop settles a run nothing drives as a stop settles any run.
  defp step(state, result, {:call, module, :stop_undriven, [tid]}),
    do: step(state, result, {:call, module, :interrupt, [tid]})

  defp step(state, _result, {:call, _, :restart, []}) do
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

  # A runtime killed by the stop reads the same as one that stopped.
  defp step(state, result, {:call, module, :restart_stuck, [_tid]}),
    do: step(state, result, {:call, module, :restart, []})

  # The turn had ended; the checkpoint captured at boot completes it.
  defp step(state, result, {:call, module, :restart_capturing, [tid]}) do
    state = update(state, tid, &end_running(&1, :completed))
    step(state, result, {:call, module, :restart, []})
  end

  # The session goes and the next message starts it again; no run changes.
  defp step(state, _result, {:call, _, :release, [_tid]}), do: state

  # The thread's next turn runs on the instance; the turn in progress finishes where it is.
  defp step(state, _result, {:call, _, :switch, [tid, instance]}) do
    if switch_refusal(state.threads[tid], instance),
      do: state,
      else: update(state, tid, &%{&1 | instance: instance})
  end

  # Resume at the reset: armed for the limit stop that is the thread's latest run.
  defp step(state, _result, {:call, _, :recover, [tid]}) do
    case limited(state.threads[tid]) do
      %{msg: msg} -> update(state, tid, &%{&1 | recovery: msg})
      nil -> state
    end
  end

  # At the reset, a live thread armed for its current limit stop resumes the queue the
  # stop held, or is sent a continuation (which completes) when it held none.
  defp step(state, _result, {:call, _, :sweep, []}) do
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

  defp step(state, _result, {:call, _, :resume, [tid]}) do
    case refusal(state, tid, :resume) do
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

  # Sent now, the queued message starts ahead of the rest, which stay as they were.
  defp step(state, _result, {:call, _, :start_queued, [tid, msg]}) do
    case start_refusal(state, tid, msg) do
      nil ->
        update(state, tid, fn thread ->
          %{thread | queue: List.delete(thread.queue, msg)}
          |> set_runs(&if(&1.msg == msg, do: %{&1 | held: false}, else: &1))
          |> Map.put(:instance, Enum.find(thread.runs, &(&1.msg == msg)).instance)
          |> put_in([:messages, msg, :shown], true)
          |> started(msg)
        end)

      _ ->
        state
    end
  end

  defp step(state, _result, {:call, _, :cancel, [tid, msg]}) do
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

  defp step(state, _result, {:call, _, :edit, [tid, msg, text]}) do
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

  defp step(state, _result, {:call, _, :reorder, [tid, msg, before]}) do
    case refusal(state, tid, :queue) || reorder_refusal(state, tid, msg, before) do
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
  defp step(state, _result, {:call, _, :promote, [tid, msg, :archived]}) do
    update(state, tid, fn thread ->
      %{thread | queue: List.delete(thread.queue, msg)}
      |> set_runs(&if(&1.msg == msg, do: %{&1 | status: :cancelled}, else: &1))
      |> cancel_queue()
      |> Map.put(:status, :archived)
    end)
  end

  defp step(state, _result, {:call, _, :promote, [tid, msg, how]}) do
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

  # The project turned the instance off: no new message names it, and no turn starts
  # on it, whatever set the turn going (`:provider_off`).
  defp off_refusal(%{off: true}, "codex-work"), do: {:error, :provider_off}
  defp off_refusal(_thread, _instance), do: nil

  # The MC's own delivery of a result is recorded whatever the switch says; its run
  # fails to start instead (`started/2`).
  defp send_refusal(state, tid, mode, instance) do
    refusal(state, tid, :send) ||
      if mode != :notice, do: off_refusal(state.threads[tid], instance)
  end

  # A switch to the instance the thread is on changes nothing; a disabled instance is
  # refused before the project's own switches are asked.
  defp switch_refusal(%{instance: instance}, instance), do: nil

  defp switch_refusal(_thread, @disabled),
    do: {:error, "The target provider instance is unavailable."}

  defp switch_refusal(thread, instance), do: off_refusal(thread, instance)

  defp instance_of(thread, msg), do: Enum.find(thread.runs, &(&1.msg == msg)).instance

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

      # Stopping a thread on a limit stop gives up its resume instead of stopping a turn.
      thread when command == :interrupt ->
        if running(thread) || limit_stop(thread), do: nil, else: {:error, "no running turn"}

      %{status: :archived} when command == :resume ->
        {:error, "Thread #{tid} is not active."}

      _ ->
        nil
    end
  end

  # A queued message is sent now only on a live thread with no turn running.
  defp start_refusal(state, tid, msg) do
    thread = state.threads[tid]

    cond do
      refused = refusal(state, tid, :resume) -> refused
      own = agents_own(state, tid, msg) -> own
      msg not in thread.queue -> {:error, :not_queued}
      running(thread) -> {:error, :another_turn}
      true -> nil
    end
  end

  defp promote_refusal(state, tid, msg) do
    case state.threads[tid] do
      nil ->
        {:error, "unknown thread #{tid}"}

      %{status: :live} = thread ->
        if msg in thread.queue,
          do: agents_own(state, tid, msg) || off_refusal(thread, instance_of(thread, msg)),
          else: {:error, :not_queued}

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

  # The agent's queued result is not the user's to move, nor to move a message ahead of.
  defp reorder_refusal(state, tid, msg, before) do
    thread = state.threads[tid]

    cond do
      agents_own(state, tid, msg) -> {:error, :agents_own}
      before in thread.queue and thread.messages[before].notice -> {:error, :ahead_of_result}
      true -> nil
    end
  end

  defp expected_reply(state, :create, [tid]),
    do: if(state.threads[tid], do: {:error, "Thread #{tid} already exists."}, else: :ok)

  defp expected_reply(state, :send, [tid, _msg, mode, instance]),
    do: send_refusal(state, tid, mode, instance) || :ok

  defp expected_reply(state, :steer_twice, [tid, _msg, instance, how]) do
    cond do
      refused = send_refusal(state, tid, :auto, instance) -> refused
      steer_refused?(state, tid, instance, how) -> {:error, :steer_refused}
      true -> :ok
    end
  end

  defp expected_reply(state, :rename, [tid, _]), do: refusal(state, tid, :rename) || :ok

  defp expected_reply(state, :switch, [tid, instance]),
    do: switch_refusal(state.threads[tid], instance) || :ok

  defp expected_reply(state, fun, [tid])
       when fun in [:archive, :unarchive, :delete, :interrupt],
       do: refusal(state, tid, fun) || :ok

  defp expected_reply(state, :interrupt_by_agent, [tid]),
    do: refusal(state, tid, :interrupt) || :ok

  defp expected_reply(state, :stop, [tid, _]),
    do: if(state.threads[tid], do: :ok, else: {:error, "unknown thread #{tid}"})

  defp expected_reply(state, :edit, [tid, msg, _]),
    do: refusal(state, tid, :queue) || agents_own(state, tid, msg) || :ok

  defp expected_reply(state, :resume, [tid]), do: refusal(state, tid, :resume) || :ok

  defp expected_reply(state, :cancel, [tid | _]), do: refusal(state, tid, :queue) || :ok

  defp expected_reply(state, :start_queued, [tid, msg]), do: start_refusal(state, tid, msg) || :ok

  defp expected_reply(state, :reorder, [tid, msg, before]),
    do: refusal(state, tid, :queue) || reorder_refusal(state, tid, msg, before) || :ok

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

  defp expected_reply(state, :implement, [tid, msg, _, instance, pt, plan]),
    do: implement_refusal(state, tid, msg, pt, plan, instance) || :ok

  defp expected_reply(state, :implement_twice, [tid, msg, pt, plan]),
    do: implement_refusal(state, tid, msg, pt, plan, "codex") || :ok

  defp expected_reply(state, :implement_lost, [tid, msg, pt, plan]) do
    case implement_refusal(state, tid, msg, pt, plan, "codex") do
      {:error, "Proposed plan" <> _} = refused -> refused
      _ -> :lost
    end
  end

  # A stop for the latest run, which completed as the stop arrived, counts as
  # done: the provider had nothing active to stop (commands.feature).
  defp expected_reply(state, :interrupt_run, [tid, msg]) do
    if pinned_running?(state, tid, msg) or pinned_completed?(state, tid, msg) or
         pinned_limited?(state, tid, msg),
       do: :ok,
       else: {:error, "no running turn"}
  end

  defp expected_reply(state, :release, [tid]),
    do: if(running(state.threads[tid]), do: {:error, :busy}, else: :ok)

  # Answers are refused before they reach a provider when the request cannot be
  # resumed or the answers are not text; a closed question refuses the rest, except an
  # answer by message sent again.
  defp expected_reply(state, :answer, [tid, rid, how]) do
    request = state.threads[tid].requests[rid]

    cond do
      request.status == "expired" ->
        {:error, "The server restarted before this runtime request was resolved."}

      how == :number ->
        {:error, "Each answer must be text or a list of chosen options."}

      request.status == "pending" and request.kind == :message ->
        off_refusal(state.threads[tid], state.threads[tid].instance) || :ok

      request.status == "pending" ->
        :ok

      request.kind == :message and request.status == "resolved" ->
        :ok

      request.kind == :message ->
        {:error, "This question has already been answered."}

      true ->
        {:error, :closed}
    end
  end

  defp expected_reply(state, :dismiss, [tid, rid]) do
    if state.threads[tid].requests[rid].status == "pending",
      do: :ok,
      else: {:error, "This question has already been answered."}
  end

  defp expected_reply(_state, _fun, _args), do: :ok

  defp reply_matches?({:error, :not_queued}, {:error, message}),
    do: message =~ ~r/^Queued run \S+ is not queued\.$/

  defp reply_matches?({:error, :another_turn}, {:error, message}),
    do: message =~ "Another turn started first, so the message stays queued."

  defp reply_matches?({:error, :agents_own}, {:error, message}),
    do: message =~ ~r/^Automatic completion deliveries cannot be/

  defp reply_matches?({:error, :ahead_of_result}, {:error, message}),
    do: message == "Queued messages cannot be reordered ahead of automatic completion delivery."

  defp reply_matches?({:error, :archived_meanwhile}, {:error, message}),
    do: message =~ ~r/not queued again: the thread was archived\.$/

  defp reply_matches?({:error, :steer_refused}, {:error, message}),
    do: message =~ "did not take the message into its running turn (turn moved on)"

  # The provider's runtime refuses a question it no longer waits on.
  defp reply_matches?({:error, :closed}, {:error, message}),
    do: is_binary(message) and message =~ "no pending request"

  defp reply_matches?({:error, :provider_off}, {:error, message}),
    do:
      message ==
        "Codex is turned off for this project. Turn it on in the project's provider settings or pick another provider."

  defp reply_matches?(expected, reply), do: expected == reply

  # An answer by message goes to the agent as the user's message: into the running
  # turn, or as the thread's next one.
  defp answered(state, tid, rid, kind) do
    update(state, tid, fn thread ->
      thread = put_in(thread.requests[rid].status, "resolved")

      if kind == :message do
        id = answer_id(rid)
        mode = if running(thread), do: :auto, else: :queue

        thread
        |> sent(id, mode, thread.instance)
        |> put_in([:messages, id, :text], answer_text(rid))
      else
        thread
      end
    end)
  end

  defp update(state, tid, fun), do: update_in(state.threads[tid], fun)

  defp open_plan, do: %{status: "active", by: nil}

  # The plan is checked before the message is sent; a message refused gives it back.
  defp implement_refusal(state, tid, msg, pt, plan, instance) do
    claimed = state.threads[pt].plans[plan]

    if claimed.status == "active" or claimed.by == msg,
      do: send_refusal(state, tid, :queue, instance),
      else: {:error, "Proposed plan #{plan} is not active."}
  end

  defp expire_requests(state) do
    threads =
      Map.new(state.threads, fn {tid, thread} ->
        requests =
          Map.new(thread.requests, fn
            {rid, %{kind: :live, status: "pending"} = r} -> {rid, %{r | status: "expired"}}
            other -> other
          end)

        {tid, %{thread | requests: requests}}
      end)

    %{state | threads: threads}
  end

  # A deleted thread's questions are all closed, those answered by message too.
  defp cancel_pending(requests),
    do:
      Map.new(requests, fn
        {rid, %{status: "pending"} = r} -> {rid, %{r | status: "cancelled"}}
        other -> other
      end)

  # A question the provider waited on is cancelled when the turn it was asked in ends.
  defp close_requests(state) do
    threads =
      Map.new(state.threads, fn {tid, thread} ->
        ran = Map.new(thread.runs, &{&1.msg, &1.status})

        requests =
          Map.new(thread.requests, fn
            {rid, %{kind: :live, status: "pending", run: msg} = r} ->
              if ran[msg] == :running, do: {rid, r}, else: {rid, %{r | status: "cancelled"}}

            other ->
              other
          end)

        {tid, %{thread | requests: requests}}
      end)

    %{state | threads: threads}
  end

  # The message an answer by message is sent as, and its text: the question, then the
  # answer. The question says "wait", so a turn the answer starts runs on.
  defp answer_id(rid), do: "async-answer:runtime-request:codex:async:" <> rid
  defp answer_text(rid), do: "wait #{rid}\nRed"

  defp set_runs(thread, fun), do: %{thread | runs: Enum.map(thread.runs, fun)}

  defp running(thread), do: Enum.find(thread.runs, &(&1.status == :running))

  defp pinned_running?(state, tid, msg),
    do:
      refusal(state, tid, :interrupt) == nil and
        match?(%{msg: ^msg}, running(state.threads[tid]))

  # The thread's latest run is this message's limit stop.
  defp pinned_limited?(state, tid, msg) do
    thread = state.threads[tid]
    thread != nil and thread.status != :deleted and match?(%{msg: ^msg}, limit_stop(thread))
  end

  defp pinned_completed?(state, tid, msg) do
    thread = state.threads[tid]
    last = thread && List.last(thread.runs)

    thread != nil and thread.status != :deleted and last != nil and
      last.status == :completed and last.msg == msg
  end

  # This steer reaches a running turn on its instance, and Codex refuses it there.
  defp steer_refused?(state, tid, instance, how) do
    thread = state.threads[tid]

    how == :refused and send_refusal(state, tid, :auto, instance) == nil and
      match?(%{instance: ^instance}, thread && running(thread))
  end

  # A promote of this queued message asks the running turn's provider to take it.
  defp steers?(thread, msg) do
    run = running(thread)

    run != nil and not thread.messages[msg].notice and
      Enum.find(thread.runs, &(&1.msg == msg)).instance == run.instance
  end

  # The running turn is interrupted for `msg`, which it names (`steeredByRunId`).
  defp steered_by(thread, msg),
    do: set_runs(thread, &if(&1.status == :running, do: Map.put(&1, :by, msg), else: &1))

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
      # The MC's own message runs on the thread's instance as it starts, which a switch
      # since it was queued may have changed; anything else takes the thread over.
      thread =
        if thread.messages[next].notice,
          do:
            set_runs(thread, &if(&1.msg == next, do: %{&1 | instance: thread.instance}, else: &1)),
          else: thread

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
  # A run on an instance the project turned off fails as it starts, and the queue goes on.
  defp started(thread, msg) do
    thread = in_start_order(thread, msg)

    cond do
      off_refusal(thread, instance_of(thread, msg)) ->
        thread
        |> set_runs(
          &if(&1.msg == msg, do: Map.merge(&1, %{status: :failed, off: true}), else: &1)
        )
        |> start_next()

      limit_text?(thread.messages[msg].text) ->
        thread
        |> set_runs(fn run ->
          cond do
            run.msg == msg -> %{run | status: :failed}
            run.msg in thread.queue -> %{run | held: true}
            true -> run
          end
        end)

      true ->
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

  # The thread's latest run when it is a limit stop it can resume from, else nil. A
  # question still waiting on the user, one answered by message too, keeps the thread
  # from resuming at the reset.
  defp limited(nil), do: nil

  defp limited(thread) do
    if not Enum.any?(Map.values(thread.requests), &(&1.status == "pending")),
      do: limit_stop(thread)
  end

  # The thread's latest run when it is a limit stop, whatever waits on the user: what a
  # stop gives up the resume of.
  defp limit_stop(nil), do: nil

  defp limit_stop(thread) do
    case latest(thread) do
      %{status: :failed, msg: msg} = run when not is_map_key(run, :off) ->
        if limit_text?(thread.messages[msg].text), do: run

      _ ->
        nil
    end
  end

  # The recovery at the reset: the held queue resumes, or a continuation runs to its end.
  # The run the resumed queue starts continues the stop (`continues`), as the
  # continuation's message does. A continuation the thread's instance cannot take,
  # turned off meanwhile, is refused.
  defp recovered(thread, msg) do
    cond do
      Enum.any?(thread.runs, &(&1.msg in thread.queue and &1.held)) ->
        [next | _] = thread.queue

        thread
        |> set_runs(&if(&1.msg in thread.queue, do: %{&1 | held: false}, else: &1))
        |> set_runs(&if(&1.msg == next, do: Map.put(&1, :continues, msg), else: &1))
        |> start_next()

      off_refusal(thread, thread.instance) ->
        thread

      true ->
        continued(thread, msg)
    end
  end

  defp continued(thread, msg) do
    resume = "resume:#{msg}"
    run = %{msg: resume, status: :completed, held: false, instance: thread.instance}
    message = %{text: "Continue where you left off.", run: resume, shown: true, notice: false}

    %{thread | runs: thread.runs ++ [run]}
    |> in_start_order(resume)
    |> put_in([:messages, resume], message)
  end

  defp sent(thread, msg, mode, instance) do
    active = running(thread)
    text = if mode == :limit, do: "usage limit #{msg}", else: "wait #{msg}"
    message = %{text: text, run: msg, shown: false, notice: mode == :notice}
    # The MC's own message names no instance: it is on the thread's.
    instance = if mode == :notice, do: thread.instance, else: instance
    # A message the user queues while the queue is held is held with it; a restart, or
    # the agent's own result (`:notice`), is not.
    held = mode in [:queue, :limit] and held_queue?(thread)
    run = %{msg: msg, status: :queued, held: held, instance: instance}

    cond do
      active == nil and held ->
        %{thread | runs: thread.runs ++ [run], queue: enqueue(thread, msg, mode)}
        |> put_in([:messages, msg], message)

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
        %{thread | runs: thread.runs ++ [run], queue: enqueue(thread, msg, mode)}
        |> put_in([:messages, msg], message)
        |> steered_by(msg)
        |> end_running(:interrupted)
        |> start_next()

      true ->
        %{thread | runs: thread.runs ++ [run], queue: enqueue(thread, msg, mode)}
        |> put_in([:messages, msg], message)
    end
  end

  defp held_queue?(thread),
    do: Enum.any?(thread.runs, &(&1.held and &1.msg in thread.queue))

  # Where a newly queued message goes: the agent's results first, in the order they came,
  # then the user's messages. A restart, or the agent's result, goes ahead of the user's.
  defp enqueue(thread, msg, mode) do
    {results, users} = Enum.split_with(thread.queue, &thread.messages[&1].notice)
    if mode in [:restart, :notice], do: results ++ [msg] ++ users, else: thread.queue ++ [msg]
  end

  # A message put first in the queue goes behind the agent's queued results.
  defp first(thread, msg) do
    {results, users} =
      Enum.split_with(List.delete(thread.queue, msg), &thread.messages[&1].notice)

    results ++ [msg | users]
  end

  # A queued message steers the running turn, or goes first in the queue when no turn
  # runs. One for another instance, or one the provider refuses to take, interrupts the
  # running turn and goes first.
  defp promoted(thread, msg, how) do
    instance = Enum.find(thread.runs, &(&1.msg == msg)).instance

    case running(thread) do
      nil ->
        %{thread | queue: first(thread, msg)}

      %{instance: other} when other != instance or how == :refused ->
        %{thread | queue: first(thread, msg)}
        |> steered_by(msg)
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
          do:
            {run.msg, Atom.to_string(run.status), run.held, run.instance, Map.get(run, :by),
             Map.get(run, :continues)}
        ),
      queue: thread.queue,
      foreign: [],
      messages:
        Map.new(thread.messages, fn {id, m} ->
          shown = if m.shown, do: {m.run, if(m.notice, do: "notification", else: "user_message")}
          {id, {m.text, m.run, shown}}
        end),
      steered: for({id, m} <- thread.messages, m.run != id, do: m.text) |> Enum.sort(),
      requests: Map.new(thread.requests, fn {rid, r} -> {rid, r.status} end),
      plans: thread.plans
    }
  end

  # --- commands ---------------------------------------------------------------------

  # Every thread is a plugin's, so that it can be stopped; a client creating one that
  # exists gets the same answer whoever started it.
  def create(tid) do
    fields = %{
      "threadId" => tid,
      "projectId" => "project-1",
      "title" => "Thread #{tid}",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default"
    }

    if StreamState.get(current(tid), "thread")[tid] do
      reply(Orchestration.dispatch(Map.put(fields, "type", "thread.create")), [])
    else
      fields
      |> Map.put("workspaceStrategy", %{
        "type" => "existing_worktree",
        "worktreePath" => Process.get(:work)
      })
      |> Orchestration.launch_thread(plugin: %{"id" => @plugin})
      |> reply([])
    end
  end

  def send(tid, msg, mode, instance),
    do: deliver(tid, message(tid, msg, mode, instance), mode, instance)

  # A message implementing a proposed plan, as the composer sends one.
  def implement(tid, msg, mode, instance, pt, plan),
    do: deliver(tid, planned(message(tid, msg, mode, instance), {pt, plan}), mode, instance)

  # A second message for the plan, sent while Codex holds the first one's steer
  # (`hold-steer`), when the first has claimed the plan but is not in the thread yet;
  # one sent after the first was decided when there is no turn to steer.
  def implement_twice(tid, msg, pt, plan) do
    steers = active_runs(tid, "codex")
    second = planned(message(tid, msg <> "-again", :queue, "codex"), {pt, plan})
    File.touch!(Process.get(:hold_steer))

    task =
      Task.async(fn ->
        Orchestration.dispatch(planned(message(tid, msg, :auto, "codex"), {pt, plan}))
      end)

    {first, again} =
      case asked(tid, msg, task) do
        {:done, first} ->
          File.rm!(Process.get(:hold_steer))
          {first, Orchestration.dispatch(second)}

        _ ->
          again = Orchestration.dispatch(second)
          File.rm!(Process.get(:hold_steer))
          {Task.await(task, @wait_ms), again}
      end

    result =
      if again == {:error, "Proposed plan #{plan} is not active."},
        do: first,
        else: {:unexpected, {first, again}}

    reply(result, if(match?({:ok, _}, result), do: steers, else: []))
  end

  # A message implementing the plan whose send stops once it has claimed the plan, as
  # at a crash: a streams hook ends the dispatching process at its next call into a
  # stream. The send can also be refused before it claims anything.
  def implement_lost(tid, msg, pt, plan) do
    command = planned(message(tid, msg, :queue, "codex"), {pt, plan})
    Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :lose_after_claim, [pt, plan]})

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:lose_after_claim, msg)
        exit({:sent, Orchestration.dispatch(command)})
      end)

    result =
      receive do
        {:DOWN, ^ref, :process, ^pid, :lost_after_claim} -> :lost
        {:DOWN, ^ref, :process, ^pid, {:sent, sent}} -> sent
        {:DOWN, ^ref, :process, ^pid, other} -> {:unexpected, other}
      after
        @wait_ms -> {:unexpected, :timeout}
      end

    Application.delete_env(:hal_c2, :streams_hook)
    reply(result, [])
  end

  def lose_after_claim(pt, plan, :ensured, _stream_id) do
    msg = Process.get(:lose_after_claim)
    claimed = pt |> HalC2.Streams.ensure() |> HalC2.Streams.Server.state()

    if msg &&
         match?(%{"implementedByMessageId" => ^msg}, StreamState.fetch(claimed, "plan", plan)),
       do: exit(:lost_after_claim),
       else: :ok
  end

  def lose_after_claim(_pt, _plan, _stage, _stream_id), do: :ok

  def propose(tid, plan) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entity = %{
      "id" => plan,
      "threadId" => tid,
      "runId" => nil,
      "nodeId" => nil,
      "kind" => "proposed_plan",
      "status" => "active",
      "markdown" => "# #{plan}",
      "createdAt" => now,
      "updatedAt" => now
    }

    :ok =
      HalC2.Streams.transact(tid, :thread, fn state ->
        {[Orchestration.upsert(state, "plan", plan, fn _ -> entity end)], :ok}
      end)

    reply({:ok, %{}}, [])
  end

  defp planned(command, nil), do: command

  defp planned(command, {pt, plan}),
    do: Map.put(command, "sourcePlanRef", %{"threadId" => pt, "planId" => plan})

  defp deliver(tid, command, mode, instance) do
    ending = active_runs(tid)
    steers = active_runs(tid, instance)
    result = Orchestration.dispatch(command)
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
  # scheduler. `how` has Codex refuse it (`:refused`) once it lets it go. A repeat of a
  # steer Codex holds hears it is still being sent, whatever Codex goes on to answer;
  # any other repeat is answered as the first was.
  def steer_twice(tid, msg, instance, how) do
    steers = active_runs(tid, instance)
    command = message(tid, msg, :auto, instance)
    if how == :refused, do: File.touch!(Process.get(:reject_steer))
    File.touch!(Process.get(:hold_steer))
    first = Task.async(fn -> Orchestration.dispatch(command) end)

    {one, repeat, held?} =
      case asked(tid, msg, first) do
        :asked ->
          repeat = Orchestration.dispatch(command)
          File.rm!(Process.get(:hold_steer))
          {Task.await(first, @wait_ms), repeat, steers != []}

        {:done, one} ->
          File.rm!(Process.get(:hold_steer))
          {one, Orchestration.dispatch(command), false}

        :timeout ->
          File.rm!(Process.get(:hold_steer))
          {Task.await(first, @wait_ms), Orchestration.dispatch(command), false}
      end

    if how == :refused, do: File.rm!(Process.get(:reject_steer))

    result =
      cond do
        held? and
            match?({:error, %{"message" => "This message is still being sent" <> _}}, repeat) ->
          one

        not held? and outcome(one) == outcome(repeat) ->
          one

        true ->
          {:unexpected, {one, repeat}}
      end

    reply(result, if(match?({:ok, _}, result), do: steers, else: []))
  end

  # The same message again, as first sent; a message the thread has ends no run.
  def resend(tid, msg, mode, plan),
    do: reply(Orchestration.dispatch(planned(message(tid, msg, mode, "codex"), plan)), [])

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
            },
            "delegatedCompletion" => %{
              "parentRunId" => nil,
              "taskIds" => ["task-#{msg}"],
              "acceptedAt" => nil
            }
          }

        :auto ->
          %{"dispatchMode" => %{"type" => "start_immediately"}, "deliveryIntent" => "auto"}

        :restart ->
          %{"dispatchMode" => %{"type" => "start_immediately"}, "deliveryIntent" => "restart"}
      end

    %{
      "type" => "message.dispatch",
      "threadId" => tid,
      "messageId" => msg,
      "text" => if(mode == :limit, do: "usage limit #{msg}", else: "wait #{msg}"),
      "attachments" => [],
      "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"}
    }
    # `Delegation` names no model: the result goes to the thread's.
    |> then(&if(mode == :notice, do: Map.delete(&1, "modelSelection"), else: &1))
    |> Map.merge(extra)
  end

  # The provider asks the user a question in its running turn: one it waits on
  # (`item/tool/requestUserInput`), or one answered by message (an async agent
  # message carrying questions).
  def ask(tid, kind, rid) do
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, tid)
    runtime = :sys.get_state(pid)

    case kind do
      :live ->
        send(
          pid,
          {:json_rpc, runtime.conn,
           {:request, System.unique_integer([:positive]), "item/tool/requestUserInput",
            %{
              "itemId" => rid,
              "questions" => [
                %{
                  "id" => "q1",
                  "header" => "Question",
                  "question" => "wait #{rid}",
                  "options" => [%{"label" => "Red"}]
                }
              ]
            }}}
        )

      :message ->
        send(
          pid,
          {:json_rpc, runtime.conn,
           {:notification, "item/completed",
            %{
              "threadId" => runtime.native_thread_id,
              "turnId" => runtime.turn.native_turn_id,
              "item" => %{
                "type" => "agentMessage",
                "id" => rid,
                "delivery" => "async",
                "text" => "",
                "questions" => [%{"title" => "wait #{rid}", "options" => ["Red"]}]
              }
            }}}
        )
    end

    await_stream(tid, &(request_of(&1, rid)["status"] == "pending"))
    reply({:ok, %{}}, [])
  end

  # Answers in text (`:full`), or a number where text belongs (`:number`).
  def answer(tid, rid, how) do
    request = request_of(current(tid), rid)
    question = if request["responseCapability"]["type"] == "message", do: "0", else: "q1"
    ending = active_runs(tid)

    result =
      Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => tid,
        "requestId" => request["id"],
        "answers" => %{question => if(how == :number, do: 5432, else: "Red")}
      })

    # Only an answer by message steers the running turn, and so ends it.
    steers? =
      match?({:ok, _}, result) and how == :full and question == "0" and
        request["status"] == "pending"

    reply(result, if(steers?, do: ending, else: []))
  end

  def dismiss(tid, rid) do
    request = request_of(current(tid), rid)

    reply(
      Orchestration.dispatch(%{
        "type" => "thread.user-input.dismiss",
        "threadId" => tid,
        "requestId" => request["id"]
      }),
      []
    )
  end

  defp request_of(state, rid) do
    requests = StreamState.get(state, "runtime-request")
    requests["runtime-request:codex:" <> rid] || requests["runtime-request:codex:async:" <> rid]
  end

  # As `hal_c2_thread_configure` switches the agent's own thread.
  def switch(tid, instance),
    do:
      thread_command(%{
        "type" => "provider.switch",
        "threadId" => tid,
        "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"}
      })

  # The project's own switch for codex-work, as its provider settings write it.
  def turn(how) do
    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        put_in(
          settings,
          [
            Access.key("projectSettingsOverrides", %{}),
            Access.key("project-1", %{}),
            Access.key("providerInstances", %{}),
            Access.key("codex-work", %{}),
            "enabled"
          ],
          how == :on
        )
      end)

    reply({:ok, %{}}, [])
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

  # An agent's stop, as `hal_c2_thread_interrupt` sends it: the run it ended records
  # the agent as who asked, with its reason, and its outcome says so (upstream
  # #24299). A request an earlier stop already recorded is that stop's, not this one's.
  def interrupt_by_agent(tid) do
    ending = active_runs(tid)

    asked =
      MapSet.new(
        StreamState.list(current(tid), "turn-item"),
        & &1["id"]
      )

    result =
      Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => tid,
        "requestedBy" => "agent",
        "reason" => "wrong branch"
      })

    reply = reply(result, ending)
    if match?({:ok, _}, result), do: check_agent_stop(tid, ending, asked)
    reply
  end

  defp check_agent_stop(tid, ending, asked) do
    state = current(tid)
    items = StreamState.list(state, "turn-item")
    by_id = Map.new(runs(state), &{&1["id"], &1})

    for run_id <- ending, by_id[run_id]["status"] == "interrupted" do
      request_id = "turn-item:run:#{run_id}:signal:interrupt-request"
      request = Enum.find(items, &(&1["id"] == request_id))

      if request != nil and not MapSet.member?(asked, request_id) do
        unless request["stoppedBy"] == "agent" and request["message"] == "wrong branch",
          do: raise("an agent's stop of #{tid} was recorded as #{inspect(request)}")

        outcome =
          Enum.find(items, &(&1["id"] == "turn-item:run:#{run_id}:signal:interrupt-result"))

        unless outcome != nil and outcome["message"] == "Stopped by an agent: wrong branch",
          do: raise("an agent's stop of #{tid} read as #{inspect(outcome && outcome["message"])}")
      end
    end
  end

  # What was queued when the stop began never starts, on the thread or on a task delegated
  # from it (`:with_task`, when the thread has a turn to delegate from): a run that did
  # carries an attempt, or ended as something other than cancelled, whatever a later command
  # makes of it. A task's thread is no thread of the model's, so nothing else looks at it.
  def stop(tid, how) do
    # A task held up by an earlier stop goes now.
    File.rm(Process.get(:hold_interrupt))

    child =
      case how do
        :alone -> nil
        :with_task -> delegate_with_queue(tid)
        :with_held_up_task -> delegate_held_up(tid)
      end

    held_up = how == :with_held_up_task and child != nil
    ending = active_runs(tid)
    queued = for run <- runs(current(tid)), run["status"] == "queued", do: run["id"]

    child_queued =
      child && for run <- runs(current(child)), run["status"] == "queued", do: run["id"]

    result =
      case Orchestration.stop_plugin_thread(tid, @plugin, if(held_up, do: 100, else: 15_000)) do
        :ok -> {:ok, %{}}
        # The stop goes on, for the task only: what follows sees the thread as it left it.
        :busy when held_up -> await_passed(tid, child, child_queued)
        :busy -> {:error, :busy}
        error -> error
      end

    refute_started(tid, queued)
    if child, do: refute_started(child, child_queued)

    reply(result, ending)
  end

  # A task whose Codex, alone of them, answers no interrupt while the file exists.
  defp delegate_held_up(tid) do
    hold = Process.get(:hold_interrupt)
    command = Application.get_env(:hal_c2, :codex_command)

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_HOLD_INTERRUPT=#{hold}" | command
    ])

    child = delegate_with_queue(tid)

    if child do
      File.write!(hold, "")
      :ok = HalC2.Streams.watch(child, self())
      await_stream(child, fn state -> Enum.any?(runs(state), &(&1["status"] == "running")) end)
    end

    Application.put_env(:hal_c2, :codex_command, command)
    child
  end

  defp await_passed(tid, child, child_queued) do
    await_stream(child, fn state ->
      Enum.all?(runs(state), &(&1["id"] not in child_queued or &1["status"] == "cancelled"))
    end)

    await_stream(tid, fn state ->
      not Enum.any?(runs(state), &(&1["status"] in @active)) and
        Enum.all?(StreamState.list(state, "provider-session"), &(&1["status"] == "stopped"))
    end)

    {:ok, %{}}
  end

  defp await_stream(tid, done?) do
    unless done?.(current(tid)) do
      receive do
        {:hal_c2_stream, ^tid, _} -> await_stream(tid, done?)
      after
        @wait_ms -> raise("#{tid} never got there: #{inspect(runs(current(tid)))}")
      end
    end
  end

  # A task that stays at work, with a message queued behind its turn.
  defp delegate_with_queue(tid) do
    with %{"providerInstanceId" => instance} <-
           Enum.find(runs(current(tid)), &(&1["status"] in ~w(running waiting))),
         {:ok, %{"childThreadId" => child}} <-
           HalC2.Orchestration.Delegation.delegate(%{"id" => tid}, instance, %{"task" => "wait"}) do
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => child,
          "messageId" => "behind-#{child}",
          "text" => "wait behind",
          "attachments" => [],
          "dispatchMode" => %{"type" => "queue_after_active"}
        })

      child
    else
      _ -> nil
    end
  end

  defp refute_started(tid, queued) do
    for run <- runs(current(tid)),
        run["id"] in queued,
        run["status"] != "cancelled" or run["startedAt"] != nil,
        do: raise("a run queued at the stop of #{tid} started: #{inspect(run)}")
  end

  def interrupt_run(tid, msg) do
    run_id = run_of(tid, msg)
    ending = Enum.filter(active_runs(tid), &(&1 == run_id))

    reply(
      Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => tid, "runId" => run_id}),
      ending
    )
  end

  def start_queued(tid, msg),
    do:
      thread_command(%{
        "type" => "queued-run.start",
        "threadId" => tid,
        "runId" => run_of(tid, msg)
      })

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

  # Only the provider's stream ends (the app-server exits), the runtime living on.
  def end_stream(tid) do
    ending = active_runs(tid)
    kill_stream(tid)
    reply({:ok, %{}}, ending)
  end

  # The same while the MC is shutting down: the run is left as it is for the next boot
  # (checked before the boot), which settles it as interrupted.
  def end_stream_leaving(tid) do
    [run_id] = active_runs(tid)
    HalC2.Orchestration.Recovery.leaving(true)
    kill_stream(tid)
    still_active? = run_id in active_runs(tid)
    result = restart()

    if still_active?,
      do: result,
      else: reply({:error, "the run was ended while the MC was stopping"}, [])
  end

  # A run whose runtime was killed as the MC stopped, which nothing drives any more
  # (the MC kept running), is stopped by the user: it settles as interrupted and keeps
  # a checkpoint of what it changed.
  def stop_undriven(tid) do
    [run_id] = active_runs(tid)
    ending = [run_id]
    HalC2.Orchestration.Recovery.leaving(true)
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, tid)
    gone = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^gone, :process, _, _} -> :ok
    end

    _ = :sys.get_state(HalC2.Orchestration.TurnWatch)
    HalC2.Orchestration.Recovery.leaving(false)

    result = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => tid})
    {outcome, projection} = reply(result, ending)
    run = current(tid) |> StreamState.get("run") |> Map.fetch!(run_id)
    checkpoint = StreamState.get(current(tid), "checkpoint")[run["checkpointId"]]

    if run["status"] == "interrupted" and checkpoint == nil,
      do: {{:error, "the stopped run kept no checkpoint"}, projection},
      else: {outcome, projection}
  end

  defp kill_stream(tid) do
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, tid)
    conn = :sys.get_state(pid).conn
    gone = Process.monitor(conn)
    Process.exit(conn, :kill)

    receive do
      {:DOWN, ^gone, :process, _, _} -> :ok
    end

    _ = :sys.get_state(pid)
    :ok
  end

  # The MC stops with turns running and boots again: provider runtimes go without
  # ending their turns, the streams come back from the store, and boot recovery
  # settles what was running.
  def restart do
    HalC2.Prop.restart_service(HalC2.Codex.Supervisor)
    # The bundled Codex plugin's sessions live under the plugin host.
    HalC2.Prop.restart_service(HalC2.Plugins)
    _ = :sys.get_state(HalC2.Plugins)
    HalC2.Prop.restart_service(HalC2.Orchestration.TurnWatch)
    HalC2.Prop.restart_service(HalC2.Streams)
    # The streams wrote their sidebar rows as they stopped.
    _ = :sys.get_state(HalC2.Shell)
    subscribe()
    HalC2.Orchestration.Recovery.run()
    HalC2.Orchestration.Recovery.continue()
    reply({:ok, %{}}, [])
  end

  # The MC stops with one runtime stuck past its shutdown limit, which kills it.
  def restart_stuck(tid) do
    HalC2.Orchestration.Recovery.leaving(true)

    case Registry.lookup(HalC2.Codex.Registry, tid) do
      [{pid, _}] ->
        gone = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^gone, :process, _, _} -> :ok
        end

      [] ->
        :ok
    end

    _ = :sys.get_state(HalC2.Orchestration.TurnWatch)
    restart()
  end

  # The MC stops after `tid`'s provider turn ended, while its checkpoint was still to
  # be captured: the effect's record is left running. Boot recovery leaves the run to
  # the effect sweep, which captures the checkpoint and completes it.
  def restart_capturing(tid) do
    [run_id] = active_runs(tid)
    run = current(tid) |> StreamState.get("run") |> Map.fetch!(run_id)
    at = HalC2.Orchestration.Entities.now()
    id = "effect:checkpoint-#{System.unique_integer([:positive])}"

    HalC2.Store.put_meta(
      "effect:#{tid}:#{id}",
      JSON.encode!(%{
        "id" => id,
        "threadId" => tid,
        "type" => "checkpoint.capture",
        "lane" => "checkpoint",
        "status" => "running",
        "attempts" => 1,
        "delays" => [],
        "error" => nil,
        "args" => %{
          "cwd" => Process.get(:work),
          "scopeId" => tid,
          "runOrdinal" => run["ordinal"],
          "runId" => run_id,
          "rootNodeId" => run["rootNodeId"],
          "at" => at
        },
        "createdAt" => at,
        "updatedAt" => at
      })
    )

    {:ok, _} = restart()
    # Effects start after recovery, as at boot, and sweep the record.
    HalC2.Prop.restart_service(HalC2.Orchestration.Effects)
    :ok = HalC2.Orchestration.Effects.drain(tid)
    reply({:ok, %{}}, [run_id])
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
  defp outcome(:lost), do: :lost
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
                 run["providerInstanceId"], by_id[run["steeredByRunId"]]["userMessageId"],
                 by_id[run["usageLimitContinuationOfRunId"]]["userMessageId"]}
            ),
          queue: queue,
          foreign: foreign(state, runs),
          messages: messages,
          steered: provider_steers(Enum.map(user_messages, fn {_, m} -> m["text"] end)),
          requests:
            for(
              {id, request} <- StreamState.get(state, "runtime-request"),
              [_, rid] <- [Regex.run(~r/^runtime-request:codex:(?:async:)?(ask-\d+)$/, id)],
              into: %{},
              do: {rid, request["status"]}
            ),
          plans:
            for(
              {"plan-" <> _ = id, %{"kind" => "proposed_plan"} = plan} <-
                StreamState.get(state, "plan"),
              into: %{},
              do: {id, %{status: plan["status"], by: plan["implementedByMessageId"]}}
            )
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
