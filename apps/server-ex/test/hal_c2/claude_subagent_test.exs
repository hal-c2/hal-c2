defmodule HalC2.ClaudeSubagentTest do
  # A subagent's stream-json, recorded in the order Claude interleaves it with the
  # parent's: what it says, streams and runs goes to its own thread, never the turn.
  use ExUnit.Case, async: false

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @thread "Survey"

  setup %{tmp_dir: dir} do
    context =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> then(&World.put_client(&1, World.client(&1)))
      |> World.fake_providers()
      # The fake leaves a turn that says "wait" open: the test plays Claude's side.
      |> World.launch_on(@thread, "claudeAgent", "wait for the survey")

    World.await_running(context, @thread)
    {:ok, context: context}
  end

  test "a subagent's messages go to its thread while the parent's turn streams on",
       %{context: context} do
    side = &Map.put(&1, "parent_tool_use_id", "agent-1")

    for message <- [
          # The parent starts streaming its answer...
          stream("p1", {:start, "p1"}),
          stream("p1", {:block, 0}),
          stream("p1", {:delta, 0, "Asking a "}),
          # ...and calls a subagent, which streams and speaks under its tool call.
          assistant("p2", [tool_use("agent-1", "Agent", %{"prompt" => "Check the tests"})]),
          task("task_started", %{"prompt" => "Check the tests", "task_type" => "local_agent"}),
          side.(user("Check the tests")),
          side.(stream("s1", {:start, "s1"})),
          side.(stream("s1", {:block, 0})),
          side.(stream("s1", {:delta, 0, "Running"})),
          side.(
            assistant("s1", [
              %{"type" => "thinking", "thinking" => "Which tests?"},
              %{"type" => "text", "text" => "Running the tests"},
              tool_use("sub-bash", "Bash", %{"command" => "mix test"}),
              tool_use("sub-todo", "TodoWrite", %{"todos" => []})
            ])
          ),
          task("task_progress", %{"summary" => "Ran mix test"}),
          side.(user([result("sub-bash", "12 tests, 0 failures"), result("sub-todo", "ok")])),
          # A subagent this runtime never saw a call for: not this turn's.
          Map.put(
            assistant("x1", [%{"type" => "text", "text" => "Stray"}]),
            "parent_tool_use_id",
            "agent-gone"
          ),
          side.(assistant("s2", [%{"type" => "text", "text" => "The tests pass"}])),
          user([result("agent-1", "The tests pass")]),
          assistant("p3", [%{"type" => "text", "text" => "They pass"}]),
          %{
            "type" => "result",
            "subtype" => "success",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          }
        ],
        do: claude_says(context, message)

    World.await_runs(context, @thread, ["completed"])
    state = World.stream(context, @thread)
    items = StreamState.list(state, "turn-item")

    assert ["Asking a ", "They pass"] =
             items
             |> Enum.filter(&(&1["type"] == "assistant_message"))
             |> Enum.sort_by(& &1["ordinal"])
             |> Enum.map(& &1["text"])

    assert [] = Enum.filter(items, &(&1["type"] in ["command_execution", "reasoning"]))
    assert [] = StreamState.list(state, "plan")
    refute Enum.any?(items, &(&1["status"] == "running"))

    assert [%{"status" => "completed", "result" => "The tests pass", "childThreadId" => child}] =
             StreamState.list(state, "subagent")

    child = child |> HalC2.Streams.ensure() |> HalC2.Streams.Server.state()
    child_items = child |> StreamState.list("turn-item") |> Enum.sort_by(& &1["ordinal"])

    assert [
             {"user_message", "Check the tests"},
             {"reasoning", "Which tests?"},
             {"assistant_message", "Running the tests"},
             {"command_execution", "12 tests, 0 failures"},
             {"dynamic_tool", "ok"},
             {"reasoning", "Ran mix test"},
             {"assistant_message", "The tests pass"}
           ] = Enum.map(child_items, &{&1["type"], &1["output"] || &1["text"]})

    refute Enum.any?(child_items, &(&1["status"] == "running"))

    # Between turns a subagent's chatter is not Claude starting a turn by itself.
    claude_says(context, side.(assistant("s3", [%{"type" => "text", "text" => "Late"}])))
    assert %{turn: nil, wake: nil} = :sys.get_state(runtime(context))
    assert [%{}] = StreamState.list(World.stream(context, @thread), "run")
  end

  test "a subagent's answer shows once though Claude's tool result adds its agent id",
       %{context: context} do
    side = &Map.put(&1, "parent_tool_use_id", "agent-1")

    for message <- [
          assistant("p1", [tool_use("agent-1", "Agent", %{"prompt" => "Check the tests"})]),
          side.(user("Check the tests")),
          side.(assistant("s1", [%{"type" => "text", "text" => "The tests pass"}])),
          user([
            result("agent-1", [
              %{"type" => "text", "text" => "The tests pass"},
              %{"type" => "text", "text" => "agentId: a1b2c3 (for resuming this agent)"},
              %{"type" => "text", "text" => "<usage>total_tokens: 1200</usage>"}
            ])
          ]),
          %{"type" => "result", "subtype" => "success"}
        ],
        do: claude_says(context, message)

    World.await_runs(context, @thread, ["completed"])
    assert ["The tests pass"] = child_messages(context)
  end

  # Between turns a background subagent's messages wait with a wake for its run; its
  # delegate_task is refused there too, and its task's summary is not its answer.
  test "a background subagent between turns keeps its tool calls and its answer",
       %{context: context} do
    side = &Map.put(&1, "parent_tool_use_id", "agent-1")
    thread_id = World.thread_id(context, @thread)

    for message <- [
          assistant("p1", [
            tool_use("agent-1", "Agent", %{"prompt" => "Survey", "run_in_background" => true})
          ]),
          task("task_started", %{"prompt" => "Survey", "is_backgrounded" => true}),
          side.(user("Survey")),
          user([result("agent-1", "Async agent launched")]),
          %{"type" => "result", "subtype" => "success"}
        ],
        do: claude_says(context, message)

    World.await_runs(context, @thread, ["completed"])

    # The thread's stream held, the wake's run cannot start: its messages wait.
    stream = HalC2.Streams.ensure(thread_id)
    :sys.suspend(stream)

    try do
      claude_says(context, assistant("w1", [%{"type" => "text", "text" => "Checking in"}]))

      claude_says(
        context,
        side.(assistant("s1", [tool_use("call-1", "mcp__hal-c2__delegate_task", %{})]))
      )

      assert %{turn: nil, wake: %{buffer: [_, _]}} = :sys.get_state(runtime(context))
      assert HalC2.Claude.ThreadRuntime.subagent_tool?(thread_id, "call-1")
      refute HalC2.Claude.ThreadRuntime.subagent_tool?(thread_id, "call-other")
    after
      :sys.resume(stream)
    end

    for message <- [
          side.(assistant("s2", [%{"type" => "text", "text" => "Found three files"}])),
          task("task_notification", %{"status" => "completed", "summary" => "Agent completed"}),
          %{"type" => "result", "subtype" => "success"}
        ],
        do: claude_says(context, message)

    World.await_runs(context, @thread, ["completed", "completed"])
    assert ["Found three files"] = child_messages(context)

    assert [%{"status" => "completed", "result" => "Agent completed"}] =
             StreamState.list(World.stream(context, @thread), "subagent")
  end

  defp stream(_id, {:start, id}),
    do: event(%{"type" => "message_start", "message" => %{"id" => id}})

  defp stream(_id, {:block, index}),
    do:
      event(%{
        "type" => "content_block_start",
        "index" => index,
        "content_block" => %{"type" => "text", "text" => ""}
      })

  defp stream(_id, {:delta, index, text}),
    do:
      event(%{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "text_delta", "text" => text}
      })

  defp event(event), do: %{"type" => "stream_event", "event" => event}

  defp assistant(id, content),
    do: %{"type" => "assistant", "message" => %{"id" => id, "content" => content}}

  defp user(content),
    do: %{"type" => "user", "message" => %{"role" => "user", "content" => content}}

  defp tool_use(id, name, input),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp result(id, content),
    do: %{"type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => false}

  defp task(subtype, fields),
    do:
      Map.merge(
        %{
          "type" => "system",
          "subtype" => subtype,
          "task_id" => "task-agent-1",
          "tool_use_id" => "agent-1"
        },
        fields
      )

  defp child_messages(context) do
    [%{"childThreadId" => child}] = StreamState.list(World.stream(context, @thread), "subagent")

    child
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == "assistant_message"))
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(& &1["text"])
  end

  defp runtime(context) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    pid
  end

  defp claude_says(context, message) do
    pid = runtime(context)
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end
end
