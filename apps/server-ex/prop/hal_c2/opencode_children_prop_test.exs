defmodule HalC2.OpencodeChildrenPropTest do
  @moduledoc """
  A state machine over one OpenCode 2 thread (`HalC2.Acp.ThreadRuntime`) whose turns start
  background subagents: a turn starts a child in the background, or steers a child (a
  later `subagent` call naming its session) that either joins the child's run or fails on
  its own; between turns a child says something, or OpenCode reports its run's end
  (`opencode/session/child_update` with status completed, failed or interrupted), which is
  the only end of a background child OpenCode 2's ACP sends.

  A report can also come from outside the thread's own children (hal-c2#1316): a grandchild's
  (whose parent is a child), or one naming a child's session under a parent that is not the
  thread's session.

  The promise: once a child's run ends, no call attached to it (the start and every steer
  that joined that run) is still running, each ends as the run did, and a steer that
  failed on its own keeps "failed". A report of a child that is not running ends nothing,
  nor does a report from outside the thread's children, and a steer of an ended child
  starts a run of its own that the next report ends.

  Turns run on `test/support/fake_acp_scripted.py`, which sends the `subagent` tool as
  `opencode acp` 2.2 does; the child's updates and reports go to the runtime as its
  connection delivers them, as the feature steps in `opencode_steps.exs` do. After each
  command the test waits for the turn's run to end, or for the runtime to have handled
  the report, then reads the thread's subagents.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "opencode-children-thread"
  @model %{"instanceId" => "opencode", "model" => "fake/one"}
  @fake_acp Path.expand("../../test/support/fake_acp_scripted.py", __DIR__)
  @ended ~w(completed failed interrupted cancelled)
  @children 3
  @wait_ms 10_000

  property "an OpenCode 2 child's end ends every call attached to its run",
    numtests: HalC2.Prop.numtests(20),
    max_size: 15 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("opencode-children")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        bin = install_fake(home)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
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

        HalC2.Acp.forget("opencode")

        {:ok, _} =
          HalC2.Settings.put(
            %{"providers" => %{"opencode" => %{"enabled" => true, "binaryPath" => bin}}},
            0
          )

        create(work)
        :ok = HalC2.Streams.subscribe(@tid, self(), nil)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Acp.forget("opencode")
        Process.delete(:fake_dir)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # children: each child's run, "running" or how it ended; calls: [{call, child, status}]
  # in the order the turns made them; next: numbers the next call; turns: turns run.
  def initial_state, do: %{children: %{}, calls: [], next: 1, turns: 0}

  def command(%{children: children, next: next}) do
    started = Map.keys(children)
    spawn = {3, {:call, __MODULE__, :spawn, ["c#{next}", map_size(children) + 1]}}

    if started == [] do
      frequency([spawn])
    else
      child = oneof(started)

      frequency([
        spawn,
        {3, {:call, __MODULE__, :steer, ["c#{next}", child, oneof([:joins, :fails])]}},
        {3, {:call, __MODULE__, :report, [child, oneof(~w(completed failed interrupted))]}},
        {1,
         {:call, __MODULE__, :stray,
          [child, oneof(~w(completed failed interrupted)), oneof([:grandchild, :elsewhere])]}},
        {1, {:call, __MODULE__, :says, [child]}}
      ])
    end
  end

  def precondition(%{children: children, next: next}, {:call, _, :spawn, [call, child]}),
    do: call == "c#{next}" and child == map_size(children) + 1 and child <= @children

  def precondition(%{children: children, next: next}, {:call, _, :steer, [call, child, _]}),
    do: call == "c#{next}" and Map.has_key?(children, child)

  def precondition(%{children: children}, {:call, _, _, [child | _]}),
    do: Map.has_key?(children, child)

  def next_state(state, _result, {:call, _, :spawn, [call, child]}),
    do: run(state, call, child, "running")

  # A steer that joins an ended child's session starts a run of its own.
  def next_state(state, _result, {:call, _, :steer, [call, child, :joins]}),
    do: run(state, call, child, "running")

  def next_state(state, _result, {:call, _, :steer, [call, child, :fails]}) do
    %{
      state
      | calls: state.calls ++ [{call, child, "failed"}],
        next: state.next + 1,
        turns: state.turns + 1
    }
  end

  def next_state(state, _result, {:call, _, :report, [child, status]}) do
    if state.children[child] == "running" do
      calls =
        for {call, c, s} <- state.calls,
            do: {call, c, if(c == child and s == "running", do: status, else: s)}

      %{state | children: Map.put(state.children, child, status), calls: calls}
    else
      state
    end
  end

  def next_state(state, _result, {:call, _, :says, _}), do: state
  def next_state(state, _result, {:call, _, :stray, _}), do: state

  defp run(state, call, child, status) do
    %{
      state
      | children: Map.put(state.children, child, status),
        calls: state.calls ++ [{call, child, status}],
        next: state.next + 1,
        turns: state.turns + 1
    }
  end

  def postcondition(state, call, seen) do
    model = next_state(state, nil, call)
    seen == %{turns: List.duplicate("completed", model.turns), calls: statuses(model.calls)}
  end

  defp statuses(calls), do: for({call, _, status} <- calls, do: {call, status})

  # --- commands ---------------------------------------------------------------------

  defp create(work) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "OpenCode",
        "modelSelection" => @model,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })
  end

  # A turn whose `subagent` call `call` starts child `child` in the background.
  def spawn(call, child) do
    turn(subagent(call, input("Explore", child, false), "completed", working(child), child))
  end

  # A turn whose `subagent` call `call` names child `child`'s session: OpenCode either sends
  # it to the child's run (:joins) or fails to prompt the child (:fails).
  def steer(call, child, :joins),
    do: turn(subagent(call, input("Again", child, true), "completed", working(child), child))

  def steer(call, child, :fails) do
    text = "Failed to prompt subagent: #{session(child)}"
    turn(subagent(call, input("Again", child, true), "failed", text, child))
  end

  # OpenCode's report that child `child`'s run ended as `status`.
  def report(child, status) do
    opencode_child(child, %{"type" => "status", "status" => status, "title" => "Explore"})
  end

  # A report from outside the thread's children: the end of a grandchild that child `child`
  # started, or one naming `child`'s session under another parent.
  def stray(child, status, :grandchild) do
    opencode_child(child, %{
      "type" => "status",
      "status" => status,
      "childSessionId" => "#{session(child)}_grand",
      "parentSessionId" => session(child),
      "depth" => 2
    })
  end

  def stray(child, status, :elsewhere) do
    opencode_child(child, %{
      "type" => "status",
      "status" => status,
      "parentSessionId" => "ses_elsewhere"
    })
  end

  # Something child `child` says, outside any turn of the thread.
  def says(child) do
    update = %{
      "sessionUpdate" => "agent_message_chunk",
      "messageId" => "child-#{child}-#{System.unique_integer([:positive])}",
      "content" => %{"type" => "text", "text" => "Looked at lib/."}
    }

    opencode_child(child, %{"type" => "update", "update" => update})
  end

  defp turn(steps) do
    config = %{
      "version" => "2.2.0",
      "turns" => [%{"match" => "", "steps" => steps ++ [%{"text" => "Started."}]}]
    }

    File.write!(Path.join(Process.get(:fake_dir), "config.json"), JSON.encode!(config))

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{System.unique_integer([:positive])}",
        "text" => "go",
        "attachments" => [],
        "modelSelection" => @model,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    settled(System.monotonic_time(:millisecond) + @wait_ms)
  end

  # Delivers OpenCode's `opencode/session/child_update` for `child` (a direct child of the
  # thread's session, unless `params` says otherwise) as the runtime's connection does, and
  # reads the thread once the runtime has handled it.
  defp opencode_child(child, params) do
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, @tid)
    %{conn: conn, session_id: root} = :sys.get_state(pid)

    params =
      Map.merge(
        %{
          "rootSessionId" => root,
          "childSessionId" => session(child),
          "parentSessionId" => root,
          "depth" => 1
        },
        params
      )

    send(pid, {:json_rpc, conn, {:notification, "opencode/session/child_update", params}})
    _ = :sys.get_state(pid)
    flush()
    projection(current())
  end

  # The `subagent` tool as `opencode acp` 2.2 sends it (packages/cli/src/acp/tool.ts): opened
  # with no input, the input streamed after, and the child's session in `rawOutput.metadata`.
  defp subagent(call, input, status, text, child) do
    tool = %{"toolCallId" => call, "title" => "subagent", "kind" => "think"}

    [
      %{
        "update" =>
          Map.merge(tool, %{
            "sessionUpdate" => "tool_call",
            "status" => "pending",
            "rawInput" => %{}
          })
      },
      %{
        "update" =>
          Map.merge(tool, %{
            "sessionUpdate" => "tool_call_update",
            "status" => "in_progress",
            "rawInput" => input
          })
      },
      %{
        "update" =>
          Map.merge(tool, %{
            "sessionUpdate" => "tool_call_update",
            "status" => status,
            "rawInput" => input,
            "content" => [
              %{"type" => "content", "content" => %{"type" => "text", "text" => text}}
            ],
            "rawOutput" => %{
              "metadata" => %{"sessionID" => session(child), "status" => "running"}
            }
          })
      }
    ]
  end

  defp input(description, child, again?) do
    input = %{
      "agent" => "general",
      "description" => description,
      "prompt" => "#{description} #{child}",
      "background" => true
    }

    if again?, do: Map.put(input, "sessionID", session(child)), else: input
  end

  defp working(child),
    do:
      "The subagent is working in the background (sessionID: #{session(child)}). " <>
        "You will be notified automatically when it finishes."

  defp session(child), do: "ses_child#{child}"

  # --- the real side ----------------------------------------------------------------

  defp install_fake(home) do
    dir = Path.join(home, "fake-opencode")
    File.mkdir_p!(dir)
    Process.put(:fake_dir, dir)
    File.write!(Path.join(dir, "config.json"), JSON.encode!(%{"version" => "2.2.0"}))
    bin = Path.join([dir, "bin", "opencode"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}'
    exec python3 -u '#{@fake_acp}' "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  defp call_number("c" <> n), do: String.to_integer(n)
  defp call_number(other), do: {:other, other}

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))

  # Waits until every run of the thread ended.
  defp settled(deadline) do
    flush()
    state = current()
    projection = projection(state)

    if Enum.all?(StreamState.list(state, "run"), &(&1["status"] in @ended)) do
      projection
    else
      receive do
        {:hal_c2_stream, @tid, _} -> settled(deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, projection}
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

  # The runs' statuses, and each subagent call's, in the order they were made.
  defp projection(state) do
    %{
      turns:
        for(
          run <- state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"]),
          do: run["status"]
        ),
      calls:
        for(
          sub <- StreamState.list(state, "subagent"),
          do: {get_in(sub, ["nativeTaskRef", "nativeId"]), sub["status"]}
        )
        |> Enum.sort_by(fn {call, _} -> call_number(call) end)
    }
  end
end
