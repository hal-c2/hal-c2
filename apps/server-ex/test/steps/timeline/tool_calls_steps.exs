defmodule HalC2.Steps.Timeline.ToolCalls do
  @moduledoc """
  Steps for `features/timeline/tool-calls.feature`. The three turns each write one file
  with the fake Codex: "turn-1.txt", "turn-2.txt", "turn-3.txt". The ACP agent is the
  scripted fake (`HalC2.Test.FakeAcp`) standing in for OpenCode.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Node.World

  # What the agent's tool call carries, by its ACP kind.
  @acp_calls %{
    "read" => %{
      "title" => "Read src/app.ts",
      "locations" => [%{"path" => "src/app.ts"}],
      "rawInput" => %{"path" => "src/app.ts"}
    },
    "search" => %{"title" => "Search for TODO", "rawInput" => %{"pattern" => "TODO"}},
    "fetch" => %{
      "title" => "Fetch the docs",
      "rawInput" => %{"url" => "https://example.com/docs"}
    }
  }

  step "a thread with three finished turns", context do
    World.finished_turns(
      context,
      World.current(context),
      for(n <- 1..3, do: "write turn-#{n}.txt")
    )
  end

  step "a client asks for the diff of the second turn", context do
    {result, context} =
      World.call!(context, "orchestration.getTurnDiff", %{
        "threadId" => World.thread_id(context, World.current(context)),
        "fromTurnCount" => 1,
        "toTurnCount" => 2
      })

    Map.put(context, :diff, result)
  end

  step "it receives the changes made during the second turn", context do
    assert %{"fromTurnCount" => 1, "toTurnCount" => 2, "diff" => diff} = context.diff
    assert changed_files(diff) == ["turn-2.txt"]
    assert diff =~ "+write turn-2.txt"
    context
  end

  step "a client asks for the whole thread's diff", context do
    {result, context} =
      World.call!(context, "orchestration.getFullThreadDiff", %{
        "threadId" => World.thread_id(context, World.current(context)),
        "toTurnCount" => 3
      })

    Map.put(context, :diff, result)
  end

  step "it receives the changes from before the first turn to after the last", context do
    assert %{"fromTurnCount" => 0, "toTurnCount" => 3, "diff" => diff} = context.diff
    assert changed_files(diff) == ["turn-1.txt", "turn-2.txt", "turn-3.txt"]
    context
  end

  step "an ACP agent's tool call is of kind {string}", %{args: [kind]} = context do
    call = Map.merge(Map.fetch!(@acp_calls, kind), %{"toolCallId" => "call-1", "kind" => kind})

    turn = %{
      "match" => "use the tool",
      "steps" => [
        %{"update" => Map.merge(call, %{"sessionUpdate" => "tool_call", "status" => "pending"})},
        %{
          "update" => %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "call-1",
            "status" => "completed",
            "content" => [
              %{"type" => "content", "content" => %{"type" => "text", "text" => "export {}"}}
            ]
          }
        },
        %{"text" => "Done."}
      ]
    }

    context
    |> FakeAcp.install("opencode", %{"turns" => [turn | FakeAcp.turns()]}, enabled: true)
    |> FakeAcp.thread("Agent work")
  end

  step "the node projects the call", context do
    context = FakeAcp.send_message(context, "use the tool")
    state = FakeAcp.await_run(context, "completed")

    assert [item] =
             Enum.filter(
               StreamState.list(state, "turn-item"),
               &(get_in(&1, ["nativeItemRef", "nativeId"]) == "call-1")
             )

    Map.put(context, :projected, item)
  end

  step ~r/^the timeline shows it as a (?<kind>file read|file search|web search)$/,
       %{args: [kind]} = context do
    item = context.projected
    assert item["status"] == "completed"

    case kind do
      "file read" ->
        assert %{"type" => "file_search", "pattern" => "src/app.ts"} = item
        assert item["results"] == [%{"fileName" => "src/app.ts"}]

      "file search" ->
        assert %{"type" => "file_search", "pattern" => "TODO"} = item
        refute Map.has_key?(item, "results")

      "web search" ->
        assert %{"type" => "web_search", "patterns" => ["https://example.com/docs"]} = item
    end

    context
  end

  defp changed_files(diff),
    do: for([_, path] <- Regex.scan(~r/^diff --git a\/(\S+) /m, diff), do: path) |> Enum.sort()
end
