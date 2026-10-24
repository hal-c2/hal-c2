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
  alias HalC2.Test.Mc.World

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

  # The announcement has nothing but the kind, with the input as text for a search
  # (an agent may send that); the input comes with a later update.
  step ~r/^an ACP agent announces a call of kind "(?<kind>read|search)" and names its input (?<at>while it runs|when it finishes)$/,
       %{args: [kind, at]} = context do
    named = Map.delete(Map.fetch!(@acp_calls, kind), "title")
    update = %{"sessionUpdate" => "tool_call_update", "toolCallId" => "call-1"}
    announced = if kind == "search", do: %{"rawInput" => ""}, else: %{}

    updates =
      case at do
        "while it runs" ->
          [
            Map.merge(update, Map.put(named, "status", "in_progress")),
            Map.put(update, "status", "completed")
          ]

        "when it finishes" ->
          [Map.merge(update, Map.put(named, "status", "completed"))]
      end

    turn = %{
      "match" => "use the tool",
      "steps" =>
        [
          %{
            "update" =>
              Map.merge(announced, %{
                "sessionUpdate" => "tool_call",
                "toolCallId" => "call-1",
                "kind" => kind,
                "title" => kind,
                "status" => "pending"
              })
          }
        ] ++ Enum.map(updates, &%{"update" => &1}) ++ [%{"text" => "Done."}]
    }

    context
    |> FakeAcp.install("opencode", %{"turns" => [turn | FakeAcp.turns()]}, enabled: true)
    |> FakeAcp.thread("Agent work")
  end

  # Kimi CLI's calls as `src/kimi_cli/acp/session.py` sends them: the tool's name as
  # the title, the arguments' JSON streamed in as the content, the result at the end.
  @kimi_args %{
    "Shell" => %{"command" => "ls -la"},
    "ReadFile" => %{"path" => "src/app.ts"},
    "Grep" => %{"pattern" => "TODO"},
    "WriteFile" => %{"path" => "notes.md", "content" => "hi"}
  }

  step "Kimi streams a {string} call's arguments while it runs", %{args: [tool]} = context do
    args = JSON.encode!(Map.fetch!(@kimi_args, tool))
    [key | _] = Map.values(Map.fetch!(@kimi_args, tool))

    running = fn update, title, text ->
      %{
        "update" => %{
          "sessionUpdate" => update,
          "toolCallId" => "call-1",
          "title" => title,
          "status" => "in_progress",
          "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => text}}]
        }
      }
    end

    turn = %{
      "match" => "use the tool",
      "steps" => [
        running.("tool_call", tool, ""),
        running.("tool_call_update", tool, String.slice(args, 0, 8)),
        running.("tool_call_update", "#{tool}: #{key}", args),
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

    context |> kimi(turn) |> FakeAcp.thread("Agent work")
  end

  @kimi_task "List the modules in lib"
  @kimi_header "agent_id: a1\nresumed: false\nactual_subagent_type: explore\nstatus: completed\n\n"

  # Kimi's Agent tool: its arguments stream in like any call's, and the subagent's work
  # goes only to the session's record, as `SubagentEvent`s under the call's id (the
  # part of ACP's id after the turn's). The call ends with Kimi's header and the answer.
  step "Kimi hands a task to one of its subagents", context do
    args =
      JSON.encode!(%{
        "description" => "Survey lib",
        "subagent_type" => "explore",
        "prompt" => @kimi_task
      })

    call = fn update, title, text ->
      %{
        "update" => %{
          "sessionUpdate" => update,
          "toolCallId" => "turn-1/tool_agent",
          "title" => title,
          "status" => "in_progress",
          "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => text}}]
        }
      }
    end

    sub = fn parent, type, payload ->
      %{
        "type" => "SubagentEvent",
        "payload" => %{
          "parent_tool_call_id" => parent,
          "agent_id" => "a1",
          "subagent_type" => "explore",
          "event" => %{"type" => type, "payload" => payload}
        }
      }
    end

    shell = %{"type" => "function", "id" => "tool_ls", "function" => %{"name" => "Shell"}}

    record = [
      %{"type" => "StepBegin", "payload" => %{"n" => 1}},
      sub.("tool_agent", "StepBegin", %{"n" => 1}),
      sub.("tool_agent", "ContentPart", %{"type" => "think", "think" => "Look at lib."}),
      sub.("tool_agent", "ToolCall", put_in(shell, ["function", "arguments"], ~s({"comm))),
      sub.("tool_agent", "ToolCallPart", %{"arguments_part" => ~s(and":"ls lib"})}),
      sub.("tool_other", "ContentPart", %{"type" => "text", "text" => "Not this one's."}),
      sub.("tool_agent", "ToolResult", %{
        "tool_call_id" => "tool_ls",
        "return_value" => %{"is_error" => false, "output" => "a.ex\nb.ex\n", "message" => ""}
      }),
      sub.("tool_agent", "ContentPart", %{"type" => "text", "text" => "lib has "}),
      sub.("tool_agent", "ContentPart", %{"type" => "text", "text" => "two modules"})
    ]

    turn = %{
      "match" => "survey the code",
      "steps" => [
        call.("tool_call", "Agent", ""),
        call.("tool_call_update", "Agent: Survey lib", args),
        %{"kimiWire" => record},
        %{
          "update" => %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "turn-1/tool_agent",
            "status" => "completed",
            "content" => [
              %{
                "type" => "content",
                "content" => %{
                  "type" => "text",
                  "text" => @kimi_header <> "[summary]\nlib has two modules"
                }
              }
            ]
          }
        },
        %{"text" => "The survey is done."}
      ]
    }

    context |> kimi(turn) |> FakeAcp.thread("Agent work")
  end

  step "the MC projects the subagent", context do
    context = FakeAcp.send_message(context, "survey the code")
    state = FakeAcp.await_run(context, "completed")
    assert [subagent] = StreamState.list(state, "subagent")
    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))
    Map.merge(context, %{subagent: subagent, child: child})
  end

  step "the subagent's thread opens with its task", context do
    assert %{"title" => "Survey lib", "prompt" => @kimi_task, "status" => "completed"} =
             context.subagent

    assert [%{"role" => "user", "text" => @kimi_task} | _] =
             Enum.sort_by(StreamState.list(context.child, "message"), & &1["createdAt"])

    context
  end

  step "the subagent's thinking, commands and replies appear in its thread", context do
    items = Enum.sort_by(StreamState.list(context.child, "turn-item"), & &1["ordinal"])

    assert [
             %{"type" => "user_message"},
             %{"type" => "reasoning", "text" => "Look at lib."},
             %{"type" => "command_execution", "input" => "ls lib", "output" => "a.ex\nb.ex\n"} =
               command,
             %{"type" => "assistant_message", "text" => "lib has two modules"}
           ] = items

    assert command["status"] == "completed"
    context
  end

  step "the subagent's result is its answer, without Kimi's header", context do
    assert context.subagent["result"] == "lib has two modules"
    context
  end

  # Kimi CLI as a registry instance, running the fake with `turn`, and keeping its
  # session records in the fake's directory.
  defp kimi(context, turn) do
    context = FakeAcp.install(context, "kimi", %{"turns" => [turn | FakeAcp.turns()]})
    World.put_app_env(:acp_commands, %{"kimi" => [context.fakes["kimi"].bin]})
    HalC2.Acp.forget("kimi")
    ExUnit.Callbacks.on_exit(fn -> HalC2.Acp.forget("kimi") end)
    share = Path.join(context.fakes["kimi"].dir, "kimi")

    FakeAcp.settings(fn settings ->
      put_in(settings, [Access.key("providerInstances", %{}), "kimi"], %{
        "driver" => "acpRegistry",
        "enabled" => true,
        "config" => %{"agentId" => "kimi"},
        "environment" => [%{"name" => "KIMI_SHARE_DIR", "value" => share}]
      })
    end)

    context
  end

  step "the MC projects the call", context do
    context = FakeAcp.send_message(context, "use the tool")
    state = FakeAcp.await_run(context, "completed")

    assert [item] =
             Enum.filter(
               StreamState.list(state, "turn-item"),
               &(get_in(&1, ["nativeItemRef", "nativeId"]) == "call-1")
             )

    Map.put(context, :projected, item)
  end

  step ~r/^the timeline shows it as a (?<kind>file read|file search|web search|command|tool call that names only its file)$/,
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

      "command" ->
        assert %{"type" => "command_execution", "input" => "ls -la", "output" => "export {}"} =
                 item

      # The file's text stays out of the timeline, as a read's does.
      "tool call that names only its file" ->
        assert %{"type" => "dynamic_tool", "toolName" => "WriteFile"} = item
        assert item["input"] == %{"path" => "notes.md"}
    end

    context
  end

  defp changed_files(diff),
    do: for([_, path] <- Regex.scan(~r/^diff --git a\/(\S+) /m, diff), do: path) |> Enum.sort()
end
