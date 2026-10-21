defmodule HalC2.MuseRuntimePropTest do
  @moduledoc """
  A state machine over one supervised Muse Code thread (`HalC2.Muse.ThreadRuntime`)
  driven through the orchestration commands a client sends: send a message whose turn
  replies, runs until stopped, starts a subagent (reported in progress, in a state of
  Muse's own the runtime does not know, or finishing before the turn does) and runs
  until stopped, asks to run a
  command (once, or for two requirements in turn) or asks a question; steer the running
  turn; approve or decline the command;
  answer the question; interrupt the
  turn; crash the runtime mid-turn; have `muse serve` exit under it, idle or mid-turn;
  release the idle thread's session as IdleSessions does.

  Turns run on the fake `muse serve` in `test/support/fake_muse_msp.py`, which keeps
  its sessions on disk. A turn that replies names every message Muse's session has
  seen, so the model checks the thread continues one Muse session across crashes and
  releases. After each command the test waits on the thread's stream until the turn
  reached the point the fake stops at (a reply, a pending request, or the end of the
  runs the command ended) and compares the runs, the pending request, the replies and
  the thread's subagents with the model: a subagent a turn started ends with that turn,
  whatever ended it (the interim #447 records changing for completed turns, whose
  subagents upstream keeps as background work; the model changes with it).
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "muse-thread"
  @fake_muse Path.expand("../../test/support/fake_muse_msp.py", __DIR__)
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000

  @turns [
    %{"match" => "wait", "steps" => [%{"text" => "Working on it."}, %{"waitInterrupt" => true}]},
    %{
      "match" => "delegate",
      "steps" => [
        # Muse names items within a turn: every turn's subagent has the same id.
        %{
          "subagent" => %{
            "objective" => "Look around",
            "progress" => "Looking",
            "itemId" => "item-look"
          }
        },
        %{"text" => "Working on it."},
        %{"waitInterrupt" => true}
      ]
    },
    %{
      "match" => "finish",
      "steps" => [
        %{
          "subagent" => %{
            "objective" => "Look around",
            "progress" => "Looking",
            "answer" => "All clear.",
            "itemId" => "item-look"
          }
        },
        %{"text" => "Working on it."},
        %{"waitInterrupt" => true}
      ]
    },
    %{
      "match" => "hold",
      "steps" => [
        %{
          "subagent" => %{
            "objective" => "Look around",
            "progress" => "Waiting for a slot",
            "progressStatus" => "queued",
            "itemId" => "item-look"
          }
        },
        %{"text" => "Working on it."},
        %{"waitInterrupt" => true}
      ]
    },
    %{"match" => "shell", "steps" => [%{"shell" => "npm test"}, %{"text" => "Ran it."}]},
    %{
      "match" => "guarded",
      "steps" => [%{"shell" => "npm test", "requirements" => 2}, %{"text" => "Ran it."}]
    },
    %{
      "match" => "workflow",
      "steps" => [
        %{"childShell" => "make", "approvable" => true, "requirements" => 2},
        %{"text" => "Ran it."}
      ]
    },
    %{
      "match" => "ask",
      "steps" => [%{"question" => %{"question" => "Pick", "options" => ~w(red green)}}]
    }
  ]

  property "a Muse Code thread keeps its runs, requests and session as the model expects",
    numtests: HalC2.Prop.numtests(30),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("muse-runtime")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        Process.put(:work, work)
        Process.put(:mode, "approval-required")
        bin = install_fake(home)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          # A request's answer is offered to every built-in runtime.
          {Registry, keys: :unique, name: HalC2.Muse.Registry},
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
            id: :codex_registry
          ),
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

        HalC2.Acp.forget("muse")

        {:ok, _} =
          HalC2.Settings.put(
            %{"providers" => %{"muse" => %{"enabled" => true, "binaryPath" => bin}}},
            0
          )

        create()
        :ok = HalC2.Streams.subscribe(@tid, self(), nil)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Acp.forget("muse")

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: [{msg, status}] in the order they were made;
  # subs: [{msg, status}] the subagent each :delegate, :hold or :finish turn started,
  # with its status (a :finish turn's already completed while the turn runs on);
  # turn: the running turn's %{msg, kind}, kind :wait | :delegate | :hold | :finish | :shell | :ask, :guarded for a
  # command with two requirements (:shell once the first is approved), or :workflow for a
  # workflow child's :guarded command;
  # mode: the thread's runtime mode; full access runs every command without asking;
  # history: what Muse's session has been sent, oldest first;
  # replies: the replies naming that history, in order.
  def initial_state,
    do: %{
      runs: [],
      subs: [],
      turn: nil,
      history: [],
      replies: [],
      next: 1,
      mode: "approval-required"
    }

  def command(%{turn: turn, next: next}) do
    msg = "m#{next}"

    idle = [
      {6,
       {:call, __MODULE__, :send,
        [msg, oneof([:say, :wait, :delegate, :hold, :finish, :shell, :guarded, :workflow, :ask])]}},
      {1, {:call, __MODULE__, :set_mode, [oneof(~w(approval-required full-access))]}},
      {1, {:call, __MODULE__, :release, []}},
      {1, {:call, __MODULE__, :host_exit, []}}
    ]

    busy =
      [
        {2, {:call, __MODULE__, :interrupt, []}},
        {1, {:call, __MODULE__, :crash, []}},
        {1, {:call, __MODULE__, :host_exit, []}}
      ] ++
        case turn && turn.kind do
          nil ->
            []

          kind when kind in [:wait, :delegate, :hold, :finish] ->
            [{3, {:call, __MODULE__, :steer, [msg]}}]

          kind when kind in [:shell, :guarded, :workflow] ->
            [
              {3, {:call, __MODULE__, :approve, [kind == :shell]}},
              {3, {:call, __MODULE__, :decline, []}}
            ]

          :ask ->
            [
              {3, {:call, __MODULE__, :answer, [oneof(~w(red green purple))]}},
              {1, {:call, __MODULE__, :dismiss, []}}
            ]
        end

    frequency(if(turn == nil, do: idle, else: busy))
  end

  def precondition(%{turn: turn}, {:call, _, fun, _}) when fun in [:send, :release, :set_mode],
    do: turn == nil

  def precondition(%{turn: turn}, {:call, _, :steer, _}),
    do: match?(%{kind: k} when k in [:wait, :delegate, :hold, :finish], turn)

  def precondition(%{turn: turn}, {:call, _, :approve, [last?]}),
    do:
      match?(%{kind: :shell}, turn) == last? and
        match?(%{kind: k} when k in [:shell, :guarded, :workflow], turn)

  def precondition(%{turn: turn}, {:call, _, :decline, _}),
    do: match?(%{kind: k} when k in [:shell, :guarded, :workflow], turn)

  def precondition(%{turn: turn}, {:call, _, fun, _}) when fun in [:answer, :dismiss],
    do: match?(%{kind: :ask}, turn)

  def precondition(_state, {:call, _, :host_exit, _}), do: true
  def precondition(%{turn: turn}, {:call, _, _, _}), do: turn != nil

  def next_state(state, _result, {:call, _, :send, [msg, kind]}) do
    text = "#{kind} #{msg}"
    state = %{state | next: state.next + 1, history: state.history ++ [text]}

    case kind do
      kind when kind in [:shell, :guarded, :workflow] and state.mode == "full-access" ->
        %{state | runs: state.runs ++ [{msg, "completed"}]}

      :say ->
        reply = "Reply to #{text} after [#{Enum.join(state.history -- [text], " | ")}]"
        %{state | runs: state.runs ++ [{msg, "completed"}], replies: state.replies ++ [reply]}

      kind when kind in [:delegate, :hold] ->
        %{
          state
          | runs: state.runs ++ [{msg, "running"}],
            subs: state.subs ++ [{msg, "running"}],
            turn: %{msg: msg, kind: kind}
        }

      # Its subagent answered before the turn settled where the fake waits, so it is
      # already completed while the turn runs on.
      :finish ->
        %{
          state
          | runs: state.runs ++ [{msg, "running"}],
            subs: state.subs ++ [{msg, "completed"}],
            turn: %{msg: msg, kind: kind}
        }

      _ ->
        %{state | runs: state.runs ++ [{msg, "running"}], turn: %{msg: msg, kind: kind}}
    end
  end

  def next_state(state, _result, {:call, _, :steer, _}),
    do: end_turn(%{state | next: state.next + 1}, "completed")

  # Approving the first of two requirements leaves the request open for the second.
  def next_state(state, _result, {:call, _, :approve, [false]}),
    do: %{state | turn: %{state.turn | kind: :shell}}

  def next_state(state, _result, {:call, _, fun, _})
      when fun in [:approve, :decline, :answer, :dismiss],
      do: end_turn(state, "completed")

  def next_state(state, _result, {:call, _, :interrupt, _}), do: end_turn(state, "interrupted")
  def next_state(state, _result, {:call, _, :crash, _}), do: end_turn(state, "failed")
  def next_state(state, _result, {:call, _, :release, _}), do: state
  def next_state(state, _result, {:call, _, :set_mode, [mode]}), do: %{state | mode: mode}

  def next_state(%{turn: nil} = state, _result, {:call, _, :host_exit, _}), do: state
  def next_state(state, _result, {:call, _, :host_exit, _}), do: end_turn(state, "failed")

  # Interim (#447): a subagent the turn ends before it answers is interrupted, even
  # by a turn that completed; one that already answered keeps its completed status
  # whatever ends the turn (a steer after it, an interrupt, a crash, the host going).
  defp end_turn(%{turn: %{msg: msg}} = state, status) do
    ended = fn status -> fn {m, s} -> if m == msg, do: {m, status}, else: {m, s} end end
    sub_status = if status == "completed", do: "interrupted", else: status

    sub_ended = fn
      {m, "running"} when m == msg -> {m, sub_status}
      entry -> entry
    end

    %{
      state
      | runs: Enum.map(state.runs, ended.(status)),
        subs: Enum.map(state.subs, sub_ended),
        turn: nil
    }
  end

  def postcondition(state, call, {reply, projection}) do
    model = next_state(state, nil, call)

    expected = %{
      runs: model.runs,
      request:
        case model.turn do
          %{kind: kind} when kind in [:shell, :guarded, :workflow] -> "command"
          %{kind: :ask} -> "user_input"
          _ -> nil
        end,
      replies: model.replies,
      subs: model.subs
    }

    reply == :ok and projection == expected
  end

  # --- commands ---------------------------------------------------------------------

  defp create do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Muse",
        "modelSelection" => %{"instanceId" => "muse", "model" => "fake/one"},
        "runtimeMode" => "approval-required",
        "interactionMode" => "default",
        "worktreePath" => Process.get(:work)
      })
  end

  def send(msg, kind) do
    result = Orchestration.dispatch(message(msg, "#{kind} #{msg}", "queue_after_active"))
    # A reply ends its run, as does a command in full access; the others stop where the
    # fake waits.
    ends? =
      kind == :say or
        (kind in [:shell, :guarded, :workflow] and Process.get(:mode) == "full-access")

    reply(result, if(ends?, do: [run_of(msg)], else: []))
  end

  def set_mode(mode) do
    Process.put(:mode, mode)

    Orchestration.dispatch(%{
      "type" => "thread.runtime-mode.set",
      "commandId" => "cmd-#{System.unique_integer([:positive])}",
      "threadId" => @tid,
      "runtimeMode" => mode
    })
    |> reply([])
  end

  def steer(msg) do
    ending = active_runs()
    reply(Orchestration.dispatch(message(msg, "steer #{msg}", "start_immediately")), ending)
  end

  defp message(msg, text, mode) do
    %{
      "type" => "message.dispatch",
      "threadId" => @tid,
      "messageId" => msg,
      "text" => text,
      "attachments" => [],
      "modelSelection" => %{"instanceId" => "muse", "model" => "fake/one"},
      "dispatchMode" => %{"type" => mode},
      "deliveryIntent" => "auto"
    }
  end

  # `last?`: the approval answers the command's last requirement, so its run ends.
  def approve(last?), do: respond(%{"decision" => "accept"}, last?)
  def decline, do: respond(%{"decision" => "decline"})
  def answer(choice), do: respond(%{"answers" => %{"q1" => choice}})

  # Muse is told the question was dismissed, and the turn goes on.
  def dismiss do
    ending = active_runs()

    request =
      current()
      |> StreamState.list("runtime-request")
      |> Enum.find(&(&1["status"] == "pending"))

    Orchestration.dispatch(%{
      "type" => "thread.user-input.dismiss",
      "threadId" => @tid,
      "requestId" => request && request["id"]
    })
    |> reply(ending)
  end

  defp respond(response, ends? \\ true) do
    ending = if ends?, do: active_runs(), else: []

    request =
      current()
      |> StreamState.list("runtime-request")
      |> Enum.find(&(&1["status"] == "pending"))

    result =
      Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "runtime-request.respond",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => @tid,
            "requestId" => request && request["id"]
          },
          response
        )
      )

    reply(result, ending)
  end

  def interrupt do
    ending = active_runs()
    reply(Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid}), ending)
  end

  # The runtime driving the turn dies, as a crash in the adapter would; its host goes
  # with it.
  def crash do
    ending = active_runs()

    case Registry.lookup(HalC2.Muse.Registry, @tid) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end

    reply({:ok, %{}}, ending)
  end

  # `muse serve` dies on its own (killed by its OS pid, from the fake's log); the
  # runtime has seen it once the connection is down and the runtime answered after.
  def host_exit do
    ending = active_runs()

    with [{runtime, _}] <- Registry.lookup(HalC2.Muse.Registry, @tid),
         %{conn: conn} when is_pid(conn) <- runtime_state(runtime) do
      ref = Process.monitor(conn)
      {_, 0} = System.cmd("kill", ["-9", "#{host_pid()}"])

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        @wait_ms -> :ok
      end

      _ = runtime_state(runtime)
    end

    reply({:ok, %{}}, ending)
  end

  # A runtime killed by `crash` stays registered until Registry sees it go.
  defp runtime_state(runtime) do
    :sys.get_state(runtime)
  catch
    :exit, _ -> nil
  end

  defp host_pid do
    log = Path.join(Process.get(:fake_dir), "log.jsonl")

    for line <- String.split(File.read!(log), "\n", trim: true),
        %{"start" => %{"argv" => argv, "pid" => pid}} <- [JSON.decode!(line)],
        "--disable-write" not in argv,
        reduce: nil,
        do: (_ -> pid)
  end

  def release do
    case Orchestration.release_session(@tid) do
      :ok -> reply({:ok, %{}}, [])
      :busy -> reply({:error, :busy}, [])
    end
  end

  # --- the real side ----------------------------------------------------------------

  defp install_fake(home) do
    dir = Path.join(home, "fake-muse")
    File.mkdir_p!(dir)
    Process.put(:fake_dir, dir)
    File.write!(Path.join(dir, "config.json"), JSON.encode!(%{"turns" => @turns}))
    bin = Path.join([dir, "bin", "muse"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}'
    exec python3 -u '#{@fake_muse}' "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp active_runs, do: for(run <- runs(current()), run["status"] in @active, do: run["id"])

  defp run_of(msg) do
    case Enum.find(runs(current()), &(&1["userMessageId"] == msg)) do
      %{"id" => id} -> id
      nil -> "run-of-#{msg}"
    end
  end

  defp reply(result, ending) do
    reply =
      case result do
        {:ok, %{}} -> :ok
        {:error, message} -> {:error, message}
        other -> {:unexpected, other}
      end

    {reply, settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # Waits until nothing is starting, the runs in `ending` ended, and a running turn
  # stopped where the fake waits: on a pending request, or after "Working on it.".
  defp settled(ending, deadline) do
    flush()
    state = current()
    runs = runs(state)
    by_id = Map.new(runs, &{&1["id"], &1})

    waiting? = fn run ->
      Enum.any?(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending")) or
        Enum.any?(
          StreamState.list(state, "message"),
          &(&1["runId"] == run["id"] and &1["text"] == "Working on it.")
        )
    end

    quiet? =
      not Enum.any?(runs, &(&1["status"] in ~w(preparing starting))) and
        Enum.all?(ending, &(by_id[&1] == nil or by_id[&1]["status"] not in @active)) and
        Enum.all?(runs, &(&1["status"] not in @active or waiting?.(&1)))

    if quiet? do
      projection(state)
    else
      receive do
        {:hal_c2_stream, @tid, _} -> settled(ending, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, projection(state)}
      end
    end
  end

  defp flush do
    receive do
      {:hal_c2_stream, @tid, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp projection(state) do
    %{
      runs: for(run <- runs(state), do: {run["userMessageId"], run["status"]}),
      request:
        case Enum.filter(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending")) do
          [] -> nil
          [request] -> request["kind"]
          many -> {:many, Enum.map(many, & &1["kind"])}
        end,
      replies:
        for(
          m <- state |> StreamState.list("message") |> Enum.sort_by(& &1["createdAt"]),
          m["role"] == "assistant" and String.starts_with?(m["text"] || "", "Reply to"),
          do: m["text"]
        ),
      subs:
        for(
          run <- runs(state),
          sub <- StreamState.list(state, "subagent"),
          sub["runId"] == run["id"],
          do: {run["userMessageId"], sub["status"]}
        )
    }
  end
end
