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

  defp running_thread(dir) do
    context =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> then(&World.put_client(&1, World.client(&1)))
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "wait for the forecast")

    World.await_running(context, @thread)
    context
  end

  defp app_item(id) do
    %{
      "type" => "mcpToolCall",
      "id" => id,
      "server" => "weather",
      "tool" => "get_forecast",
      "arguments" => %{},
      "status" => "completed",
      "result" => %{"content" => [%{"type" => "text", "text" => "Sunny"}]},
      "error" => nil,
      "mcpAppResourceUri" => "ui://weather/forecast.html"
    }
  end

  defp documents do
    dir = HalC2.Attachments.dir()

    if File.dir?(dir),
      do: Enum.filter(File.ls!(dir), &String.contains?(&1, "-mcp-app-")),
      else: []
  end

  # Regression: the session of the instance now running the thread answered for an
  # app an earlier instance made, so the app read and called with the new account.
  @tag :tmp_dir
  test "an app is served only by the session of the instance that made it", %{tmp_dir: dir} do
    context = running_thread(dir)
    id = World.thread_id(context, @thread)

    assert {:ok, {_conn, _native}} = HalC2.Codex.McpApps.session(id, "codex")
    assert {:ok, {_conn, _native}} = HalC2.Codex.McpApps.session(id)
    assert :stopped = HalC2.Codex.McpApps.session(id, "codex-work")
  end

  # Regression: a read that returned after the thread was deleted still published its
  # document, which nothing then cleaned up.
  @tag :tmp_dir
  test "a document read after the thread was deleted is not kept", %{tmp_dir: dir} do
    context = running_thread(dir)
    id = World.thread_id(context, @thread)
    {_pid, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "item/completed", %{
      "threadId" => runtime.native_thread_id,
      "turnId" => runtime.turn.native_turn_id,
      "item" => app_item("mcp-live")
    })

    item =
      World.await_value(context, @thread, fn state ->
        Enum.find(HalC2.StreamState.list(state, "turn-item"), &Map.has_key?(&1, "mcpApp"))
      end)

    assert [_] = documents()

    thread = HalC2.StreamState.get(HalC2.Streams.state(id), "thread")[id]

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"thread", id,
         HalC2.Patch.diff(
           thread,
           Map.put(thread, "deletedAt", HalC2.Orchestration.Entities.now())
         )}
      ])

    assert :ok =
             HalC2.Codex.McpApps.attach(
               runtime.conn,
               runtime.native_thread_id,
               id,
               item["id"],
               app_item("mcp-live")
             )

    # The deleted thread's item kept the document it had; the late one left no file.
    assert documents() == [Path.basename(item["mcpApp"]["attachmentId"]) <> ".html"]
  end
end
