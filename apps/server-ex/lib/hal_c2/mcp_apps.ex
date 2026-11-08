defmodule HalC2.McpApps do
  @moduledoc """
  MCP Apps (https://github.com/modelcontextprotocol/ext-apps, spec 2026-01-26): an MCP
  tool can name a `ui://` HTML resource that a host renders as an interactive view of
  its result. Provider-neutral; a provider adapter recognises the app in its own tool
  calls and answers its requests (`HalC2.Codex.McpApps`).

  When the tool call completes, the adapter reads the resource and `snapshot/5` stores
  it as one of the thread's attachments, with the app's Content-Security-Policy at the
  top, so `HalC2.Attachments.delete_thread/1` removes it with the thread. The tool's
  turn item records the reference in `"mcpApp"`; clients fetch the document through
  `assets.createUrl` with `renderIntent: "mcp-app"` (`serve_document/1`) and host it.

  The app's requests (`mcpApps.*`) name the tool call that made it, so an app reaches
  only its own server, and run through the thread's live provider session. A stopped
  session is reported, never started: an app must not spend a provider turn. A tool
  that is not read only runs only once the user approved the call. What an app tells
  the model (`mcpApps.updateModelContext`) is an `mcp-app-context` entity per app,
  sent with every later turn; a fork copies it and a rollback of the app's run drops it.
  """

  alias HalC2.{Patch, StreamState}

  @mime "text/html;profile=mcp-app"
  @scheme "ui://"
  # Largest app document stored, and what an app may tell the model.
  @max_html 5 * 1024 * 1024
  @max_context 16 * 1024
  @max_domains 32
  @domain ~r/^(?:https?|wss?):\/\/(?:\*\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*(?::\d{1,5})?$/i
  @permissions ~w(camera microphone geolocation clipboardWrite)

  @doc "The MCP client extension a provider declares to be given UI resources."
  def client_extensions, do: %{"io.modelcontextprotocol/ui" => %{"mimeTypes" => [@mime]}}

  @doc "Whether `uri` names an app's UI resource."
  def resource_uri?(uri), do: is_binary(uri) and String.starts_with?(uri, @scheme)

  @doc "How much an app may tell the model, in bytes."
  def max_context_bytes, do: @max_context

  # --- the document ----------------------------------------------------------------

  @doc """
  Stores the app document in `contents` (a `resources/read` result's) for the thread
  and returns the reference its tool item carries, or nil when the contents hold no
  app document or one over #{div(@max_html, 1024 * 1024)} MiB.
  """
  # The file is named by the thread's sanitised segment and a random tag, in the
  # attachments directory.
  # sobelow_skip ["Traversal.FileModule"]
  def snapshot(thread_id, server, tool, uri, contents) do
    with true <- resource_uri?(uri),
         {html, ui} when is_binary(html) <- document(List.wrap(contents), uri),
         id = HalC2.Attachments.thread_segment(thread_id) <> "-mcp-app-" <> tag(),
         path = Path.join(HalC2.Attachments.dir(), id <> ".html"),
         csp = csp(ui["csp"]),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write(path, inject_csp(html, csp)) do
      %{"attachmentId" => id, "server" => server, "tool" => tool, "resourceUri" => uri}
      |> put_present("csp", csp)
      |> put_present("permissions", permissions(ui["permissions"]))
      |> then(
        &if(is_boolean(ui["prefersBorder"]),
          do: Map.put(&1, "prefersBorder", ui["prefersBorder"]),
          else: &1
        )
      )
    else
      _ -> nil
    end
  end

  # A write cut short leaves no half document behind. `path` is `snapshot/5`'s.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(path, html) do
    with {:error, _} = error <- File.write(path, html) do
      File.rm(path)
      error
    end
  end

  # The first `text/html;profile=mcp-app` content for `uri`; a blob is base64 per MCP.
  defp document(contents, uri) do
    Enum.find_value(contents, fn
      %{} = content ->
        with true <- content["uri"] in [nil, uri],
             true <- mime?(content["mimeType"]),
             html when is_binary(html) <- html(content),
             true <- byte_size(html) <= @max_html and String.trim(html) != "" do
          ui = get_in(content, ["_meta", "ui"])
          {html, if(is_map(ui), do: ui, else: %{})}
        else
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp mime?(mime),
    do: is_binary(mime) and String.downcase(String.replace(mime, ~r/\s+/, "")) == @mime

  defp html(%{"text" => text}) when is_binary(text), do: text

  defp html(%{"blob" => blob})
       when is_binary(blob) and byte_size(blob) <= div(@max_html, 3) * 4 + 4 do
    case Base.decode64(blob, ignore: :whitespace) do
      {:ok, html} -> if String.valid?(html), do: html
      :error -> nil
    end
  end

  defp html(_content), do: nil

  # Only scheme-qualified origins (optionally `*.`-wildcarded) survive: anything else
  # could widen or break the policy built from them.
  defp csp(%{} = declared) do
    for key <- ~w(connectDomains resourceDomains frameDomains baseUriDomains),
        domains = domains(declared[key]),
        domains != [],
        into: %{},
        do: {key, domains}
  end

  defp csp(_declared), do: %{}

  defp domains(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 256 and Regex.match?(@domain, &1)))
    |> Enum.take(@max_domains)
  end

  defp domains(_list), do: []

  defp permissions(%{} = declared),
    do: for(key <- @permissions, is_map(declared[key]), into: %{}, do: {key, %{}})

  defp permissions(_declared), do: %{}

  @doc """
  The Content-Security-Policy for an app document: undeclared origins stay blocked,
  and nothing loads from the MC's own origin.
  """
  def policy(csp) do
    resources = Enum.join(csp["resourceDomains"] || [], " ")
    list = fn key -> Enum.join(csp[key] || ["'none'"], " ") end

    Enum.join(
      [
        "default-src 'none'",
        String.trim("script-src 'unsafe-inline' " <> resources),
        String.trim("style-src 'unsafe-inline' " <> resources),
        String.trim("img-src data: blob: " <> resources),
        String.trim("font-src data: " <> resources),
        String.trim("media-src data: blob: " <> resources),
        "connect-src " <> list.("connectDomains"),
        "frame-src " <> list.("frameDomains"),
        "object-src 'none'",
        "base-uri " <> list.("baseUriDomains"),
        "form-action 'none'"
      ],
      "; "
    )
  end

  # The policy as a meta tag, after a leading doctype (the document stays in standards
  # mode), ahead of every script.
  defp inject_csp(html, csp) do
    content =
      csp
      |> policy()
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")

    meta = ~s(<meta http-equiv="Content-Security-Policy" content="#{content}">)

    case Regex.run(~r/^\x{FEFF}?\s*<!doctype[^>]*>/iu, html) do
      [doctype] ->
        doctype <>
          meta <> binary_part(html, byte_size(doctype), byte_size(html) - byte_size(doctype))

      nil ->
        "<!doctype html>" <> meta <> html
    end
  end

  # Installed ahead of the app's own scripts when the document is served, so documents
  # stored before them get them too. The theme script gives an app that ignores the
  # host's theme the host's light or dark canvas; the frame's origin is opaque, so
  # messages are trusted by their sender, the parent window. In that sandbox reading
  # `document.cookie` throws, which stopped some apps starting: the cookie script makes
  # it read empty and drop writes.
  @theme_bootstrap ~s"""
  <script>(()=>{window.addEventListener("message",(event)=>{if(event.source!==window.parent)return;const m=event.data;if(!m||m.jsonrpc!=="2.0")return;const theme=m.method==="ui/notifications/host-context-changed"?m.params?.theme:m.id!==undefined&&m.method===undefined?m.result?.hostContext?.theme:undefined;if(theme==="light"||theme==="dark"){document.documentElement.style.colorScheme=theme;}});})();</script>
  """
  @cookie_bootstrap ~s"""
  <script>(function(){try{void document.cookie;}catch(error){if(error&&error.name==="SecurityError"){Object.defineProperty(document,"cookie",{configurable:true,get:function(){return "";},set:function(){}});}}})();</script>
  """

  @doc """
  An app document as it is served: the theme and cookie bootstraps go in after the
  doctype and the stored CSP meta tag, so the policy still comes first.
  """
  def serve_document(html) do
    scripts = String.trim(@theme_bootstrap) <> String.trim(@cookie_bootstrap)

    prefix =
      case Regex.run(
             ~r/^(?:\x{FEFF}?\s*<!doctype[^>]*>\s*)?(?:<meta http-equiv="Content-Security-Policy" content="[^"]*">)?/iu,
             html
           ) do
        [prefix] -> prefix
        nil -> ""
      end

    rest = binary_part(html, byte_size(prefix), byte_size(html) - byte_size(prefix))
    if prefix == "", do: "<!doctype html>" <> scripts <> rest, else: prefix <> scripts <> rest
  end

  @doc """
  The headers an app document is served with: its own sandbox, so its scripts run in
  an opaque origin that cannot reach the MC or the client's storage.
  """
  def serve_headers,
    do: [
      {"content-security-policy",
       "sandbox allow-scripts allow-forms allow-popups allow-downloads"}
    ]

  @doc "The largest stored app document served: the cap plus room for its policy."
  def max_document_bytes, do: @max_html + 128 * 1024

  @doc "Whether an attachment id names an app document `snapshot/5` stored."
  def document_id?(id), do: is_binary(id) and String.contains?(id, "-mcp-app-")

  # --- the app's requests ------------------------------------------------------------

  @doc "`mcpApps.toolInfo`: whether the app may call a tool, and whether it only reads."
  def tool_info(%{"name" => name} = input) do
    with {:ok, app, adapter, session} <- resolve(input),
         {:ok, tool} <- find_tool(input, adapter, session, app, name) do
      %{
        "callable" => tool != nil and callable?(tool),
        "readOnly" => tool != nil and read_only?(tool)
      }
      |> put_present("title", tool && get_in(tool, ["annotations", "title"]))
      |> then(&if(tool, do: Map.put(&1, "tool", tool), else: &1))
      |> then(&{:ok, &1})
    end
  end

  @doc """
  `mcpApps.callTool`: calls a tool on the app's server. A tool hidden from apps is
  refused, and one that is not read only needs `approved: true`, which a client sends
  once its user approved this call.
  """
  def call_tool(%{"name" => name} = input) do
    with {:ok, app, adapter, session} <- resolve(input),
         {:ok, tool} <- find_tool(input, adapter, session, app, name),
         :ok <-
           if(tool != nil and callable?(tool), do: :ok, else: error(input, "tool-not-callable")),
         :ok <-
           if(read_only?(tool) or input["approved"] == true,
             do: :ok,
             else: error(input, "approval-required")
           ) do
      case adapter.call_tool(session, app["server"], name, input["arguments"] || %{}) do
        {:ok, result} -> {:ok, call_result(result)}
        {:error, _} -> error(input, "request-failed")
      end
    end
  end

  @doc "`mcpApps.readResource`: reads a resource from the app's server."
  def read_resource(%{"uri" => uri} = input) do
    with {:ok, app, adapter, session} <- resolve(input) do
      case adapter.read_resource(session, app["server"], uri) do
        {:ok, %{"contents" => contents}} when is_list(contents) ->
          {:ok, %{"contents" => contents}}

        _ ->
          error(input, "request-failed")
      end
    end
  end

  @doc """
  `mcpApps.updateModelContext`: what the app wants the model to know, sent with the
  thread's later turns. Each update replaces the app's last; none clears it. Text
  blocks are kept as written and structured content as JSON, cut to
  #{div(@max_context, 1024)} KiB. Needs the app, not a live session.
  """
  def update_model_context(%{"threadId" => thread_id, "itemId" => item_id} = input) do
    # The thread on screen: the app's own, or a fork, which holds its own copy of the item.
    thread_id = input["conversationThreadId"] || thread_id

    # The thread's own stream, not the shell, whose row trails it by a debounce.
    with {:ok, text} <- context_text(input) do
      HalC2.Streams.transact(thread_id, :thread, fn state ->
        case thread?(state, thread_id) && StreamState.get(state, "turn-item")[item_id] do
          %{"mcpApp" => %{}} = item ->
            {Enum.reject([context_change(state, item, cut(text))], &is_nil/1), {:ok, nil}}

          _ ->
            {[], error(input, "not-an-app")}
        end
      end)
    end
  end

  defp context_text(input) do
    blocks = List.wrap(input["content"])

    if Enum.all?(blocks, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)) do
      texts = Enum.map(blocks, & &1["text"])

      texts =
        if input["structuredContent"] != nil,
          do: texts ++ [JSON.encode!(input["structuredContent"])],
          else: texts

      {:ok, Enum.join(texts, "\n")}
    else
      error(input, "unsupported-content")
    end
  end

  defp context_change(state, item, text) do
    id = item["id"]

    if String.trim(text) == "" do
      if StreamState.get(state, "mcp-app-context")[id],
        do: {"mcp-app-context", id, Patch.delete()}
    else
      HalC2.Orchestration.upsert(state, "mcp-app-context", id, fn _ ->
        %{
          "id" => id,
          "threadId" => item["threadId"],
          "runId" => item["runId"],
          "itemId" => id,
          "text" => text,
          "updatedAt" => HalC2.Orchestration.Entities.now()
        }
      end)
    end
  end

  @doc "`text` cut to `bytes` (#{div(@max_context, 1024)} KiB), at a character boundary."
  def cut(text, bytes \\ @max_context)
  def cut(text, bytes) when byte_size(text) <= bytes, do: text
  def cut(text, bytes), do: valid_prefix(binary_part(text, 0, bytes))

  defp valid_prefix(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: valid_prefix(binary_part(bytes, 0, byte_size(bytes) - 1))
  end

  @doc """
  What the thread's apps told the model, oldest update first, as `{key, text}`: only
  apps still in the thread's history count, so an app whose run was rolled back no
  longer informs the agent.
  """
  def model_context(thread_id) do
    state = HalC2.Streams.state(thread_id)
    runs = StreamState.get(state, "run")
    items = StreamState.get(state, "turn-item")

    state
    |> StreamState.list("mcp-app-context")
    |> Enum.filter(fn context ->
      Map.has_key?(items, context["itemId"]) and
        get_in(runs, [context["runId"], "status"]) not in [nil, "rolled_back"]
    end)
    |> Enum.sort_by(&{&1["updatedAt"], &1["itemId"]})
    |> Enum.map(&{"mcp_app_" <> String.replace(&1["itemId"], ~r/[^\w.-]/, "_"), &1["text"]})
  end

  # The app a tool call made, and the live session of the provider that ran it.
  defp resolve(%{"threadId" => thread_id, "itemId" => item_id} = input) do
    state = HalC2.Streams.state(thread_id)

    with true <- thread?(state, thread_id) || error(input, "not-an-app"),
         %{"mcpApp" => %{"server" => _} = app} = item <-
           StreamState.get(state, "turn-item")[item_id] || error(input, "not-an-app"),
         {:ok, adapter} <- adapter(driver(state, item), input) do
      # An app made on another instance of the driver than the one now running the
      # thread is bound to that instance's session, which has stopped.
      instance = get_in(StreamState.get(state, "run"), [item["runId"], "providerInstanceId"])

      case adapter.session(thread_id, instance) do
        {:ok, session} -> {:ok, app, adapter, session}
        :stopped -> error(input, "session-stopped")
      end
    else
      {:error, _} = error -> error
      _ -> error(input, "not-an-app")
    end
  end

  # A thread this MC holds and nobody deleted.
  defp thread?(state, thread_id) do
    case StreamState.get(state, "thread")[thread_id] do
      %{} = thread -> thread["deletedAt"] == nil
      _ -> false
    end
  end

  # The provider thread the item ran on, else (a fork's copy) the thread's latest.
  defp driver(state, item) do
    threads = StreamState.get(state, "provider-thread")

    thread =
      threads[item["providerThreadId"]] ||
        threads |> Map.values() |> Enum.max_by(&(&1["lastRunOrdinal"] || 0), fn -> nil end)

    thread &&
      (thread["driver"] || HalC2.Orchestration.driver_for(thread["providerInstanceId"] || "codex"))
  end

  defp adapter("codex", _input), do: {:ok, HalC2.Codex.McpApps}
  defp adapter(_driver, input), do: error(input, "provider-unsupported")

  defp find_tool(input, adapter, session, app, name) do
    case adapter.list_tools(session, app["server"]) do
      {:ok, tools} -> {:ok, Enum.find(tools, &(is_map(&1) and &1["name"] == name))}
      {:error, _} -> error(input, "request-failed")
    end
  end

  # The spec lets apps call a tool unless its `_meta.ui.visibility` leaves them out.
  defp callable?(tool) do
    case get_in(tool, ["_meta", "ui", "visibility"]) do
      visibility when is_list(visibility) -> "app" in visibility
      _ -> true
    end
  end

  # Only a server's own `readOnlyHint: true` makes a tool read only.
  defp read_only?(tool), do: get_in(tool, ["annotations", "readOnlyHint"]) == true

  defp call_result(result) do
    %{"content" => List.wrap(result["content"])}
    |> put_present("structuredContent", result["structuredContent"])
    |> then(&if(result["isError"] == true, do: Map.put(&1, "isError", true), else: &1))
    |> put_present("_meta", result["_meta"])
  end

  @messages %{
    "not-an-app" => "This tool call has no MCP app.",
    "provider-unsupported" => "This thread's provider cannot run MCP app requests.",
    "session-stopped" =>
      "The app's thread is not running. Send a message in the thread that created it to use the app again.",
    "tool-not-callable" => "This app cannot call that tool.",
    "approval-required" => "The user has to approve this tool call first.",
    "unsupported-content" => "Only text and structured content are supported.",
    "request-failed" => "The app's MCP server request failed."
  }

  defp error(input, reason) do
    {:error,
     %{
       "_tag" => "McpAppRequestError",
       "threadId" => input["threadId"],
       "reason" => reason,
       "message" => @messages[reason]
     }}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, empty) when empty == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp tag, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
