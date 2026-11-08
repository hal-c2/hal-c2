defmodule HalC2.ClaudeApprovalsPropTest do
  @moduledoc """
  A state machine over one Claude thread (`HalC2.Claude.ThreadRuntime`) on the fake
  CLI in `test/support/fake_claude.py`, covering two promises the feature scenarios
  make one case at a time:

  - The pending-approval lifecycle. Claude asks ("approve"), and then, in any
    order: the user answers (`ThreadRuntime.respond/3` with accept, decline or
    cancel), Claude withdraws the request (its `control_cancel_request`, which the
    session forwards as `{:permission_cancelled, id}`), withdrawal or an answer
    arrives a second time or names a request that never existed, and the user
    stops the run. The promise: the first thing that closes a request wins — a
    withdrawn approval closes as cancelled, one the user already answered stays
    answered, and nothing after that changes its status or decision. An answer
    for a request that is not pending is an error.
  - The resume head a turn records (its provider turn's `nativeTurnRef`, where a
    rollback to that turn resumes). A `/compact` turn has no assistant message,
    so its compact boundary is its head; a turn Claude compacts in before
    answering ("grow the conversation") records the later assistant message,
    which moves the head past the boundary; a plain turn records its answer.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Claude.ThreadRuntime

  @moduletag timeout: :infinity

  @tid "claude-approvals-thread"
  @request "runtime-request:claudeAgent:perm-1"
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 15_000

  property "the first close of an approval wins, and a compact boundary is a resume head",
    numtests: HalC2.Prop.numtests(30),
    max_size: 16 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :claude_command)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("claude-approvals")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :claude_command, ["python3", "-u", @fake_claude])

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      {Registry, keys: :unique, name: HalC2.Claude.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
        id: :codex_registry
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

    # So "grow the conversation" compacts before it answers.
    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        providers =
          Map.update(
            settings["providers"] || %{},
            "claudeAgent",
            %{"autoCompactWindow" => "200000"},
            &Map.put(&1, "autoCompactWindow", "200000")
          )

        Map.put(settings, "providers", providers)
      end)

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Claude",
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-opus-4-6"},
        "runtimeMode" => "approval-required",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok
  end

  # --- model ----------------------------------------------------------------------

  # phase: :idle (no turn), :pending (an approval is open), :withdrawn (Claude
  #   withdrew it; the turn still runs). status/decision: what the request the
  #   fake keeps opening as perm-1 shows now, or nil before the first ask.
  #   msgs: user messages sent, which the fake numbers its uuid- and compact-
  #   ids by. head: the resume head the last finished turn recorded.
  def initial_state,
    do: %{phase: :idle, status: nil, decision: nil, msgs: 0, n: 1, head: nil}

  def command(%{phase: :idle, n: n}) do
    frequency([
      {3, {:call, __MODULE__, :ask, [n]}},
      {2, {:call, __MODULE__, :plain, [n]}},
      {2, {:call, __MODULE__, :compact_only, [n]}},
      {2, {:call, __MODULE__, :grow, [n]}},
      {1, {:call, __MODULE__, :withdraw, [oneof(["perm-1", "perm-nope"])]}},
      {1, {:call, __MODULE__, :answer, [oneof(["accept", "decline"])]}}
    ])
  end

  def command(%{phase: :pending}) do
    frequency([
      {3, {:call, __MODULE__, :answer, [oneof(["accept", "decline"])]}},
      {1, {:call, __MODULE__, :answer, ["cancel"]}},
      {3, {:call, __MODULE__, :withdraw, ["perm-1"]}},
      {1, {:call, __MODULE__, :withdraw, ["perm-nope"]}},
      {1, {:call, __MODULE__, :stop, []}}
    ])
  end

  def command(%{phase: :withdrawn}) do
    frequency([
      {2, {:call, __MODULE__, :answer, [oneof(["accept", "decline", "cancel"])]}},
      {1, {:call, __MODULE__, :withdraw, [oneof(["perm-1", "perm-nope"])]}},
      {3, {:call, __MODULE__, :stop, []}}
    ])
  end

  def precondition(_state, _call), do: true

  # A new ask reopens perm-1 as pending, whatever an earlier turn closed it as.
  # The reopened entity keeps the last decision it was closed with until this
  # ask is itself closed, so the model keeps it too (and the postcondition does
  # not read a pending request's decision).
  def next_state(state, _result, {:call, _, :ask, [_n]}),
    do: %{sent(state) | phase: :pending, status: "pending"}

  def next_state(state, _result, {:call, _, :plain, [_n]}),
    do: %{sent(state) | head: "uuid-#{state.msgs + 1}"}

  # No assistant message follows the boundary, so the boundary is the head.
  def next_state(state, _result, {:call, _, :compact_only, [_n]}),
    do: %{sent(state) | head: "compact-#{state.msgs + 1}"}

  # Claude answers after compacting: the answer moves the head past the boundary.
  def next_state(state, _result, {:call, _, :grow, [_n]}),
    do: %{sent(state) | head: "uuid-#{state.msgs + 1}"}

  # An accepted or declined approval lets the turn finish; cancelling one stops
  # it. Either way the thread is idle and the answer stands.
  def next_state(%{phase: :pending} = state, _result, {:call, _, :answer, ["cancel"]}),
    do: %{state | phase: :idle, status: "cancelled", decision: "cancel"}

  def next_state(%{phase: :pending} = state, _result, {:call, _, :answer, [decision]}),
    do: %{state | phase: :idle, status: "resolved", decision: decision}

  # No pending request to answer: an error, and the last close stands.
  def next_state(state, _result, {:call, _, :answer, [_decision]}), do: state

  # Withdrawing the open request closes it as cancelled; the turn runs on.
  def next_state(%{phase: :pending} = state, _result, {:call, _, :withdraw, ["perm-1"]}),
    do: %{state | phase: :withdrawn, status: "cancelled", decision: "cancel"}

  # A withdrawal with nothing open by that name changes nothing: an answered
  # request stays answered, a withdrawn one stays cancelled.
  def next_state(state, _result, {:call, _, :withdraw, [_id]}), do: state

  # Stopping the run closes a still-pending request as cancelled with it, and
  # leaves an already-withdrawn one as Claude's withdrawal closed it.
  def next_state(%{phase: :pending} = state, _result, {:call, _, :stop, []}),
    do: %{state | phase: :idle, status: "cancelled"}

  def next_state(state, _result, {:call, _, :stop, []}), do: %{state | phase: :idle}

  defp sent(state), do: %{state | msgs: state.msgs + 1, n: state.n + 1}

  def postcondition(state, {:call, _, fun, args}, seen) do
    next = next_state(state, seen, {:call, nil, fun, args})

    seen.status == next.status and
      (next.status == "pending" or seen.decision == next.decision) and
      seen.head == next.head and respond_ok?(state, fun, args, seen)
  end

  # Answering is :ok only while the request is pending.
  defp respond_ok?(%{phase: :pending}, :answer, _args, seen), do: seen.respond == :ok
  defp respond_ok?(_state, :answer, _args, seen), do: seen.respond == :error
  defp respond_ok?(_state, _fun, _args, _seen), do: true

  # --- commands -------------------------------------------------------------------

  # A turn that asks for a command's approval and waits on it.
  def ask(n) do
    send_message(n, "approve run: touch x")
    await(fn -> match?(%{status: "pending"}, snapshot()) && snapshot() end)
  end

  # A turn Claude answers (uuid-N) without asking anything.
  def plain(n), do: turn(n, "where are we")

  # A turn Claude only compacts in (compact-N, no assistant uuid).
  def compact_only(n), do: turn(n, "/compact")

  # A turn Claude compacts in (compact-N) before answering (uuid-N).
  def grow(n), do: turn(n, "grow the conversation")

  defp turn(n, text) do
    run = send_message(n, text)
    await_run(run, &(&1["status"] in ["completed", "failed", "interrupted"]))
    snapshot()
  end

  # The user's answer. An accepted/declined turn finishes on the fake's reply;
  # a cancelled one is interrupted; with nothing pending nothing more happens.
  def answer(decision) do
    runs = StreamState.list(current(), "run")

    respond =
      case ThreadRuntime.respond(@tid, @request, %{"decision" => decision}) do
        :ok -> :ok
        {:error, _} -> :error
      end

    if respond == :ok do
      run =
        Enum.find(runs, &(&1["status"] not in ["completed", "failed", "interrupted"])) ||
          List.last(runs)

      await_run(run["id"], &(&1["status"] in ["completed", "failed", "interrupted"]))
    end

    Map.put(snapshot(), :respond, respond)
  end

  # Claude withdraws a request: what its `control_cancel_request` reaches the
  # runtime as. The runtime has handled it once it answers a state read.
  def withdraw(control_id) do
    case runtime_pid() do
      nil ->
        snapshot()

      pid ->
        send(pid, {:claude, :sys.get_state(pid).session, {:permission_cancelled, control_id}})
        _ = :sys.get_state(pid)
        snapshot()
    end
  end

  # The user stops the running turn.
  def stop do
    run = current() |> StreamState.list("run") |> List.last()

    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})
    await_run(run["id"], &(&1["status"] in ["completed", "failed", "interrupted"]))
    snapshot()
  end

  # --- the runtime ------------------------------------------------------------------

  # What is read back: perm-1's status and decision, and the resume head the
  # newest provider turn recorded (its newest nativeTurnRef).
  defp snapshot do
    state = current()

    request =
      Enum.find(StreamState.list(state, "runtime-request"), &(&1["id"] == @request))

    # `list/2` is in creation order, so the last head recorded wins.
    head =
      state
      |> StreamState.list("provider-turn")
      |> Enum.filter(&get_in(&1, ["nativeTurnRef", "nativeId"]))
      |> List.last()

    %{
      status: request && request["status"],
      decision: request && request["decision"],
      head: head && get_in(head, ["nativeTurnRef", "nativeId"])
    }
  end

  defp send_message(n, text) do
    runs = MapSet.new(StreamState.list(current(), "run"), & &1["id"])

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => text,
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await(fn ->
      Enum.find_value(StreamState.list(current(), "run"), fn run ->
        if not MapSet.member?(runs, run["id"]), do: run["id"]
      end)
    end)
  end

  defp runtime_pid do
    case Registry.lookup(HalC2.Claude.Registry, @tid) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Until run `id` satisfies `done?`; the runtime has handled what led there by then.
  defp await_run(id, done?) do
    await(fn ->
      run = Enum.find(StreamState.list(current(), "run"), &(&1["id"] == id))

      if run && done?.(run),
        do: tap(run, fn _ -> if pid = runtime_pid(), do: :sys.get_state(pid) end)
    end)
  end

  # Until `fun` gives a value, rechecked on each change to the thread's stream.
  defp await(fun, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    if value = fun.() do
      value
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await(fun, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> raise "never got there"
      end
    end
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
end
