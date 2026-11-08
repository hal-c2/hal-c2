defmodule HalC2.ClaudeBackgroundWaitPropTest do
  @moduledoc """
  A state machine over the background work of one Claude thread
  (`HalC2.Claude.ThreadRuntime`) and the agent's marks on it
  (`ThreadRuntime.await_background/3`, behind `hal_c2_background_wait`): the test plays
  Claude starting background commands and their ends, and the agent marking and
  clearing ids, Claude's task ids or the tool use ids, running or not.

  The promise: a mark matches exactly the ids of work still running, and the running
  commands marked awaited (what `HalC2.Projection.BackgroundWork.holding/1` holds the
  thread for) are exactly those whose last matched mark was a wait, whatever the
  order. An unmatched id changes nothing.

  The turn runs on the fake CLI in `test/support/fake_claude.py`, which leaves a turn
  saying "wait" open; the test then sends the runtime Claude's messages itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "claude-wait-thread"
  @commands ~w(c1 c2 c3)
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 10_000

  property "only the running work the agent waits on holds a Claude thread",
    numtests: HalC2.Prop.numtests(30),
    max_size: 30 do
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
    home = HalC2.Prop.scratch_home("claude-background-wait")
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

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Claude",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m1",
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await(fn -> session() != nil end)
  end

  # --- model ----------------------------------------------------------------------

  # running: the commands started and not ended; awaited: those whose last matched mark
  # was a wait; started: every command started, ended or not.
  def initial_state, do: %{running: MapSet.new(), awaited: MapSet.new(), started: MapSet.new()}

  def command(%{running: running, started: started}) do
    fresh = @commands -- MapSet.to_list(started)
    known = MapSet.to_list(started) ++ ["c9"]

    [
      {3, {:call, __MODULE__, :mark, [ids(oneof(known)), boolean()]}},
      {2, {:call, __MODULE__, :check, []}}
    ]
    |> Kernel.++(if fresh == [], do: [], else: [{3, {:call, __MODULE__, :start, [oneof(fresh)]}}])
    |> Kernel.++(
      if MapSet.size(running) == 0,
        do: [],
        else: [{2, {:call, __MODULE__, :finish, [oneof(MapSet.to_list(running))]}}]
    )
    |> frequency()
  end

  # One to three ids; the agent names work by Claude's task id or by the tool use id.
  defp ids(command) do
    id = oneof([{:task, command}, {:tool, command}])
    oneof([vector(1, id), vector(2, id), vector(3, id)])
  end

  def precondition(%{started: started}, {:call, _, :start, [c]}), do: c not in started
  def precondition(%{running: running}, {:call, _, :finish, [c]}), do: c in running

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :start, [c]}),
    do: %{state | running: MapSet.put(state.running, c), started: MapSet.put(state.started, c)}

  def next_state(state, _result, {:call, _, :finish, [c]}),
    do: %{
      state
      | running: MapSet.delete(state.running, c),
        awaited: MapSet.delete(state.awaited, c)
    }

  def next_state(state, _result, {:call, _, :mark, [ids, waiting]}) do
    matched = for {_, c} <- ids, c in state.running, into: MapSet.new(), do: c

    awaited =
      if waiting,
        do: MapSet.union(state.awaited, matched),
        else: MapSet.difference(state.awaited, matched)

    %{state | awaited: awaited}
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :mark, [ids, _]}, {:ok, matched}),
    do: matched == for(id <- Enum.uniq(Enum.map(ids, &native/1)), running?(state, id), do: id)

  def postcondition(state, {:call, _, :check, []}, {running, holding}),
    do:
      running == Enum.sort(state.running) and
        holding == Enum.sort(MapSet.intersection(state.awaited, state.running))

  def postcondition(_state, _call, result), do: result == :ok

  defp running?(state, id), do: Enum.any?(state.running, &(id in [native({:task, &1}), &1]))

  # --- commands -------------------------------------------------------------------

  def start(c) do
    says([
      %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-#{c}",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => c,
              "name" => "Bash",
              "input" => %{"command" => "run #{c}", "run_in_background" => true}
            }
          ]
        }
      },
      %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => native({:task, c}),
        "tool_use_id" => c,
        "description" => c,
        "task_type" => "local_bash"
      },
      %{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => c,
              "content" => "Command running in background with ID: #{native({:task, c})}"
            }
          ]
        }
      }
    ])
  end

  def finish(c) do
    says([
      %{
        "type" => "system",
        "subtype" => "task_notification",
        "task_id" => native({:task, c}),
        "tool_use_id" => c,
        "status" => "completed",
        "summary" => "#{c} ended"
      }
    ])
  end

  def mark(ids, waiting),
    do: HalC2.Claude.ThreadRuntime.await_background(@tid, Enum.map(ids, &native/1), waiting)

  # The running background commands and those marked awaited, by tool use id.
  def check do
    pid() |> :sys.get_state()

    running =
      for %{"type" => "command_execution", "status" => "running"} = item <-
            StreamState.list(current(), "turn-item"),
          do: {item["nativeItemRef"]["nativeId"], item["awaited"] == true}

    {running |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
     for({id, true} <- running, do: id) |> Enum.sort()}
  end

  defp native({:task, c}), do: "task-" <> c
  defp native({:tool, c}), do: c

  # --- Claude ---------------------------------------------------------------------

  defp says(messages) do
    pid = pid()
    session = :sys.get_state(pid).session
    for message <- messages, do: send(pid, {:claude, session, {:message, message}})
    # Every message sent so far is handled once the runtime answers.
    :sys.get_state(pid)
    :ok
  end

  defp pid do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, @tid)
    pid
  end

  defp session do
    with %{} <- Enum.find(StreamState.list(current(), "run"), &(&1["status"] == "running")),
         [{pid, _}] <- Registry.lookup(HalC2.Claude.Registry, @tid),
         %{session: session, turn: %{}} <- :sys.get_state(pid),
         do: session,
         else: (_ -> nil)
  end

  # Until `ready` holds, on the thread's stream events.
  defp await(ready, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    unless ready.() do
      receive do
        {:hal_c2_stream, @tid, _} -> await(ready, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          raise "the thread never got there"
      end
    end

    :ok
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
end
