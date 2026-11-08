defmodule HalC2.CodexMcpAppReadTest do
  # An MCP app's document is read from its server off the thread's Codex runtime:
  # a server slow to answer holds nothing else of the turn.
  use ExUnit.Case, async: false

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @thread "Forecast"

  # Regression: the read ran inside the runtime, so a Stop waited for a hung
  # server's 20 s read to give up, past the Stop's own budget.
  test "a Stop is answered while the server of an MCP app has not answered its read",
       %{tmp_dir: dir} do
    context =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> then(&World.put_client(&1, World.client(&1)))
      |> World.fake_providers()
      # The fake leaves a turn that says "wait" open: the test plays Codex's side.
      |> World.launch_on(@thread, "codex", "wait for the forecast")

    run = World.await_running(context, @thread)
    {_pid, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "item" => %{
        "type" => "mcpToolCall",
        "id" => "mcp-slow",
        "server" => "weather",
        "tool" => "get_forecast",
        "arguments" => %{},
        "status" => "completed",
        "result" => %{"content" => [%{"type" => "text", "text" => "Sunny"}]},
        "error" => nil,
        "mcpAppResourceUri" => "ui://weather/slow.html"
      }
    })

    # The Stop rides behind the item's completion in the runtime's mailbox.
    assert :ok = HalC2.Codex.ThreadRuntime.interrupt(World.thread_id(context, @thread), run["id"])
    World.await_runs(context, @thread, ["interrupted"])

    # The tool call finished as a plain row: its app never arrived.
    item =
      World.await_value(context, @thread, fn state ->
        Enum.find(
          HalC2.StreamState.list(state, "turn-item"),
          &(&1["status"] == "completed" and &1["nativeItemRef"]["nativeId"] == "mcp-slow")
        )
      end)

    refute Map.has_key?(item, "mcpApp")
  end
end
