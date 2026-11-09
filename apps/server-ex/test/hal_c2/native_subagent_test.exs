defmodule HalC2.Orchestration.NativeSubagentTest do
  # The stream-level settle for an end no runtime reports (a deleted thread):
  # the still-running work in its provider subagents' child threads ends too. And
  # what plugins that hear turns hear of a subagent's work as it ends.
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.NativeSubagent
  alias HalC2.StreamState

  @moduletag :tmp_dir
  @at "2026-09-23T10:00:00.000Z"

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    :ok
  end

  test "a tool call still running when its subagent ends is heard once, ended, as the parent turn's" do
    start_supervised!({Registry, keys: :unique, name: HalC2.Plugins.Hooks})

    {:ok, _} =
      Registry.register(HalC2.Plugins.Hooks, {:observe, "listener"}, %{
        id: "listener",
        dropped: :counters.new(1, [])
      })

    {:ok, _} = HalC2.Streams.commit("p", :thread, [{"thread", "p", %{"s" => %{"id" => "p"}}}])

    ids = %{
      thread: "p",
      run: "r1",
      root_node: "node:root:r1",
      provider_thread: "pt",
      driver: "claudeAgent"
    }

    sub = NativeSubagent.start(ids, "agent-1", %{"prompt" => "Schedule it"})
    assert_received {:observe, %{"itemType" => "subagent"}}

    sub =
      NativeSubagent.item(sub, "tool-1", "dynamic_tool", "running", %{
        "providerToolName" => "CronCreate"
      })

    refute_received {:observe, %{"tool" => "CronCreate"}}

    NativeSubagent.finish(sub, "interrupted", nil)

    assert_received {:observe,
                     %{
                       "type" => "turn.item",
                       "tool" => "CronCreate",
                       "status" => "interrupted",
                       "threadId" => "p",
                       "runId" => "r1",
                       "subagent" => true
                     }}

    refute_received {:observe, %{"tool" => "CronCreate"}}
  end

  test "settle_children ends a child thread's running work and leaves finished work" do
    {:ok, _} =
      HalC2.Streams.commit("p", :thread, [
        {"thread", "p", %{"s" => %{"id" => "p", "title" => "p"}}},
        {"subagent", "sub",
         %{
           "s" => %{
             "id" => "sub",
             "origin" => "provider_native",
             "childThreadId" => "c",
             "status" => "cancelled"
           }
         }},
        {"subagent", "task",
         %{
           "s" => %{
             "id" => "task",
             "origin" => "app_owned",
             "childThreadId" => "other",
             "status" => "running"
           }
         }}
      ])

    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [
        {"thread", "c", %{"s" => %{"id" => "c", "title" => "c"}}},
        {"turn-item", "turn-item:codex:cmd-1",
         %{
           "s" => %{
             "id" => "turn-item:codex:cmd-1",
             "type" => "command_execution",
             "status" => "running",
             "streaming" => true,
             "createdAt" => @at
           }
         }},
        {"turn-item", "turn-item:codex:done-1",
         %{
           "s" => %{
             "id" => "turn-item:codex:done-1",
             "type" => "command_execution",
             "status" => "completed",
             "createdAt" => @at
           }
         }}
      ])

    assert :ok = NativeSubagent.settle_children("p", "cancelled")

    items =
      "c"
      |> HalC2.Streams.ensure()
      |> HalC2.Streams.Server.state()
      |> StreamState.get("turn-item")

    assert items["turn-item:codex:cmd-1"]["status"] == "cancelled"
    assert items["turn-item:codex:cmd-1"]["streaming"] == false
    assert items["turn-item:codex:done-1"]["status"] == "completed"
  end
end
