defmodule HalC2.ClaudeApprovalsPropTest do
  @moduledoc """
  A state machine over one Claude thread (`HalC2.Claude.ThreadRuntime`) on the fake
  CLI in `test/support/fake_claude.py`, covering two promises the feature scenarios
  make one case at a time:

  - The pending-approval lifecycle, for a command's approval and for an MCP
    tool's elicitation. Claude asks ("approve", "mcp confirm"), and then, in any
    order: the user answers (`ThreadRuntime.respond/3` with accept, decline or
    cancel), Claude withdraws the request (its `control_cancel_request`, which the
    session forwards as `{:permission_cancelled, id}`), withdrawal or an answer
    arrives a second time or names a request that never existed, and the user
    stops the run. The promise: the first thing that closes a request wins — a
    withdrawn approval closes as cancelled, one the user already answered stays
    answered, and nothing after that changes its status or decision. An answer
    for a request that is not pending is an error, and an elicitation answered
    with a decision its card does not offer ("acceptForSession") is declined.
  - The resume head a turn records (its provider turn's `nativeTurnRef`, where a
    rollback to that turn resumes). A `/compact` turn has no assistant message,
    so its compact boundary is its head (a thread's first `/compact` has no
    conversation to compact, so it fails and records nothing); a turn Claude compacts in before
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
  # Each kind's request, and the control id Claude asks it under.
  @requests %{
    permission: {"runtime-request:claudeAgent:perm-1", "perm-1"},
    elicitation: {"runtime-request:claudeAgent:mcp-elicitation:elicit-1", "elicit-1"}
  }
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
  #   withdrew it; the turn still runs). kind: the latest ask's kind. reqs: per
  #   kind, the status and decision of the request the fake keeps opening under
  #   that kind's id (perm-1, elicit-1), or nil before its first ask.
  #   msgs: user messages that reached the fake, which numbers its uuid- and
  #   compact- ids by. head: the resume head the last finished turn recorded.
  #   talked: a turn has reached Claude, so the thread has a conversation.
  def initial_state do
    unasked = %{status: nil, decision: nil}

    %{
      phase: :idle,
      kind: :permission,
      reqs: %{permission: unasked, elicitation: unasked},
      msgs: 0,
      n: 1,
      head: nil,
      talked: false
    }
  end

  @control_ids ["perm-1", "elicit-1", "perm-nope"]

  def command(%{phase: :idle, n: n, kind: kind}) do
    frequency([
      {3, {:call, __MODULE__, :ask, [n, oneof([:permission, :elicitation])]}},
      {2, {:call, __MODULE__, :plain, [n]}},
      {2, {:call, __MODULE__, :compact_only, [n]}},
      {2, {:call, __MODULE__, :grow, [n]}},
      {1, {:call, __MODULE__, :withdraw, [oneof(@control_ids)]}},
      {1, {:call, __MODULE__, :answer, [kind, oneof(["accept", "decline"])]}}
    ])
  end

  def command(%{phase: :pending, kind: kind}) do
    # A command's "always allow" writes session rules the next ask would skip on.
    offered =
      if kind == :elicitation,
        do: ["accept", "decline", "acceptForSession"],
        else: ["accept", "decline"]

    frequency([
      {3, {:call, __MODULE__, :answer, [kind, oneof(offered)]}},
      {1, {:call, __MODULE__, :answer, [kind, "cancel"]}},
      {3, {:call, __MODULE__, :withdraw, [control_id(kind)]}},
      {1, {:call, __MODULE__, :withdraw, [oneof(@control_ids)]}},
      {1, {:call, __MODULE__, :stop, []}}
    ])
  end

  def command(%{phase: :withdrawn, kind: kind}) do
    frequency([
      {2, {:call, __MODULE__, :answer, [kind, oneof(["accept", "decline", "cancel"])]}},
      {1, {:call, __MODULE__, :withdraw, [oneof(@control_ids)]}},
      {3, {:call, __MODULE__, :stop, []}}
    ])
  end

  # Shrinking keeps an answer naming the kind of request that was asked.
  def precondition(%{phase: :pending, kind: kind}, {:call, _, :answer, [answered, _]}),
    do: answered == kind

  def precondition(_state, _call), do: true

  # A new ask reopens its kind's request as pending, whatever an earlier turn
  # closed it as.
  # The reopened entity keeps the last decision it was closed with until this
  # ask is itself closed, so the model keeps it too (and the postcondition does
  # not read a pending request's decision).
  def next_state(state, _result, {:call, _, :ask, [_n, kind]}),
    do: %{close(sent(state), kind, "pending", :kept) | phase: :pending, kind: kind}

  def next_state(state, _result, {:call, _, :plain, [_n]}),
    do: %{sent(state) | head: "uuid-#{state.msgs + 1}"}

  # No assistant message follows the boundary, so the boundary is the head. With
  # no conversation yet the MC refuses it before Claude sees it: the run fails.
  def next_state(%{talked: false} = state, _result, {:call, _, :compact_only, [_n]}),
    do: %{state | n: state.n + 1}

  def next_state(state, _result, {:call, _, :compact_only, [_n]}),
    do: %{sent(state) | head: "compact-#{state.msgs + 1}"}

  # Claude answers after compacting: the answer moves the head past the boundary.
  def next_state(state, _result, {:call, _, :grow, [_n]}),
    do: %{sent(state) | head: "uuid-#{state.msgs + 1}"}

  # An accepted or declined approval lets the turn finish; cancelling one stops
  # it. Either way the thread is idle and the answer stands.
  def next_state(%{phase: :pending} = state, _result, {:call, _, :answer, [kind, "cancel"]}),
    do: %{close(state, kind, "cancelled", "cancel") | phase: :idle}

  # An elicitation's card offers no "always allow": answering with it declines.
  def next_state(
        %{phase: :pending} = state,
        _result,
        {:call, _, :answer, [:elicitation, "acceptForSession"]}
      ),
      do: %{close(state, :elicitation, "resolved", "decline") | phase: :idle}

  def next_state(%{phase: :pending} = state, _result, {:call, _, :answer, [kind, decision]}),
    do: %{close(state, kind, "resolved", decision) | phase: :idle}

  # No pending request to answer: an error, and the last close stands.
  def next_state(state, _result, {:call, _, :answer, [_kind, _decision]}), do: state

  # Withdrawing the open request closes it as cancelled; the turn runs on.
  def next_state(%{phase: :pending, kind: kind} = state, _result, {:call, _, :withdraw, [id]})
      when id == "perm-1" or id == "elicit-1" do
    if id == control_id(kind),
      do: %{close(state, kind, "cancelled", "cancel") | phase: :withdrawn},
      else: state
  end

  # A withdrawal with nothing open by that name changes nothing: an answered
  # request stays answered, a withdrawn one stays cancelled.
  def next_state(state, _result, {:call, _, :withdraw, [_id]}), do: state

  # Stopping the run closes a still-pending request as cancelled with it, and
  # leaves an already-withdrawn one as Claude's withdrawal closed it.
  def next_state(%{phase: :pending, kind: kind} = state, _result, {:call, _, :stop, []}),
    do: %{close(state, kind, "cancelled", :kept) | phase: :idle}

  def next_state(state, _result, {:call, _, :stop, []}), do: %{state | phase: :idle}

  defp sent(state), do: %{state | msgs: state.msgs + 1, n: state.n + 1, talked: true}

  # Sets `kind`'s request status, and its decision unless `:kept`.
  defp close(state, kind, status, decision) do
    update_in(state.reqs[kind], fn req ->
      %{req | status: status, decision: if(decision == :kept, do: req.decision, else: decision)}
    end)
  end

  defp control_id(kind), do: elem(@requests[kind], 1)

  def postcondition(state, {:call, _, fun, args}, seen) do
    next = next_state(state, seen, {:call, nil, fun, args})

    Enum.all?(next.reqs, fn {kind, req} ->
      seen.reqs[kind].status == req.status and
        (req.status == "pending" or seen.reqs[kind].decision == req.decision)
    end) and
      seen.head == next.head and respond_ok?(state, fun, args, seen) and
      ended_ok?(state, fun, seen)
  end

  # A turn that asks nothing completes, but a first `/compact` is refused.
  defp ended_ok?(%{talked: false}, :compact_only, seen), do: seen.ended == "failed"

  defp ended_ok?(_state, fun, seen) when fun in [:plain, :compact_only, :grow],
    do: seen.ended == "completed"

  defp ended_ok?(_state, _fun, _seen), do: true

  # Answering is :ok only while the request is pending.
  defp respond_ok?(%{phase: :pending}, :answer, _args, seen), do: seen.respond == :ok
  defp respond_ok?(_state, :answer, _args, seen), do: seen.respond == :error
  defp respond_ok?(_state, _fun, _args, _seen), do: true

  # --- commands -------------------------------------------------------------------

  # A turn that asks for a command's approval, or an MCP tool's confirmation, and
  # waits on it.
  def ask(n, kind) do
    send_message(n, if(kind == :permission, do: "approve run: touch x", else: "mcp confirm"))
    await(fn -> match?(%{status: "pending"}, snapshot().reqs[kind]) && snapshot() end)
  end

  # A turn Claude answers (uuid-N) without asking anything.
  def plain(n), do: turn(n, "where are we")

  # A turn Claude only compacts in (compact-N, no assistant uuid).
  def compact_only(n), do: turn(n, "/compact")

  # A turn Claude compacts in (compact-N) before answering (uuid-N).
  def grow(n), do: turn(n, "grow the conversation")

  defp turn(n, text) do
    run = send_message(n, text)
    ended = await_run(run, &(&1["status"] in ["completed", "failed", "interrupted"]))
    Map.put(snapshot(), :ended, ended["status"])
  end

  # The user's answer. An accepted/declined turn finishes on the fake's reply;
  # a cancelled one is interrupted; with nothing pending nothing more happens.
  def answer(kind, decision) do
    runs = StreamState.list(current(), "run")
    {request, _control_id} = @requests[kind]

    respond =
      case ThreadRuntime.respond(@tid, request, %{"decision" => decision}) do
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

  # What is read back: each kind's request's status and decision, and the resume
  # head the newest provider turn recorded (its newest nativeTurnRef).
  defp snapshot do
    state = current()
    requests = StreamState.list(state, "runtime-request")

    reqs =
      Map.new(@requests, fn {kind, {id, _control_id}} ->
        request = Enum.find(requests, &(&1["id"] == id))
        {kind, %{status: request && request["status"], decision: request && request["decision"]}}
      end)

    # `list/2` is in creation order, so the last head recorded wins.
    head =
      state
      |> StreamState.list("provider-turn")
      |> Enum.filter(&get_in(&1, ["nativeTurnRef", "nativeId"]))
      |> List.last()

    %{
      reqs: reqs,
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
