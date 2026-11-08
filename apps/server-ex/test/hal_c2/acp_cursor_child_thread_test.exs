defmodule HalC2.Acp.CursorChildThreadTest do
  # Review of hal-c2/hal-c2#1284: what a Cursor subagent's updates write to its child
  # thread. The updates are the ACP ones the sidecar sends for the child's session.
  use ExUnit.Case, async: false

  alias HalC2.Acp.ThreadRuntime
  alias HalC2.Orchestration.NativeSubagent
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
      |> World.create_thread(@thread)

    thread = World.thread_id(context, @thread)

    ids = %{
      thread: thread,
      run: "run-1",
      root_node: "node:root",
      provider_thread: nil,
      driver: "cursor"
    }

    sub = NativeSubagent.start(ids, "task-1", %{"prompt" => "List the modules"})
    state = %{subagents: %{"task-1" => %{session: "child-s", sub: sub}}, orphans: %{}}
    {:ok, state: state, sub: sub}
  end

  defp update(state, update),
    do: ThreadRuntime.child_update(%{"sessionId" => "child-s", "update" => update}, state)

  defp items(state) do
    state.subagents["task-1"].sub.child
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.list("turn-item")
    |> Enum.sort_by(& &1["ordinal"])
  end

  test "the child's messages keep to their ids, in order around its tool call", %{state: state} do
    text =
      &%{
        "sessionUpdate" => "agent_message_chunk",
        "messageId" => &1,
        "content" => %{"text" => &2}
      }

    state =
      state
      |> update(text.("m1", "Check"))
      |> update(text.("m1", "ing"))
      |> update(%{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "c1",
        "kind" => "execute",
        "rawInput" => %{"command" => "ls"}
      })
      |> update(text.("m2", "Done"))

    assert [
             {"assistant_message", "Checking"},
             {"command_execution", _},
             {"assistant_message", "Done"}
           ] =
             items(state)
             |> Enum.filter(&(&1["type"] != "user_message"))
             |> Enum.map(&{&1["type"], &1["text"] || &1["input"]})
  end

  test "a sparse update keeps the command the child announced", %{state: state} do
    state =
      state
      |> update(%{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "c1",
        "kind" => "execute",
        "rawInput" => %{"command" => "make test"}
      })
      |> update(%{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "c1",
        "status" => "completed",
        "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => "ok"}}]
      })

    assert [
             %{
               "type" => "command_execution",
               "input" => "make test",
               "output" => "ok",
               "status" => "completed"
             }
           ] =
             Enum.filter(items(state), &(&1["type"] == "command_execution"))
  end

  test "a child's command output is cut to what a thread keeps", %{state: state} do
    big = String.duplicate("x", HalC2.Orchestration.CommandTail.kept() * 3)

    state =
      update(state, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "c1",
        "kind" => "execute",
        "status" => "completed",
        "rawInput" => %{"command" => "yes"},
        "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => big}}]
      })

    [%{"output" => output}] = Enum.filter(items(state), &(&1["type"] == "command_execution"))
    assert byte_size(output) <= HalC2.Orchestration.CommandTail.kept() + 200
  end
end
