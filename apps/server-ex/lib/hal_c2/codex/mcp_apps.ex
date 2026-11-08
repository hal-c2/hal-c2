defmodule HalC2.Codex.McpApps do
  @moduledoc """
  Codex's side of MCP Apps (`HalC2.McpApps`). Codex names an app on the `mcpToolCall`
  item, and the app reaches its server through Codex's own MCP client, so any server
  the user configured for Codex works without the MC connecting to it.
  """

  alias HalC2.JsonRpc.Connection
  alias HalC2.Orchestration
  alias HalC2.Orchestration.Entities
  alias HalC2.StreamState

  # Reading an app's resource is one MCP round trip; a server that hangs gives up
  # its app after this long and leaves a plain tool row.
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

  @doc """
  Puts the app `capture/4` reads for a completed tool item onto that item,
  `item_id` in `thread_id`'s stream, once the read returns: `:ok` either way.
  ThreadRuntime runs it in a process of its own, as the read may take its server's time.
  The stored document stays only when it is published on a live thread's item: one
  deleted (or whose item went) while the server answered would otherwise keep a file
  nothing owns or cleans up.
  """
  def attach(conn, native_thread_id, thread_id, item_id, item) do
    with %{"mcpApp" => _} = fields <- capture(conn, native_thread_id, thread_id, item) do
      publish(thread_id, item_id, fields)
    end

    :ok
  end

  @doc """
  Puts `capture/4`'s `fields` (a stored document) on `item_id` of a live `thread_id`.
  The document is removed when it cannot be, so none outlives what owns it. Decided
  inside the stream's transaction, so it is ordered against the thread's deletion.
  """
  def publish(thread_id, item_id, %{"mcpApp" => %{"attachmentId" => id}} = fields) do
    published? = put_on_item(thread_id, item_id, fields)
    if not published?, do: remove_document(id)
    published?
  end

  defp put_on_item(thread_id, item_id, fields) do
    HalC2.Streams.transact(thread_id, :thread, fn stream ->
      live? = get_in(StreamState.get(stream, "thread"), [thread_id, "deletedAt"]) == nil

      update = fn
        nil -> nil
        current -> current |> Map.merge(fields) |> Map.put("updatedAt", Entities.now())
      end

      change = live? && Orchestration.upsert(stream, "turn-item", item_id, update)
      {Enum.reject([change], &(&1 in [nil, false])), change != nil and change != false}
    end)
  catch
    # The thread went away while its server answered: there is no item to put it on.
    :exit, _ -> false
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_document(id), do: File.rm(HalC2.Attachments.path(%{"id" => id}))

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

  @doc """
  The thread's live Codex connection and native thread, or `:stopped`; never starts one.
  `instance` is the provider instance the app was made on (nil: the default one): a
  connection open for another instance of Codex is not that app's session.
  """
  def session(thread_id, instance \\ nil) do
    made_on = instance || "codex"

    case HalC2.Codex.ThreadRuntime.mcp_session(thread_id) do
      {conn, native, open_for}
      when conn != nil and is_binary(native) and open_for in [made_on, :unknown] ->
        {:ok, {conn, native}}

      _ ->
        :stopped
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
