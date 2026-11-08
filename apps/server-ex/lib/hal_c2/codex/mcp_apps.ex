defmodule HalC2.Codex.McpApps do
  @moduledoc """
  Codex's side of MCP Apps (`HalC2.McpApps`). Codex names an app on the `mcpToolCall`
  item, and the app reaches its server through Codex's own MCP client, so any server
  the user configured for Codex works without the MC connecting to it.
  """

  alias HalC2.JsonRpc.Connection

  # Reading an app's resource is one MCP round trip; a server that hangs must not
  # hold the item, and the turn after it, open.
  @capture_timeout 20_000
  @request_timeout 60_000

  @doc "The UI resource a Codex MCP tool call names, under any field Codex reports it in."
  def resource_uri(%{"type" => "mcpToolCall"} = item) do
    uri =
      get_in(item, ["mcpAppUi", "resourceUri"]) || item["mcpAppResourceUri"] ||
        get_in(item, ["appContext", "resourceUri"])

    if HalC2.McpApps.resource_uri?(uri), do: uri
  end

  def resource_uri(_item), do: nil

  @doc """
  The `"mcpApp"` field for a completed tool item: the app's document read through
  `conn` and stored for `thread_id`. A call that returned a result is captured even
  when the tool marked it an error (the app shows the failure); a call that failed
  before returning one, a read that fails and a document too big leave a plain tool row.
  """
  def capture(conn, native_thread_id, thread_id, item) do
    with uri when is_binary(uri) <- resource_uri(item),
         true <- conn != nil and is_binary(native_thread_id),
         true <- item["result"] != nil and item["error"] == nil,
         {:ok, %{"contents" => contents}} <-
           safe_call(
             conn,
             "mcpServer/resource/read",
             %{"threadId" => native_thread_id, "server" => item["server"], "uri" => uri},
             @capture_timeout
           ),
         %{} = app <-
           HalC2.McpApps.snapshot(thread_id, item["server"], item["tool"], uri, contents) do
      %{"mcpApp" => Map.put(app, "toolResult", item["result"])}
    else
      _ -> %{}
    end
  end

  # --- `HalC2.McpApps` adapter ---------------------------------------------------

  @doc """
  The thread's app context (`HalC2.McpApps.model_context/1`) as `turn/start`
  `additionalContext` entries. Codex cuts the middle out of a longer value
  (`HalC2.Mcp.Instructions.codex_entry_bytes/0`), so an app's context goes in as
  many entries as it needs, `KEY_01`, `KEY_02`, ..., which Codex sends in that order.
  """
  def context_entries(thread_id) do
    for {key, text} <- HalC2.McpApps.model_context(thread_id),
        {part, n} <- Enum.with_index(parts(text, HalC2.Mcp.Instructions.codex_entry_bytes()), 1),
        into: %{} do
      {key <> "_" <> String.pad_leading("#{n}", 2, "0"),
       %{"kind" => "untrusted", "value" => part}}
    end
  end

  # `text` in pieces of at most `bytes`, each whole UTF-8.
  defp parts(text, bytes) when byte_size(text) <= bytes, do: [text]

  defp parts(text, bytes) do
    part = HalC2.McpApps.cut(text, bytes)
    [part | parts(binary_part(text, byte_size(part), byte_size(text) - byte_size(part)), bytes)]
  end

  @doc "The thread's live Codex connection and native thread, or `:stopped`; never starts one."
  def session(thread_id) do
    case HalC2.Codex.ThreadRuntime.mcp_session(thread_id) do
      {conn, native} when conn != nil and is_binary(native) -> {:ok, {conn, native}}
      _ -> :stopped
    end
  end

  def list_tools({conn, native}, server) do
    with {:ok, %{"data" => data}} when is_list(data) <-
           safe_call(conn, "mcpServerStatus/list", %{
             "threadId" => native,
             "serverName" => server,
             "detail" => "toolsAndAuthOnly"
           }) do
      tools =
        case Enum.find(data, &(is_map(&1) and &1["name"] == server)) do
          %{"tools" => %{} = tools} -> Map.values(tools)
          %{"tools" => tools} when is_list(tools) -> tools
          _ -> []
        end

      {:ok, tools}
    else
      {:error, _} = error -> error
      _ -> {:error, :unexpected}
    end
  end

  def call_tool({conn, native}, server, tool, arguments) do
    safe_call(conn, "mcpServer/tool/call", %{
      "threadId" => native,
      "server" => server,
      "tool" => tool,
      "arguments" => arguments
    })
  end

  def read_resource({conn, native}, server, uri) do
    safe_call(conn, "mcpServer/resource/read", %{
      "threadId" => native,
      "server" => server,
      "uri" => uri
    })
  end

  # A connection that closes or stalls mid-call fails the request, not the caller.
  defp safe_call(conn, method, params, timeout \\ @request_timeout) do
    Connection.call(conn, method, params, timeout)
  catch
    :exit, reason -> {:error, reason}
  end
end
