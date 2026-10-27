defmodule HalC2.McpBridgeTest do
  @moduledoc """
  The ACP-facing MCP pieces that need no thread: the stdio bridge's
  ordering, the terminal call, the server forms `AcpServers` builds, and
  the runtime instructions. Behaviour against a real thread is in
  `features/mc/orchestration/mcp-server.feature`.
  """
  use ExUnit.Case, async: false

  alias HalC2.Mcp.{AcpServers, Bridge, BridgeCli, Instructions}

  defp collect_bridge(post) do
    {:ok, lines} = Agent.start_link(fn -> [] end)

    {:ok, bridge} =
      Bridge.start_link(
        endpoint: "http://mc.invalid/mcp",
        authorization: "Bearer test",
        post: post,
        out: fn line -> Agent.update(lines, &[line | &1]) end
      )

    on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)
    {bridge, fn -> Agent.get(lines, &Enum.reverse/1) end}
  end

  test "the bridge replays the session and protocol version the MC gave it" do
    {:ok, seen} = Agent.start_link(fn -> [] end)

    post = fn _e, headers, body, emit ->
      Agent.update(seen, &[headers | &1])
      request = JSON.decode!(body)

      if request["method"] == "initialize" do
        emit.(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{"protocolVersion" => "2025-03-26"}
        })

        {:ok, 200, %{"mcp-session-id" => "s1"}}
      else
        if request["id"], do: emit.(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
        {:ok, 200, %{}}
      end
    end

    {bridge, _lines} = collect_bridge(post)
    Bridge.line(bridge, ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}))
    Bridge.line(bridge, ~s({"jsonrpc":"2.0","id":2,"method":"ping"}))
    Bridge.flush(bridge)

    assert [_, second] = Agent.get(seen, &Enum.reverse/1)
    assert second["mcp-session-id"] == "s1"
    assert second["mcp-protocol-version"] == "2025-03-26"
  end

  test "an unreadable line is a parse error and the bridge keeps going" do
    post = fn _e, _h, body, emit ->
      %{"id" => id} = JSON.decode!(body)
      emit.(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
      {:ok, 200, %{}}
    end

    {bridge, lines} = collect_bridge(post)
    Bridge.line(bridge, "not json")
    Bridge.line(bridge, ~s({"jsonrpc":"2.0","id":7,"method":"ping"}))
    Bridge.flush(bridge)

    assert [error, answer] = lines.()
    assert %{"error" => %{"code" => -32700, "message" => "Parse error"}} = JSON.decode!(error)
    assert %{"id" => 7, "result" => %{}} = JSON.decode!(answer)
  end

  test "a terminal call prints the tool result and nothing without its environment" do
    assert {:error, 2, message} = BridgeCli.command("acp-mcp-call", ["ping", "{}"], %{})
    assert message =~ "HAL_C2_ACP_MCP_ENDPOINT"

    assert {:error, 2, _} =
             BridgeCli.command("acp-mcp-bridge", [], %{
               "HAL_C2_ACP_MCP_ENDPOINT" => "http://x/mcp"
             })

    post = fn _e, _h, body, emit ->
      request = JSON.decode!(body)

      if request["id"] do
        result =
          if request["method"] == "initialize",
            do: %{"protocolVersion" => "2025-06-18"},
            else: %{"content" => [], "structuredContent" => %{"ok" => true}}

        emit.(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      end

      {:ok, 200, %{}}
    end

    assert {:ok, %{"structuredContent" => %{"ok" => true}}} =
             Bridge.call_tool("http://mc.invalid/mcp", "Bearer t", "some_tool", %{}, post)
  end

  test "the server forms an ACP agent is given" do
    server = %{url: "http://127.0.0.1:9/mcp", authorization: "Bearer sekrit"}

    http = AcpServers.build(%{"mcpCapabilities" => %{"http" => true, "acp" => true}}, server)

    assert [
             %{"type" => "http", "url" => "http://127.0.0.1:9/mcp"},
             %{"type" => "acp", "serverId" => "hal-c2"}
           ] = http.servers

    env = Map.new(http.env)
    assert env["HAL_C2_ACP_MCP_AUTHORIZATION"] == "Bearer sekrit"
    assert env["HAL_C2_ACP_MCP_NODE"] != ""

    stdio = AcpServers.build(%{"mcpCapabilities" => %{}}, server)
    assert [only] = stdio.servers
    assert "acp-mcp-bridge" in only["args"]
    refute Enum.join([only["command"] | only["args"]], " ") =~ "sekrit"

    assert Enum.any?(
             only["env"],
             &(&1["name"] == "HAL_C2_ACP_MCP_AUTHORIZATION" and &1["value"] == "Bearer sekrit")
           )

    assert AcpServers.build(%{}, nil) == %{servers: [], env: []}
  end

  test "runtime instructions name the harness, model and effort, and omit an automatic model" do
    text = Instructions.runtime(%{harness: "Claude Code", model: "Opus", effort: "high"})
    assert text =~ "through the Claude Code harness, as Opus with high reasoning effort"
    assert text =~ "No need to mention this otherwise"
    assert text =~ "embed images and videos"
    assert text =~ "link_pull_request"

    auto = Instructions.runtime(%{harness: "Cursor", model: "auto"})
    assert auto =~ "through the Cursor harness."
    refute auto =~ "as auto"
  end

  test "ACP prompts carry instructions only when they change, never before a slash command" do
    state = %{interaction_mode: "default", has_mcp: true, capabilities: MapSet.new(["preview"])}
    first = Instructions.acp_prompt("hello", state, nil)
    assert first =~ "HAL-C2 orchestration"
    assert Instructions.acp_prompt("again", state, state) == "again"

    plan = %{state | interaction_mode: "plan"}
    assert Instructions.acp_prompt("plan it", plan, state) =~ "interaction mode: Plan"
    assert Instructions.acp_prompt("/compact", state, nil) == "/compact"
  end

  test "first-run and system-prompt delivery" do
    assert Instructions.first_run_prompt("hi", 1, true) =~ "<user_request>\nhi\n</user_request>"
    assert Instructions.first_run_prompt("hi", 2, true) == "hi"
    assert Instructions.first_run_prompt("hi", 1, false) == "hi"
    assert Instructions.system_prompt(true) == Instructions.orchestration()
    assert Instructions.system_prompt(false) == nil
  end
end
