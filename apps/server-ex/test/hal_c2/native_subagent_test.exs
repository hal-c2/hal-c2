defmodule HalC2.Orchestration.NativeSubagentTest do
  # The stream-level settle for an end no runtime reports (a deleted thread):
  # the still-running work in its provider subagents' child threads ends too.
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.{NativeSubagent, TurnWriter}
  alias HalC2.StreamState

  @moduletag :tmp_dir
  @at "2026-09-23T10:00:00.000Z"

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    :ok
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

  # Review of #1398: a runtime that went leaves a try at its run's end to end the work it
  # kept running, of its run and its instance's earlier runs (`TurnWriter.abandon/5`'s
  # `lost:`). Before that try, the next run's runtime resumed a subagent an earlier
  # run started (Claude's SendMessage), and the try ended it under that runtime.
  test "a lost runtime's end leaves the subagent a later run resumed running" do
    resumed_subagent(%{1 => "completed", 2 => "failed", 3 => "running"}, "run-1", "run-3")

    # The lost runtime drove run 2, whose end already recorded.
    assert :ok = TurnWriter.abandon("p", "run-2", "failed", "gone", lost: true)

    assert_running("run-1")
  end

  # Review of #1398: the try of the run that started the subagent took it by the run it
  # was recorded under, as did the work its runtime had ended, which an end the store
  # refused keeps for the tries after it (`TurnWatch.ending/2`).
  for ended? <- [false, true] do
    test "the lost end of the run that started a subagent leaves it to the run that resumed it (ended: #{ended?})" do
      resumed_subagent(%{1 => "failed", 2 => "running"}, "run-1", "run-2")
      ended = if unquote(ended?), do: [ended: NativeSubagent.keys("sub")], else: []

      assert :ok = TurnWriter.abandon("p", "run-1", "failed", "gone", [lost: true] ++ ended)

      assert_running("run-1")
    end
  end

  # And an end of the run that resumed it ends it as that run's, whatever run started it.
  test "the end of the run that resumed a subagent ends it" do
    resumed_subagent(%{1 => "failed", 2 => "running"}, "run-1", "run-2")

    assert :ok = TurnWriter.abandon("p", "run-2", "failed", "gone")

    parent = HalC2.Streams.state("p")
    assert %{"status" => "failed"} = StreamState.get(parent, "subagent")["sub"]
    assert %{"status" => "failed"} = StreamState.get(parent, "node")["sub"]

    assert %{"status" => "failed"} =
             StreamState.get(parent, "turn-item")["turn-item:subagent:sub"]

    assert %{"status" => "failed"} =
             StreamState.get(HalC2.Streams.state("c"), "turn-item")["turn-item:claudeAgent:cmd-1"]
  end

  # Thread "p" with runs of `statuses` by ordinal, and a provider subagent run `origin`
  # started and ended, which run `resumer` resumed: it runs a command in its thread "c".
  defp resumed_subagent(statuses, origin, resumer) do
    run = fn ordinal, status ->
      id = "run-#{ordinal}"

      {"run", id,
       %{
         "s" => %{
           "id" => id,
           "threadId" => "p",
           "status" => status,
           "ordinal" => ordinal,
           "providerInstanceId" => "claudeAgent",
           "rootNodeId" => "node-root-#{ordinal}"
         }
       }}
    end

    done = %{"runId" => origin, "status" => "completed", "completedAt" => @at}

    {:ok, _} =
      HalC2.Streams.commit(
        "p",
        :thread,
        [{"thread", "p", %{"s" => %{"id" => "p", "title" => "p"}}}] ++
          Enum.map(statuses, fn {ordinal, status} -> run.(ordinal, status) end) ++
          [
            {"subagent", "sub",
             %{
               "s" =>
                 Map.merge(done, %{
                   "id" => "sub",
                   "threadId" => "p",
                   "origin" => "provider_native",
                   "childThreadId" => "c",
                   "nativeTaskRef" => %{"nativeId" => "task-1"}
                 })
             }},
            {"node", "sub", %{"s" => Map.put(done, "id", "sub")}},
            {"turn-item", "turn-item:subagent:sub",
             %{
               "s" =>
                 Map.merge(done, %{
                   "id" => "turn-item:subagent:sub",
                   "type" => "subagent",
                   "nodeId" => "sub"
                 })
             }}
          ]
      )

    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [
        {"thread", "c", %{"s" => %{"id" => "c", "title" => "c"}}}
      ])

    entity = StreamState.get(HalC2.Streams.state("p"), "subagent")["sub"]
    ids = %{thread: "p", run: resumer, driver: "claudeAgent", instance: "claudeAgent"}
    NativeSubagent.resume(ids, entity, "go on")

    command = %{
      "id" => "turn-item:claudeAgent:cmd-1",
      "type" => "command_execution",
      "status" => "running",
      "createdAt" => @at
    }

    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [{"turn-item", command["id"], %{"s" => command}}])
  end

  # The subagent, its node and item, and the command in its thread all still run.
  defp assert_running(origin) do
    parent = HalC2.Streams.state("p")

    assert %{"status" => "running", "runId" => ^origin} =
             StreamState.get(parent, "subagent")["sub"]

    assert %{"status" => "running"} = StreamState.get(parent, "node")["sub"]

    assert %{"status" => "running"} =
             StreamState.get(parent, "turn-item")["turn-item:subagent:sub"]

    assert %{"status" => "running"} =
             StreamState.get(HalC2.Streams.state("c"), "turn-item")["turn-item:claudeAgent:cmd-1"]
  end
end
