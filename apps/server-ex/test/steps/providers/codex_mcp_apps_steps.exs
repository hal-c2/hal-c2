defmodule HalC2.Steps.Providers.CodexMcpApps do
  @moduledoc """
  MCP apps a Codex tool returns (`HalC2.McpApps`, `HalC2.Codex.McpApps`). The MC's
  part: it recognises the app on the tool item, stores its document for the thread,
  serves it in a sandbox of its own, and answers the app's requests through the
  thread's live Codex session. Codex is the fake app-server; its weather server and
  app are `test/support/fake_codex_mcp_apps.py`. The clients host the document.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @thread "Codex work"

  # --- an app in the thread --------------------------------------------------------

  step "a Codex tool call returned an MCP app", context do
    with_app(context, "show the mcp app")
  end

  step "a Codex tool call returned an MCP app with a result marked as an error", context do
    with_app(context, "show the mcp app, failed")
  end

  step "a Codex tool call returned an MCP app that reads its cookies while it starts", context do
    with_app(context, "show the mcp app that reads cookies")
  end

  step "an MCP app is open in a Codex thread", context do
    context |> with_app("show the mcp app") |> open_app()
  end

  # The thread title is the one the delete step shared with OpenCode's scenarios names.
  step "a Codex thread with an MCP app", context do
    context = with_app(context, "show the mcp app", "Work")
    assert File.exists?(document_path(context))
    context
  end

  step "the user looks at the tool call", context do
    open_app(context)
  end

  step "the app is shown and running in the thread", context do
    app = context.app_item["mcpApp"]

    assert %{
             "server" => "weather",
             "tool" => "get_forecast",
             "resourceUri" => "ui://weather/forecast.html"
           } = app

    # Only scheme-qualified origins survive from what the server declared.
    assert app["csp"] == %{
             "connectDomains" => ["https://api.weather.example"],
             "resourceDomains" => ["https://cdn.weather.example"]
           }

    assert app["permissions"] == %{"geolocation" => %{}}
    assert app["prefersBorder"] == true
    assert app["toolResult"]["content"] != nil

    assert_served_app(context.served)
    assert context.served.body =~ "<h1>Forecast</h1>"
    context
  end

  step "the user can open it full screen and close it again", context do
    # Full screen hosts the same document again, and so does the card after it.
    {:ok, 200, _, again} = serve(context)
    assert again == context.served.body
    {:ok, 200, _, _} = serve(context)
    context
  end

  step "the tool call still shows that it failed", context do
    item = context.app_item
    assert item["status"] == "failed"
    assert inspect(item["output"]) =~ "No forecast for Reykjavik"
    assert item["mcpApp"]["toolResult"]["isError"] == true
    context
  end

  # --- what the app may do ---------------------------------------------------------

  step "the app calls a tool that is not read only", context do
    {info, context} =
      World.call(context, "mcpApps.toolInfo", target(context, %{"name" => "save_city"}))

    {asked, context} =
      World.call(
        context,
        "mcpApps.callTool",
        target(context, %{"name" => "save_city", "arguments" => %{"city" => "Oslo"}})
      )

    Map.merge(context, %{tool_info: info, unapproved: asked})
  end

  step "the user is asked to approve it first", context do
    # What a client asks before it calls: the tool exists for apps and does not only read.
    assert {:ok, %{"callable" => true, "readOnly" => false}} = context.tool_info

    # A call the user has not approved is refused and never reaches the server.
    assert {:error, message, %{"reason" => "approval-required"}} = context.unapproved
    assert message =~ "approve"
    assert tool_calls(context) == []

    # Approved, it runs.
    {reply, context} =
      World.call(
        context,
        "mcpApps.callTool",
        target(context, %{
          "name" => "save_city",
          "arguments" => %{"city" => "Oslo"},
          "approved" => true
        })
      )

    assert {:ok, %{"content" => [%{"text" => ~s(called save_city with {"city": "Oslo"})}]}} =
             reply

    # A read-only tool needs no approval, and one hidden from apps is refused even approved.
    {reply, context} =
      World.call(
        context,
        "mcpApps.callTool",
        target(context, %{"name" => "get_forecast", "arguments" => %{}})
      )

    assert {:ok, %{"structuredContent" => %{"ok" => true}}} = reply

    {reply, context} =
      World.call(
        context,
        "mcpApps.callTool",
        target(context, %{"name" => "admin_reset", "arguments" => %{}, "approved" => true})
      )

    assert {:error, _, %{"reason" => "tool-not-callable"}} = reply
    assert Enum.map(tool_calls(context), & &1["tool"]) == ["save_city", "get_forecast"]
    context
  end

  # --- what the app tells the model ------------------------------------------------

  # The next message is Claude's step of that name, which sends into "Claude work".
  step "an MCP app in a Codex thread gave the model some context", context do
    context = with_app(context, "show the mcp app", "Claude work")
    # Two-byte characters, so the 16 KiB cut has to land between them.
    text = "Forecast view: " <> String.duplicate("é", 10_000)

    {reply, context} =
      World.call(
        context,
        "mcpApps.updateModelContext",
        target(context, %{
          "content" => [%{"type" => "text", "text" => text}],
          "structuredContent" => %{"city" => "Reykjavik"}
        })
      )

    assert {:ok, _} = reply
    Map.put(context, :app_context, text <> "\n" <> ~s({"city":"Reykjavik"}))
  end

  step "that context goes with it, cut to 16 KiB", context do
    value = sent_context(context, "hello")
    assert byte_size(value) <= 16 * 1024 and byte_size(value) > 16 * 1024 - 2
    assert String.valid?(value)
    assert String.starts_with?(context.app_context, value)
    context
  end

  step "a fork of the thread keeps it and a rollback past it drops it", context do
    title = context.app_thread
    context = World.fork(context, title, 2, "fork")
    assert {:ok, _} = context.reply
    context = World.post_message(context, "fork", "and in the fork")
    await_completed(context, "fork", 3)
    assert sent_context(context, "and in the fork") == sent_context(context, "hello")

    context = World.rollback(context, title, 0, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    context = World.post_message(context, title, "after the rollback")
    await_completed(context, title, 1)
    assert sent_context(context, "after the rollback") == nil
    context
  end

  # --- a stopped session -----------------------------------------------------------

  step "the Codex session of a thread with an MCP app has stopped", context do
    context = with_app(context, "show the mcp app")
    id = World.thread_id(context, @thread)
    :ok = HalC2.Orchestration.release_session(id)
    assert Registry.lookup(HalC2.Codex.Registry, id) == []
    Map.put(context, :initializes, initializes(context))
  end

  step "the user opens the app", context do
    # What a host asks first: the app's tool, to hand the app its tool info.
    {reply, context} =
      World.call(context, "mcpApps.toolInfo", target(context, %{"name" => "get_forecast"}))

    Map.put(context, :reply, reply)
  end

  step "the app says the session has stopped", context do
    assert {:error, message, %{"reason" => "session-stopped"}} = context.reply
    assert message =~ "The app's thread is not running"
    context
  end

  step "no session is started for it", context do
    id = World.thread_id(context, @thread)
    assert Registry.lookup(HalC2.Codex.Registry, id) == []
    assert initializes(context) == context.initializes
    sessions = StreamState.list(World.stream(context, @thread), "provider-session")
    assert sessions != [] and Enum.all?(sessions, &(&1["status"] == "stopped"))
    context
  end

  # --- deleting the thread ---------------------------------------------------------

  step "the app's stored documents are removed with it", context do
    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, context.app_thread), 10_000)
    refute File.exists?(context.document_path)
    context
  end

  # --- appearance and cookies ------------------------------------------------------

  step "the user switches the app between light and dark", context do
    # The host tells the app with `ui/notifications/host-context-changed`; the served
    # document has the script that applies it before any of the app's own.
    context
  end

  step "the MCP app's page and its text follow the appearance", context do
    body = context.served.body
    assert_served_app(context.served)
    theme = position(body, "ui/notifications/host-context-changed")
    assert theme < position(body, "window.app = true")
    assert body =~ "document.documentElement.style.colorScheme=theme"
    context
  end

  step "an MCP app stored in the thread before this works the same", context do
    # A document stored as it was before the bootstraps: no doctype, no policy.
    File.write!(
      context.document_path,
      "<html><body><script>window.app = true</script></body></html>"
    )

    {:ok, 200, headers, body} = serve(context)
    assert_served_app(%{headers: Map.new(headers), body: body})

    assert position(body, "ui/notifications/host-context-changed") <
             position(body, "window.app = true")

    context
  end

  step "the app is shown with its content", context do
    assert context.app_item["mcpApp"]["resourceUri"] == "ui://weather/cookies.html"
    assert_served_app(context.served)
    assert context.served.body =~ "document.title = document.cookie"
    context
  end

  step "the app sees no cookies and keeps none it sets", context do
    body = context.served.body
    # In its opaque-origin sandbox reading cookies throws; the script ahead of the
    # app's makes them read empty and drops writes.
    assert position(body, ~s(Object.defineProperty(document,"cookie")) <
             position(body, "document.title = document.cookie")

    refute context.served.headers["content-security-policy"] =~ "allow-same-origin"
    refute Map.has_key?(context.served.headers, "set-cookie")
    context
  end

  # --- helpers ---------------------------------------------------------------------

  # A thread whose first turn called the weather server's tool, which returned its app.
  defp with_app(context, text, title \\ @thread) do
    context = context |> World.fake_providers() |> World.launch_on(title, "codex", text)
    await_completed(context, title, 1)

    item =
      World.await_value(context, title, fn state ->
        Enum.find(StreamState.list(state, "turn-item"), &match?(%{"mcpApp" => %{}}, &1))
      end)

    context
    |> Map.merge(%{app_thread: title, app_item: item})
    |> then(&Map.put(&1, :document_path, document_path(&1)))
  end

  # The client fetches the app's document as its card does and keeps the answer.
  defp open_app(context) do
    {:ok, 200, headers, body} = serve(context)
    Map.put(context, :served, %{headers: Map.new(headers), body: body})
  end

  defp serve(context) do
    {reply, _} =
      World.call(context, "assets.createUrl", %{
        "resource" => %{
          "_tag" => "attachment",
          "attachmentId" => context.app_item["mcpApp"]["attachmentId"],
          "disposition" => "inline",
          "renderIntent" => "mcp-app"
        }
      })

    {:ok, %{"relativeUrl" => "/api/assets/" <> rest}} = reply
    rest |> String.split("/") |> hd() |> HalC2.Attachments.serve()
  end

  # Served as an app: HTML in a sandbox of its own (an opaque origin), its policy
  # first, scripts allowed inline.
  defp assert_served_app(%{headers: headers, body: body}) do
    assert headers["content-type"] =~ "text/html"
    assert headers["content-security-policy"] =~ "sandbox allow-scripts"
    assert body =~ ~r/\A<!doctype html>/i

    if body =~ "Content-Security-Policy" do
      assert position(body, "Content-Security-Policy") < position(body, "<script>")
      assert body =~ "script-src &#39;unsafe-inline&#39;" or body =~ "script-src 'unsafe-inline'"
    end
  end

  defp position(body, text) do
    case :binary.match(body, text) do
      {at, _} -> at
      :nomatch -> flunk("#{inspect(text)} is not in the document: #{body}")
    end
  end

  defp target(context, fields) do
    Map.merge(
      %{
        "threadId" => World.thread_id(context, context.app_thread),
        "itemId" => context.app_item["id"]
      },
      fields
    )
  end

  defp document_path(context),
    do: HalC2.Attachments.path(%{"id" => context.app_item["mcpApp"]["attachmentId"]})

  defp await_completed(context, title, count) do
    World.await_value(
      context,
      title,
      fn state ->
        runs = StreamState.list(state, "run")

        length(Enum.filter(runs, &(&1["status"] == "completed"))) == count and
          not Enum.any?(runs, &(&1["status"] in ["queued", "running", "starting", "waiting"]))
      end,
      10_000
    )
  end

  defp requests(context, method) do
    for entry <- World.provider_log(context, "codex"),
        get_in(entry, ["in", "method"]) == method,
        do: entry["in"]["params"]
  end

  defp tool_calls(context), do: requests(context, "mcpServer/tool/call")
  defp initializes(context), do: length(requests(context, "initialize"))

  # The app context the turn that `text` started carried, or nil.
  defp sent_context(context, text) do
    start =
      context
      |> requests("turn/start")
      |> Enum.filter(&String.contains?(get_in(&1, ["input", Access.at(0), "text"]) || "", text))
      |> List.last()

    assert start, "no turn started for #{inspect(text)}"

    # In as many entries as Codex keeps whole, which it sends in key order.
    parts =
      for {"mcp_app_" <> _ = key, %{"kind" => "untrusted", "value" => value}} <-
            Enum.sort(start["additionalContext"] || %{}),
          do: {key, value}

    assert Enum.all?(parts, fn {_, value} ->
             byte_size(value) <= HalC2.Mcp.Instructions.codex_entry_bytes()
           end)

    if parts != [], do: Enum.map_join(parts, fn {_, value} -> value end)
  end
end
