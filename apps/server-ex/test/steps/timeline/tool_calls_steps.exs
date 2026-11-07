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

  # Kimi Code's calls as `packages/acp-server/src/events-map.ts` sends them: created
  # from the first streamed arguments under the tool's name, the arguments' JSON text
  # as the content while they stream, then the whole input under the call's
  # description, and the result at the end.
  @kimi_args %{
    "Bash" => %{"command" => "ls -la", "description" => "List the files"},
    "Read" => %{"path" => "src/app.ts"},
    "Grep" => %{"pattern" => "TODO", "path" => "src"},
    "Write" => %{"path" => "notes.md", "content" => "hi"}
  }

  @kimi_kinds %{"Bash" => "execute", "Read" => "read", "Grep" => "read", "Write" => "edit"}

  step "Kimi streams a {string} call's arguments while it runs", %{args: [tool]} = context do
    input = Map.fetch!(@kimi_args, tool)
    args = JSON.encode!(input)
    text = &[%{"type" => "content", "content" => %{"type" => "text", "text" => &1}}]
    call = %{"toolCallId" => "call-1"}

    turn = %{
      "match" => "use the tool",
      "steps" =>
        Enum.map(
          [
            Map.merge(call, %{
              "sessionUpdate" => "tool_call",
              "title" => tool,
              "kind" => @kimi_kinds[tool],
              "status" => "pending",
              "content" => text.(String.slice(args, 0, 8))
            }),
            Map.merge(call, %{
              "sessionUpdate" => "tool_call_update",
              "status" => "in_progress",
              "content" => text.(args)
            }),
            Map.merge(call, %{
              "sessionUpdate" => "tool_call_update",
              "title" => input["description"] || tool,
              "kind" => @kimi_kinds[tool],
              "status" => "in_progress",
              "rawInput" => input,
              "content" => text.(args)
            }),
            Map.merge(call, %{
              "sessionUpdate" => "tool_call_update",
              "status" => "completed",
              "content" => text.("export {}"),
              "rawOutput" => "export {}"
            })
          ],
          &%{"update" => &1}
        ) ++ [%{"text" => "Done."}]
    }

    context |> kimi(turn) |> FakeAcp.thread("Agent work")
  end

  @kimi_task "List the modules in lib"

  # Kimi Code's Agent tool: created as "Agent" while its arguments stream in, named by
  # its description once they are whole. The subagent's work goes only to the session's
  # records: the main agent's names it under the call's id (the part of ACP's id after
  # the turn's) and how it ended, its own holds its messages.
  step "Kimi hands a task to one of its subagents", context do
    input = %{"description" => "Survey lib", "prompt" => @kimi_task}
    args = JSON.encode!(input)

    call = fn update, fields ->
      %{
        "update" =>
          Map.merge(
            %{"sessionUpdate" => update, "toolCallId" => "1:functions.Agent:0"},
            fields
          )
      }
    end

    text = &[%{"type" => "content", "content" => %{"type" => "text", "text" => &1}}]
    main = &%{"kimiWire" => %{"agent" => "main", "records" => &1}}
    sub = &%{"kimiWire" => %{"agent" => "sub-a1", "records" => &1}}
    message = &%{"type" => "context.append_message", "message" => &1}

    turn = %{
      "match" => "survey the code",
      "steps" => [
        call.("tool_call", %{
          "title" => "Agent",
          "kind" => "other",
          "status" => "pending",
          "content" => text.(binary_part(args, 0, 10))
        }),
        call.("tool_call_update", %{"status" => "in_progress", "content" => text.(args)}),
        call.("tool_call_update", %{
          "title" => "Survey lib",
          "status" => "in_progress",
          "rawInput" => input,
          "content" => text.(args)
        }),
        main.([
          %{"type" => "turn.started"},
          %{
            "type" => "subagent.spawned",
            "subagentId" => "sub-a1",
            "parentToolCallId" => "functions.Agent:0"
          }
        ]),
        sub.([
          message.(%{"role" => "user", "content" => [%{"type" => "text", "text" => @kimi_task}]}),
          message.(%{
            "role" => "assistant",
            "content" => [%{"type" => "think", "think" => "Look at lib."}],
            # A call in a shape the record does not use is passed over.
            "toolCalls" => [
              %{"id" => "ls", "name" => "Bash", "arguments" => ~s({"command":"ls lib"})},
              %{"id" => "odd", "function" => %{"name" => "Bash"}}
            ]
          }),
          %{"type" => "usage.updated"},
          message.(%{
            "role" => "tool",
            "toolCallId" => "ls",
            "content" => [%{"type" => "text", "text" => "a.ex\nb.ex\n"}]
          }),
          message.(%{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "lib has two modules"}]
          })
        ]),
        main.([
          %{
            "type" => "subagent.completed",
            "subagentId" => "sub-a1",
            "resultSummary" => "lib has two modules"
          }
        ]),
        call.("tool_call_update", %{
          "status" => "completed",
          "content" => text.("Subagent sub-a1 finished.\n\nlib has two modules")
        }),
        %{"text" => "The survey is done."}
      ]
    }

    context |> kimi(turn) |> FakeAcp.thread("Agent work")
  end

  step "Kimi hands a task to a subagent in the background", context do
    input = %{"description" => "Survey lib", "prompt" => @kimi_task, "run_in_background" => true}
    text = &[%{"type" => "content", "content" => %{"type" => "text", "text" => &1}}]

    call = fn fields ->
      %{
        "update" =>
          Map.merge(
            %{"sessionUpdate" => "tool_call_update", "toolCallId" => "1:functions.Agent:0"},
            fields
          )
      }
    end

    spawned = %{
      "type" => "subagent.spawned",
      "subagentId" => "sub-a1",
      "parentToolCallId" => "functions.Agent:0"
    }

    turn = %{
      "match" => "survey the code",
      "steps" => [
        call.(%{"sessionUpdate" => "tool_call", "title" => "Agent", "status" => "pending"}),
        call.(%{"title" => "Survey lib", "status" => "in_progress", "rawInput" => input}),
        %{"kimiWire" => %{"agent" => "main", "records" => [spawned]}},
        call.(%{
          "status" => "completed",
          "content" => text.("Started sub-a1 in the background.")
        }),
        %{"text" => "The survey runs in the background."}
      ]
    }

    context |> kimi(turn) |> FakeAcp.thread("Agent work")
  end

  step "Kimi's turn fails while one of its subagents works", context do
    input = %{"description" => "Survey lib", "prompt" => @kimi_task}

    spawned = %{
      "type" => "subagent.spawned",
      "subagentId" => "sub-a1",
      "parentToolCallId" => "functions.Agent:0"
    }

    turn = %{
      "match" => "survey the code",
      "steps" => [
        %{
          "update" => %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "1:functions.Agent:0",
            "title" => "Survey lib",
            "status" => "in_progress",
            "rawInput" => input
          }
        },
        %{"kimiWire" => %{"agent" => "main", "records" => [spawned]}},
        # Kimi answers the prompt with an error and keeps running.
        %{"error" => %{"code" => -32603, "message" => "The model is overloaded."}}
      ]
    }

    context |> kimi(turn) |> FakeAcp.thread("Agent work")
  end

  step "the turn fails", context do
    if context[:cursor_world] do
      # An ACP provider feature on the AcpFixtures world (Cursor): the run
      # the scenario started has failed.
      assert [%{"status" => "failed"}] =
               HalC2.Test.AcpFixtures.runs(context.threads[context.thread])

      context
    else
      if context[:batch_pending] do
        # An Antigravity batch held by its scenario (features/providers):
        # kill its agent process, so its turn fails around it.
        [{pid, _}] =
          Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, context.thread))

        %{conn: conn} = :sys.get_state(pid)
        if conn, do: Process.exit(conn, :kill)
        Map.put(context, :run_state, FakeAcp.await_run(context, "failed"))
      else
        context = FakeAcp.send_message(context, "survey the code")
        state = FakeAcp.await_run(context, "failed")
        assert [subagent] = StreamState.list(state, "subagent")
        Map.put(context, :subagent, subagent)
      end
    end
  end

  step "the subagent ends with it", context do
    assert context.subagent["status"] == "failed"
    context
  end

  step "the subagent is still running", context do
    assert context.subagent["status"] == "running"
    context
  end

  # Kimi writes the end to the main agent's record, which the MC reads while one runs.
  step "Kimi records that the subagent finished", context do
    [main] =
      Path.wildcard(Path.join(context.fakes["kimi"].dir, "kimi-code/sessions/*/*/agents/main"))

    record = %{
      "type" => "subagent.completed",
      "subagentId" => "sub-a1",
      "resultSummary" => "lib has two modules"
    }

    File.write!(Path.join(main, "wire.jsonl"), JSON.encode!(record) <> "\n", [:append])
    thread_id = World.thread_id(context, context.thread)

    subagent =
      World.await_stream(thread_id, fn state ->
        Enum.find(StreamState.list(state, "subagent"), &(&1["status"] == "completed"))
      end)

    Map.put(context, :subagent, subagent)
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

  step "the subagent's result is the summary Kimi recorded", context do
    assert context.subagent["result"] == "lib has two modules"
    context
  end

  # Kimi Code as a registry instance, running the fake with `turn`, and keeping its
  # session records in the fake's directory.
  defp kimi(context, turn) do
    context = FakeAcp.install(context, "kimi", %{"turns" => [turn | FakeAcp.turns()]})
    World.put_app_env(:acp_commands, %{"kimi" => [context.fakes["kimi"].bin]})
    HalC2.Acp.forget("kimi")
    ExUnit.Callbacks.on_exit(fn -> HalC2.Acp.forget("kimi") end)
    home = Path.join(context.fakes["kimi"].dir, "kimi-code")

    FakeAcp.settings(fn settings ->
      put_in(settings, [Access.key("providerInstances", %{}), "kimi"], %{
        "driver" => "acpRegistry",
        "enabled" => true,
        "config" => %{"agentId" => "kimi"},
        "environment" => [%{"name" => "KIMI_CODE_HOME", "value" => home}]
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

  step ~r/^the timeline shows it as a (?<kind>file read|file search|web search|command|file change)$/,
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

      "file change" ->
        assert item["fileName"] == "notes.md"
        refute Map.has_key?(item, "input")
    end

    context
  end

  # The agent backgrounds a command, then writes a markdown table while the command
  # ticks, finishes, and reports its end again (upstream T3 Code #13386). The chunks
  # carry no message id, as Antigravity's do.
  step "the agent is writing a message", context do
    say = &%{"update" => %{"sessionUpdate" => "agent_message_chunk", "content" => &1}}
    text = &say.(%{"type" => "text", "text" => &1})

    progress =
      &%{
        "update" => %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "background-1",
          "status" => &1,
          "rawOutput" => %{"stdout" => &2}
        }
      }

    started = %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "background-1",
        "title" => "Terminal",
        "kind" => "execute",
        "status" => "in_progress",
        "rawInput" => %{"command" => "sleep 3 && echo done"}
      }
    }

    steps = [
      started,
      text.("| a | b |\n|---|---|\n| 1 "),
      progress.("in_progress", "."),
      text.("| x |\n"),
      progress.("completed", "done"),
      text.("| 2 | y |\n"),
      progress.("completed", "done"),
      text.("| 3 | z |")
    ]

    turn = %{"match" => "write the table", "steps" => steps}

    context
    |> FakeAcp.install("opencode", %{"turns" => [turn | FakeAcp.turns()]}, enabled: true)
    |> FakeAcp.thread("Agent work")
  end

  step "a command it started in the background reports progress in the middle of the message",
       context do
    context = FakeAcp.send_message(context, "write the table")
    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "the message stays one message", context do
    assert [message] =
             Enum.filter(
               StreamState.list(context.run_state, "turn-item"),
               &(&1["type"] == "assistant_message")
             )

    Map.put(context, :message, message)
  end

  step "the text the agent writes after the progress is part of it", context do
    assert context.message["text"] ==
             "| a | b |\n|---|---|\n| 1 | x |\n| 2 | y |\n| 3 | z |"

    assert [command] =
             Enum.filter(
               StreamState.list(context.run_state, "turn-item"),
               &(&1["type"] == "command_execution")
             )

    assert command["status"] == "completed"
    context
  end

  # --- command output -----------------------------------------------------------
  # The fake Codex's "print output N" runs a command that prints N letters, a to z
  # over and over, and holds it open at the gates "printed" and "more". The thread
  # never holds the output: its item carries `outputSize`, and a client that opens the
  # command asks for the output (`orchestration.getCommandOutput`).

  step "the agent's command is still running and printing", context do
    print_output(context, 100_000)
  end

  step "the agent's command prints 17 MB of output", context do
    print_output(context, 17 * 1024 * 1024)
  end

  step "the agent's command has printed more than 64K bytes", context do
    print_output(context, 100_000)
  end

  step("no client has opened the command's details", context, do: context)

  step "a client watching a running command falls more than 16 KB behind", context do
    # A client that did not follow the command's output: it has seen none of it.
    print_output(context, 100_000)
  end

  step "the user opens the command's details", context do
    Map.put(context, :shown, command_output(context))
  end

  step "the output printed so far is shown", context do
    assert %{"running" => true, "output" => output} = context.shown
    # It printed 100,000 bytes; the MC keeps the last 64K.
    assert output == String.slice(printed(100_000), -65_536, 65_536)
    context
  end

  step "new output is added as it is printed, at most every 100 ms", context do
    # What the thread holds of it is its size, so there is nothing to throttle but the
    # client's own refetch; the MC adds each delta to what the next fetch returns.
    context = World.open_gate(context, "printed")
    item = await_command(context, &(&1["outputSize"] == 100_005))
    assert item["output"] == ""
    assert %{"running" => true, "output" => output} = command_output(context)
    assert output == String.slice(printed(100_000) <> "more\n", -65_536, 65_536)
    context
  end

  step "once the command ends the output is replaced by the output the thread kept",
       context do
    context = World.open_gate(context, "more")
    item = await_command(context, &(&1["status"] == "completed"))
    assert item["output"] == "kept output\n"
    assert %{"running" => false, "output" => "kept output\n"} = command_output(context)
    context
  end

  step "the agent ran a command that finished", context do
    title = World.current(context)

    {{:ok, _}, context} =
      World.send_message(
        context,
        title,
        ~s(run command {"command": "ls", "output": "a.txt\\n"})
      )

    await_command(context, &(&1["status"] == "completed"))
    context
  end

  step "the command's final output is shown", context do
    assert %{"running" => false, "output" => "a.txt\n"} = context.shown
    context
  end

  step "no client receives any of that output", context do
    item = await_command(context, &(&1["outputSize"] == 17 * 1024 * 1024))
    assert item["output"] == ""
    # What the thread's clients were sent is a size, not the 17 MB.
    assert Process.get(:sent, 0) < 1_000_000
    context
  end

  step "the thread's history and stream do not grow by it", context do
    thread = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id(context)))
    assert :erlang.external_size(thread) < 1_000_000
    context
  end

  step "the last 64K bytes are shown", context do
    assert %{"running" => true, "output" => output} = context.shown
    assert byte_size(output) == 65_536
    assert output == String.slice(printed(100_000), -65_536, 65_536)
    context
  end

  step "it is sent the whole kept output instead of the missed parts, at most every 500 ms",
       context do
    context = Map.put(context, :shown, command_output(context))
    assert byte_size(context.shown["output"]) == 65_536
    context
  end

  step "what it shows afterwards matches what a client that kept up shows", context do
    # A second connection that has followed the command from the start.
    {kept_up, _} =
      World.call!(
        context,
        "orchestration.getCommandOutput",
        %{"threadId" => thread_id(context), "itemId" => command_item(context)["id"]},
        "kept-up"
      )

    assert kept_up == context.shown
    context
  end

  defp print_output(context, size) do
    title = World.current(context)
    {{:ok, _}, context} = World.send_message(context, title, "print output #{size}")
    Process.put(:sent, 0)
    await_command(context, &(&1["outputSize"] == size))
    context
  end

  # Output of the fake's "print output": the letters a to z over and over.
  defp printed(size) do
    alphabet = String.duplicate("abcdefghijklmnopqrstuvwxyz", div(size, 26) + 1)
    binary_part(alphabet, 0, size)
  end

  defp thread_id(context), do: World.thread_id(context, World.current(context))

  defp command_item(context) do
    thread_id(context)
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.list("turn-item")
    |> Enum.find(&(&1["type"] == "command_execution"))
  end

  defp command_output(context) do
    {output, _} =
      World.call!(context, "orchestration.getCommandOutput", %{
        "threadId" => thread_id(context),
        "itemId" => command_item(context)["id"]
      })

    output
  end

  # Waits for the thread's command to satisfy `pred`; returns it.
  defp await_command(context, pred) do
    id = thread_id(context)

    Enum.reduce_while(Stream.repeatedly(fn -> :tick end), nil, fn _, _ ->
      item = command_item(context)

      cond do
        item && pred.(item) ->
          {:halt, item}

        true ->
          receive do
            {:hal_c2_stream, ^id, event} ->
              Process.put(:sent, Process.get(:sent, 0) + :erlang.external_size(event))
              {:cont, nil}
          after
            10_000 -> flunk("the command stopped at #{inspect(item)}")
          end
      end
    end)
  end

  defp changed_files(diff),
    do: for([_, path] <- Regex.scan(~r/^diff --git a\/(\S+) /m, diff), do: path) |> Enum.sort()
end
