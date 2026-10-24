defmodule HalC2.ClaudeSubagentPropTest do
  @moduledoc """
  A state machine over one Claude turn (`HalC2.Claude.ThreadRuntime`) into which the
  test plays Claude's stream-json, interleaving the parent's messages with those its
  subagents send under their tool calls (`parent_tool_use_id`): the parent streams
  and says text and runs commands; it starts a subagent and finishes it with its tool
  result; a running subagent streams, says text and runs commands; a subagent this
  runtime never saw, or one already finished, says something.

  The promise: whatever the order, the parent's turn shows exactly the parent's
  messages and commands, each subagent's thread exactly its own followed by its
  result, and a stray or late subagent message lands nowhere. An MCP call's tool use
  is a subagent's (`ThreadRuntime.subagent_tool?/2`, which refuses it `delegate_task`)
  exactly while the subagent that made it runs, never Claude's own.

  The turn runs on the fake CLI in `test/support/fake_claude.py`, which leaves a turn
  saying "wait" open; the test then sends the runtime Claude's messages itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "claude-thread"
  @agents ~w(a1 a2)
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 10_000

  property "a Claude turn keeps its subagents' messages in their own threads",
    numtests: HalC2.Prop.numtests(30),
    max_size: 40 do
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
    home = HalC2.Prop.scratch_home("claude-subagent")
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

    await_session(System.monotonic_time(:millisecond) + @wait_ms)
  end

  # Until the turn runs: the runtime holds its session and turn by then.
  defp await_session(deadline) do
    run = Enum.find(StreamState.list(current(@tid), "run"), &(&1["status"] == "running"))

    with %{} <- run,
         [{pid, _}] <- Registry.lookup(HalC2.Claude.Registry, @tid),
         %{session: session, turn: %{}} when session != nil <- :sys.get_state(pid) do
      :ok
    else
      _ ->
        receive do
          {:hal_c2_stream, @tid, _} -> await_session(deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> raise "no Claude turn"
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

  # --- model ----------------------------------------------------------------------

  # parent: the parent's texts, in order; open: the text of the message the parent is
  #   streaming, or nil; commands: how many commands the parent ran;
  # agents: name -> %{done: whether its tool result came, said: its texts in order,
  #   commands: how many it ran}; calls: the id of each tool call left waiting -> the
  #   agent that made it, or :parent; n: a counter for unique ids.
  def initial_state,
    do: %{parent: [], open: nil, commands: 0, agents: %{}, calls: %{}, n: 1}

  def command(%{agents: agents, calls: calls, n: n, open: open}) do
    running = for {a, %{done: false}} <- agents, do: a
    done = for {a, %{done: true}} <- agents, do: a
    fresh = @agents -- Map.keys(agents)

    [
      {3, {:call, __MODULE__, :parent_says, [n]}},
      {3, {:call, __MODULE__, :parent_streams, [n, open != nil]}},
      {1, {:call, __MODULE__, :parent_runs, [n]}},
      {1, {:call, __MODULE__, :stray, [n]}},
      {1, {:call, __MODULE__, :parent_calls, [n]}},
      {3, {:call, __MODULE__, :owner, [oneof(["call-unknown" | Map.keys(calls)])]}},
      {2, {:call, __MODULE__, :check, []}}
    ]
    |> Kernel.++(if open, do: [{2, {:call, __MODULE__, :parent_closes, [open]}}], else: [])
    |> Kernel.++(
      if fresh == [], do: [], else: [{2, {:call, __MODULE__, :start_agent, [oneof(fresh)]}}]
    )
    |> Kernel.++(
      if running == [],
        do: [],
        else: [
          {4, {:call, __MODULE__, :agent_says, [oneof(running), n]}},
          {3, {:call, __MODULE__, :agent_streams, [oneof(running), n]}},
          {2, {:call, __MODULE__, :agent_runs, [oneof(running), n]}},
          {2, {:call, __MODULE__, :agent_calls, [oneof(running), n]}},
          {1, {:call, __MODULE__, :finish_agent, [oneof(running)]}}
        ]
    )
    |> Kernel.++(
      if done == [], do: [], else: [{1, {:call, __MODULE__, :agent_says, [oneof(done), n]}}]
    )
    |> frequency()
  end

  def precondition(%{agents: agents}, {:call, _, :start_agent, [a]}),
    do: not is_map_key(agents, a)

  def precondition(%{agents: agents}, {:call, _, name, [a | _]})
      when name in [:agent_streams, :agent_runs, :agent_calls, :finish_agent],
      do: match?(%{done: false}, agents[a])

  def precondition(%{agents: agents}, {:call, _, :agent_says, [a, _]}),
    do: is_map_key(agents, a)

  def precondition(%{open: open}, {:call, _, :parent_closes, [text]}),
    do: open != nil and open == text

  def precondition(%{open: open}, {:call, _, :parent_streams, [_, opened]}),
    do: opened == (open != nil)

  # A parent message goes after the one it is streaming.
  def precondition(%{open: open}, {:call, _, name, _})
      when name in [
             :parent_says,
             :parent_runs,
             :parent_calls,
             :start_agent,
             :finish_agent,
             :check
           ],
      do: open == nil

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, name, _} = call) do
    state |> Map.update!(:n, &(&1 + 1)) |> step(call, name)
  end

  defp step(state, {_, _, _, [n]}, :parent_says), do: %{state | parent: state.parent ++ ["P#{n}"]}

  defp step(state, {_, _, _, [n, _]}, :parent_streams),
    do: %{state | open: (state.open || "") <> "Q#{n} "}

  defp step(state, _call, :parent_closes),
    do: %{state | parent: state.parent ++ [state.open], open: nil}

  defp step(state, _call, :parent_runs), do: %{state | commands: state.commands + 1}

  defp step(state, {_, _, _, [a]}, :start_agent),
    do: put_in(state.agents[a], %{done: false, said: [], commands: 0})

  defp step(state, {_, _, _, [a, n]}, :agent_says) do
    case state.agents[a] do
      %{done: false} -> update_in(state.agents[a].said, &(&1 ++ ["S#{n}"]))
      _ -> state
    end
  end

  defp step(state, {_, _, _, [a, _]}, :agent_runs),
    do: update_in(state.agents[a].commands, &(&1 + 1))

  defp step(state, {_, _, _, [n]}, :parent_calls), do: put_in(state.calls["call-#{n}"], :parent)
  defp step(state, {_, _, _, [a, n]}, :agent_calls), do: put_in(state.calls["call-#{n}"], a)

  # Its result is its answer, after what it said.
  defp step(state, {_, _, _, [a]}, :finish_agent),
    do: update_in(state.agents[a], &%{&1 | done: true, said: &1.said ++ ["R-#{a}"]})

  defp step(state, _call, _name), do: state

  def postcondition(%{calls: calls, agents: agents}, {:call, _, :owner, [id]}, subagent?),
    do: subagent? == match?(%{done: false}, agents[calls[id]])

  def postcondition(state, {:call, _, :check, []}, seen),
    do: seen == expected(state)

  def postcondition(_state, _call, result), do: result == :ok

  defp expected(state) do
    %{
      parent: state.parent,
      commands: state.commands,
      agents:
        Map.new(state.agents, fn {a, agent} ->
          {a, %{prompt: "Do #{a}", said: agent.said, commands: agent.commands}}
        end)
    }
  end

  # --- commands -------------------------------------------------------------------

  def parent_says(n), do: says([assistant("p#{n}", [text("P#{n}")])])

  # The first delta opens the message the parent streams; parent_closes/1 ends it.
  def parent_streams(n, true), do: says([stream(delta("Q#{n} "))])

  def parent_streams(n, false) do
    Process.put(:streaming, "p#{n}")

    says([
      stream(%{"type" => "message_start", "message" => %{"id" => "p#{n}"}}),
      stream(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      stream(delta("Q#{n} "))
    ])
  end

  def parent_closes(text) do
    id = Process.delete(:streaming)
    says([stream(%{"type" => "message_stop"}), assistant(id, [text(text)])])
  end

  def parent_runs(n), do: says(run("cmd-#{n}", "make #{n}"))

  def start_agent(a) do
    says([
      assistant("start-#{a}", [tool_use("agent-#{a}", "Agent", %{"prompt" => "Do #{a}"})]),
      %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => "task-#{a}",
        "tool_use_id" => "agent-#{a}",
        "prompt" => "Do #{a}",
        "task_type" => "local_agent"
      },
      under(a, user("Do #{a}"))
    ])
  end

  def agent_says(a, n), do: says([under(a, assistant("s#{n}", [text("S#{n}")]))])

  def agent_streams(a, n) do
    says(
      Enum.map(
        [
          %{"type" => "message_start", "message" => %{"id" => "s#{n}"}},
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          delta("not said yet")
        ],
        &under(a, stream(&1))
      )
    )
  end

  def agent_runs(a, n), do: says(Enum.map(run("sub-#{n}", "make #{n}"), &under(a, &1)))

  def finish_agent(a),
    do:
      says([
        user([%{"type" => "tool_result", "tool_use_id" => "agent-#{a}", "content" => "R-#{a}"}])
      ])

  # An MCP tool call left waiting, as a call to HAL-C2's server is while it runs.
  def parent_calls(n), do: says([assistant("m-call-#{n}", [mcp_call("call-#{n}")])])

  def agent_calls(a, n), do: says([under(a, assistant("m-call-#{n}", [mcp_call("call-#{n}")]))])

  def owner(id) do
    sync()
    HalC2.Claude.ThreadRuntime.subagent_tool?(@tid, id)
  end

  def stray(n), do: says([under("gone", assistant("x#{n}", [text("X#{n}")]))])

  # What the parent's turn and each subagent's thread show.
  def check do
    sync()
    state = current(@tid)
    items = StreamState.list(state, "turn-item")

    agents =
      for %{"childThreadId" => child} = sub <- StreamState.list(state, "subagent"), into: %{} do
        "agent-" <> a = sub["nativeTaskRef"]["nativeId"]
        child_items = StreamState.list(current(child), "turn-item")

        [{"user_message", prompt} | said] =
          for %{"type" => type} = item <- Enum.sort_by(child_items, & &1["ordinal"]),
              type in ["user_message", "assistant_message"],
              do: {type, item["text"]}

        {a,
         %{
           prompt: prompt,
           said: Enum.map(said, &elem(&1, 1)),
           commands: Enum.count(child_items, &(&1["type"] == "command_execution"))
         }}
      end

    %{
      parent:
        for(
          %{"type" => "assistant_message"} = item <- Enum.sort_by(items, & &1["ordinal"]),
          do: item["text"]
        ),
      commands: Enum.count(items, &(&1["type"] == "command_execution")),
      agents: agents
    }
  end

  # --- Claude's messages ------------------------------------------------------------

  defp says(messages) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, @tid)
    session = :sys.get_state(pid).session
    for message <- messages, do: send(pid, {:claude, session, {:message, message}})
    flush()
  end

  # Every message sent so far is handled once the runtime answers.
  defp sync do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, @tid)
    :sys.get_state(pid)
  end

  defp under(a, message), do: Map.put(message, "parent_tool_use_id", "agent-#{a}")

  defp run(id, command) do
    [
      assistant("m-#{id}", [tool_use(id, "Bash", %{"command" => command})]),
      user([%{"type" => "tool_result", "tool_use_id" => id, "content" => "ok"}])
    ]
  end

  defp assistant(id, content),
    do: %{"type" => "assistant", "message" => %{"id" => id, "content" => content}}

  defp user(content),
    do: %{"type" => "user", "message" => %{"role" => "user", "content" => content}}

  defp mcp_call(id), do: tool_use(id, "mcp__hal-c2__delegate_task", %{"task" => "Fan out"})

  defp text(text), do: %{"type" => "text", "text" => text}

  defp tool_use(id, name, input),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp stream(event), do: %{"type" => "stream_event", "event" => event}

  defp delta(text),
    do: %{
      "type" => "content_block_delta",
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => text}
    }

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
end
