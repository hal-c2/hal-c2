defmodule HalC2.Steps.Preview.Automation do
  @moduledoc """
  Steps for `features/preview/automation.feature`: agents' `preview_*` MCP tools,
  routed by `HalC2.PreviewAutomation` to desktops' browsers.

  A desktop is a socket subscribed to the `previewAutomation` shape
  (`context.desktops`, by name; its client id is the name). The agent's tool call
  runs in a task while this process answers the requests the desktops receive with
  `previewAutomation.respond`, as a desktop's browser panel would, and logs each
  `{desktop, request}` in `context.log`. `context.answers` overrides the browser's
  answer per operation; a scenario that names no desktop gets `desktop-1`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World
  alias HalC2.Test.WsClient

  @host_sub 81
  @watch 82
  @page "http://localhost:5173/"
  @recording "recorded preview video"
  # What a current desktop advertises (`PREVIEW_AUTOMATION_OPERATIONS`).
  @all_operations ~w(status open navigate snapshot click type press scroll evaluate waitFor
                     recordingStart recordingStop resize setColorScheme)

  # The agent's phrasing of an action: {tool, arguments, operation}.
  @actions %{
    "read the tab's status" => {"preview_status", %{}, "status"},
    "navigate" => {"preview_navigate", %{"url" => "http://localhost:5173/about"}, "navigate"},
    "navigate to another address" =>
      {"preview_navigate", %{"url" => "http://localhost:5173/about"}, "navigate"},
    "resize the page" =>
      {"preview_resize", %{"mode" => "custom", "width" => 375, "height" => 667}, "resize"},
    "switch the page between light and dark" =>
      {"preview_set_appearance", %{"colorScheme" => "dark"}, "setColorScheme"},
    "click a button" => {"preview_click", %{"selector" => "button"}, "click"},
    "type text into a field" =>
      {"preview_type", %{"selector" => "#email", "text" => "sam@example.com"}, "type"},
    "scroll the page" => {"preview_scroll", %{"deltaY" => 600}, "scroll"},
    "wait for text to appear" => {"preview_wait_for", %{"text" => "Saved"}, "waitFor"},
    "evaluate a script in the page" =>
      {"preview_evaluate", %{"expression" => "document.title"}, "evaluate"},
    "start a recording" => {"preview_recording_start", %{}, "recordingStart"}
  }

  @operations %{
    "a status read" => "status",
    "a navigation" => "navigate",
    "a resize" => "resize",
    "a color scheme change" => "setColorScheme",
    "typing" => "type",
    "a scroll" => "scroll",
    "a wait" => "waitFor",
    "an evaluation" => "evaluate",
    "a recording start" => "recordingStart"
  }

  # --- hosts and routing -------------------------------------------------------------------

  step "a desktop offers its browser to the node", context do
    connect_desktop(context, "desktop-1")
  end

  step "the node confirms the connection", context do
    %{connection_id: connection_id} = context.desktops["desktop-1"]
    assert is_binary(connection_id) and connection_id != ""
    assert %{connection_id: ^connection_id} = broker().clients["desktop-1"]
    context
  end

  step "the desktop receives the agent's browser actions from then on", context do
    context = act(context, "click a button")
    assert {:ok, %{"done" => "click"}} = context.result
    assert [{"desktop-1", _}] = requests(context, "click")
    context
  end

  step "an agent has already acted in the browser of one desktop", context do
    context = context |> connect_desktop("desktop-1") |> act("read the tab's status")
    assert [{"desktop-1", _}] = requests(context, "status")
    context
  end

  # The newer desktop is focused too, so a fresh choice would pick it.
  step "a second desktop is also available", context do
    context |> connect_desktop("desktop-2") |> focus("desktop-2")
  end

  step "the agent takes another browser action", context do
    act(context, "click a button")
  end

  step "the action goes to the same desktop as before", context do
    assert [{"desktop-1", _}] = requests(context, "click")
    context
  end

  step "two desktops offer their browsers", context do
    context |> connect_desktop("desktop-1") |> connect_desktop("desktop-2")
  end

  # The first, so focus rather than registering last is what decides.
  step "only one of them has its window focused", context do
    focus(context, "desktop-1")
  end

  step "an agent takes its first browser action", context do
    act(context, "click a button")
  end

  step "the action goes to the desktop that can do the most, preferring the focused one",
       context do
    assert [{"desktop-1", _}] = requests(context, "click")
    clients = broker().clients
    most = clients |> Map.values() |> Enum.map(&MapSet.size(&1.operations)) |> Enum.max()
    assert MapSet.size(clients["desktop-1"].operations) == most
    assert clients["desktop-1"].focused and not clients["desktop-2"].focused
    context
  end

  step "no desktop is offering its browser", context do
    services()
    assert broker().clients == %{}
    Map.put(context, :no_desktop, true)
  end

  step "an agent asks to take a snapshot", context do
    tool(context, "preview_snapshot", %{})
  end

  step "the tool fails with {string}", %{args: [message]} = context do
    assert {:error, _tag, ^message} = context.result
    context
  end

  # A second desktop that can record is available, so a swap would be possible.
  step "an agent is working in a desktop browser that cannot record", context do
    operations = @all_operations -- ~w(recordingStart recordingStop)

    context
    |> connect_desktop("desktop-1", operations)
    |> act("read the tab's status")
    |> connect_desktop("desktop-2")
  end

  step "the tool fails saying no host is available for that action", context do
    assert {:error, "PreviewAutomationNoAvailableHostError", message} = context.result
    assert message =~ "No preview automation host is available for recordingStart."
    context
  end

  step "the agent's later actions still go to the same browser", context do
    context = act(context, "click a button")
    assert [{"desktop-1", _}] = requests(context, "click")
    assert requests(context, "recordingStart") == []
    context
  end

  step "an agent is working in a desktop browser", context do
    context |> connect_desktop("desktop-1") |> act("read the tab's status")
  end

  # The broker's own timer message, sent now rather than after 15 seconds.
  step "the desktop does not answer an action within its time limit", context do
    context
    |> answer("click", fn _request, _context -> :timeout end)
    |> act("click a button")
  end

  step "the node drops that desktop so it has to register again", context do
    %{client: client} = context.desktops["desktop-1"]
    {_end, _client} = Node.await(client, &(&1["t"] == "end" and &1["id"] == @host_sub))
    refute Map.has_key?(broker().clients, "desktop-1")
    context
  end

  step "the action is not tried a second time", context do
    assert [{"desktop-1", %{"timeoutMs" => 15_000}}] = requests(context, "click")
    assert broker().pending == %{}
    context
  end

  step "an agent is waiting on an action in a desktop browser", context do
    context |> connect_desktop("desktop-1") |> hold("click a button")
  end

  step "that desktop disconnects", context do
    {desktop, desktops} = Map.pop(context.desktops, "desktop-1")
    Mint.HTTP.close(desktop.client.conn)
    finish(%{Map.delete(context, :held) | desktops: desktops})
  end

  step "the tool fails saying the client disconnected during the action", context do
    assert {:error, "PreviewAutomationClientDisconnectedError",
            "Preview automation client desktop-1 disconnected during click."} = context.result

    context
  end

  step "a desktop is registered as a browser host", context do
    connect_desktop(context, "desktop-1")
  end

  # With an action waiting on the old connection, so its fate can be checked.
  step "the same desktop registers again", context do
    context = hold(context, "click a button")
    {old, desktops} = Map.pop(context.desktops, "desktop-1")

    %{context | desktops: Map.put(desktops, "old desktop-1", old)}
    |> Map.put(:old_task, context.task)
    |> Map.drop([:task, :held])
    |> connect_desktop("desktop-1")
  end

  step "only the new connection receives actions", context do
    context = act(context, "scroll the page")
    assert {:ok, _} = context.result
    assert [{"desktop-1", _}] = requests(context, "scroll")
    new = context.desktops["desktop-1"].connection_id
    assert new != context.desktops["old desktop-1"].connection_id
    assert %{connection_id: ^new} = broker().clients["desktop-1"]
    context
  end

  step "actions pending on the old connection fail as disconnected", context do
    assert {:error, "PreviewAutomationClientDisconnectedError",
            "Preview automation client desktop-1 disconnected during click."} =
             Task.await(context.old_task, 2_000)

    context
  end

  step "an agent navigated a specific browser tab", context do
    context = tool(context, "preview_navigate", %{"tabId" => "tab-2", "url" => @page})
    assert {:ok, %{"tabId" => "tab-2"}} = context.result
    context
  end

  step "the agent takes a snapshot without naming a tab", context do
    tool(context, "preview_snapshot", %{})
  end

  step "the snapshot is of the tab the agent last touched", context do
    assert {:ok, %{"tabId" => "tab-2"}, _content} = context.result
    assert [{_, %{"tabId" => "tab-2", "tabIdExplicit" => false}}] = requests(context, "snapshot")
    context
  end

  step "an agent's current tab is its first browser tab", context do
    context = tool(context, "preview_navigate", %{"tabId" => "tab-1", "url" => @page})
    assert {:ok, %{"tabId" => "tab-1"}} = context.result
    context
  end

  # As the tools do when they look up the page an action left a tab on.
  step "the node checks another tab's page for a tool result", context do
    scope = caller(context)
    opts = [tab_id: "tab-2", update_current_tab: false]
    context = serve(context, fn -> HalC2.PreviewAutomation.invoke(scope, "status", %{}, opts) end)
    assert {:ok, %{"tabId" => "tab-2"}} = context.result
    context
  end

  step "the agent's current tab stays the first one", context do
    context = act(context, "click a button")
    assert [{_, %{"tabId" => "tab-1", "tabIdExplicit" => false}}] = requests(context, "click")
    context
  end

  step ~r/^the desktop browser answers the agent's action with (?<failure>.+)$/,
       %{args: [failure]} = context do
    {action, args, error} =
      case failure do
        "an unsupported action" ->
          {"scroll the page", %{}, %{"_tag" => "PreviewAutomationUnsupportedClientError"}}

        "a missing named tab" ->
          {"click a button", %{"tabId" => "tab-9"},
           %{"_tag" => "PreviewAutomationTabNotFoundError"}}

        "no active tab" ->
          {"click a button", %{}, %{"_tag" => "PreviewAutomationTabNotFoundError"}}

        "a failure without any details" ->
          {"click a button", %{}, nil}
      end

    {_tool, _args, operation} = @actions[action]

    context
    |> answer(operation, fn _request, _context -> {:error, error} end)
    |> act(action, args)
  end

  # --- tools ---------------------------------------------------------------------------------

  step "an agent opens a preview without saying whether to show it", context do
    tool(context, "preview_open", %{"url" => @page})
  end

  step "whether the browser comes to the front follows the user's desktop preference",
       context do
    assert [{_, %{"input" => input}}] = requests(context, "open")
    refute Map.has_key?(input, "open")
    refute Map.has_key?(input, "show")
    context
  end

  step "an existing tab for the same page is reused", context do
    assert [{_, %{"input" => %{"url" => @page, "reuseExistingTab" => true}}}] =
             requests(context, "open")

    context
  end

  step "an agent opens a preview and asks to show it", context do
    tool(context, "preview_open", %{"url" => @page, "show" => true})
  end

  step "the browser comes to the front with the page", context do
    assert [{_, %{"input" => %{"url" => @page, "open" => true}}}] = requests(context, "open")
    assert {:ok, _} = context.result
    context
  end

  step "an agent's current tab shows {string}", %{args: [url]} = context do
    current_tab(context, url)
  end

  step "an agent's current tab shows a blank page", context do
    current_tab(context, "about:blank")
  end

  step "an agent's current tab shows a page", context do
    current_tab(context, @page)
  end

  step "an agent's current tab shows a slow page", context do
    current_tab(context, @page)
  end

  step "the agent clicks a button on the page", context do
    act(context, "click a button")
  end

  step "the agent presses a key on the page", context do
    tool(context, "preview_press", %{"key" => "Enter"})
  end

  step "the tool result names the page {string}", %{args: [url]} = context do
    assert {:ok, %{"toolIcon" => %{"_tag" => "website", "pageUrl" => ^url}}} = context.result
    context
  end

  step "the tool result does not name a page", context do
    assert {:ok, result} = context.result
    refute Map.has_key?(result, "toolIcon")
    # The page was looked up, and was not a website.
    assert [{_, %{"timeoutMs" => 500}}] = requests(context, "status")
    context
  end

  step ~r/^(?:an|the) agent takes a snapshot$/, context do
    tool(context, "preview_snapshot", %{})
  end

  step "the tool returns the page's address, its text and its interactive elements", context do
    assert {:ok, _metadata, [url | _]} = context.result
    assert JSON.decode!(url["text"]) == %{"url" => @page}
    assert %{"url" => @page, "visibleText" => "Welcome to the shop"} = bounded = bounded(context)
    assert [%{"role" => "button", "name" => "Add to cart"}] = bounded["interactiveElements"]
    context
  end

  step "the tool returns the page's screenshot", context do
    assert {:ok, metadata, content} = context.result
    assert [%{"data" => data, "mimeType" => "image/png"}] = images(content)
    assert Base.decode64!(data) == png()
    assert metadata["screenshot"] == %{"mimeType" => "image/png", "width" => 1, "height" => 1}
    context
  end

  step "an agent takes a snapshot and asks for no image", context do
    tool(context, "preview_snapshot", %{"includeImage" => false})
  end

  step "the tool returns the page's text without the screenshot", context do
    assert {:ok, %{"visibleText" => "Welcome to the shop"}, content} = context.result
    assert images(content) == []
    context
  end

  step ~r/^the page has (?<content>.+)$/, %{args: [content]} = context do
    {page, left_out} =
      case content do
        "visible text longer than 8000 characters" ->
          {%{"visibleText" => String.duplicate("a", 8_500)}, "visibleText after 8000 characters"}

        "an element named with 500 characters" ->
          {%{
             "interactiveElements" => [%{"role" => "link", "name" => String.duplicate("n", 500)}]
           }, "element names longer than 200 characters"}

        "100 console messages" ->
          {%{"consoleEntries" => for(i <- 1..100, do: %{"level" => "log", "text" => "m#{i}"})},
           "60 older console entries"}

        "an accessibility tree" ->
          {%{"accessibilityTree" => %{"role" => "document", "children" => []}},
           "accessibilityTree"}
      end

    context
    |> Map.put(:snapshot, page)
    |> Map.put(:left_out, left_out)
  end

  step ~r/^the snapshot keeps (?<kept>.+)$/, %{args: [kept]} = context do
    metadata = bounded(context)

    case kept do
      "the first 8000 characters of visible text" ->
        assert metadata["visibleText"] == String.duplicate("a", 8_000) <> "…"

      "the first 200 characters of the name" ->
        assert [%{"name" => name}] = metadata["interactiveElements"]
        assert name == String.duplicate("n", 200) <> "…"

      "the newest 40 console messages" ->
        assert Enum.map(metadata["consoleEntries"], & &1["text"]) ==
                 for(i <- 61..100, do: "m#{i}")

      "the interactive elements without the tree" ->
        assert [%{"name" => "Add to cart"}] = metadata["interactiveElements"]
        refute Map.has_key?(metadata, "accessibilityTree")
    end

    context
  end

  step "the snapshot says what it left out", context do
    assert {:ok, _metadata, content} = context.result

    assert [note] =
             for(
               %{"type" => "text", "text" => "Snapshot text was bounded. Omitted: " <> _ = text} <-
                 content,
               do: text
             )

    assert note =~ context.left_out
    context
  end

  step "the desktop sends a snapshot with no screenshot", context do
    context
    |> answer("snapshot", fn _request, context ->
      {:ok, Map.delete(page(context), "screenshot")}
    end)
    |> tool("preview_snapshot", %{})
  end

  step ~r/^(?:an|the) agent takes a snapshot and asks to save it$/, context do
    tool(context, "preview_snapshot", %{"save" => true})
  end

  step "the screenshot is saved under the node's browser artifacts named for {string}",
       %{args: [slug]} = context do
    assert {:ok, %{"screenshotPath" => path}, _content} = context.result
    assert Path.dirname(path) == artifacts()
    assert Path.basename(path) =~ ~r/^browser-screenshot-#{slug}-[a-z0-9]+-[0-9a-f]{8}\.png$/
    assert File.read!(path) == png()
    context
  end

  step "the tool result gives the saved file's path", context do
    assert {:ok, %{"screenshotPath" => path}, content} = context.result
    assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ path))
    context
  end

  # A file where the folder should be.
  step "the node cannot write its browser artifacts folder", context do
    File.mkdir_p!(Path.dirname(artifacts()))
    File.write!(artifacts(), "")
    context
  end

  step "the tool fails saying it could not save the preview screenshot to that path", context do
    assert {:error, "PreviewScreenshotSaveError", message} = context.result
    dir = Regex.escape(artifacts())

    assert message =~
             ~r/^Could not save preview screenshot to #{dir}\/browser-screenshot-localhost-.+\.png\.$/

    context
  end

  step "an agent is recording the preview", context do
    context = act(context, "start a recording")
    assert {:ok, %{"done" => "recordingStart"}} = context.result
    context
  end

  step "the agent stops the recording", context do
    tool(context, "preview_recording_stop", %{})
  end

  step "the recording is attached to the thread", context do
    assert {:ok, %{"id" => id} = recording} = context.result
    assert String.starts_with?(id, "th-agent-")
    assert recording["fileName"] == "recording.webm"
    refute Map.has_key?(recording, "uploadedAttachmentId")
    context
  end

  step "the tool result gives the attachment's path", context do
    assert {:ok, %{"id" => id, "path" => path}} = context.result
    assert path == HalC2.Attachments.path(%{"id" => id})
    assert File.read!(path) == @recording
    context
  end

  # The desktop names an upload it never made.
  step "the recording upload cannot be claimed", context do
    answer(context, "recordingStop", fn _request, _context ->
      {:ok, recording("pending-#{HalC2.Environment.uuid4()}-webm")}
    end)
  end

  step "the desktop app is too old to upload it", context do
    answer(context, "recordingStop", fn _request, _context -> {:ok, recording(nil)} end)
  end

  # `run "..."` requests are the timeline's approval steps, not browser actions.
  step ~r/^the agent asks to (?!run ")(?!.* allowing \d+ seconds$)(?<action>.+)$/,
       %{args: [action]} = context do
    act(context, action)
  end

  step ~r/^the desktop browser carries out (?<operation>.+) on that tab$/,
       %{args: [operation]} = context do
    op = Map.fetch!(@operations, operation)
    # The last: setting up the current tab was a navigation too.
    assert {"desktop-1", %{"tabId" => "tab-1", "tabIdExplicit" => false}} =
             List.last(requests(context, op))

    Map.put(context, :operation, op)
  end

  step "the result reaches the agent", context do
    assert {:ok, result} = context.result
    result = if context.operation == "evaluate", do: result["value"], else: result
    assert result["done"] == context.operation
    context
  end

  # The request is held while the broker's timer is read, then answered.
  step ~r/^the agent asks to (?<action>.+) allowing (?<seconds>\d+) seconds$/,
       %{args: [action, seconds]} = context do
    {_tool, _args, operation} = @actions[action]
    timeout = String.to_integer(seconds) * 1_000
    context = hold(context, action, %{"timeoutMs" => timeout})
    {_desktop, request} = context.held
    left = Process.read_timer(broker().pending[request["requestId"]].timer)

    context
    |> Map.put(:wait, %{operation: operation, timeout_ms: request["timeoutMs"], left: left})
    |> finish()
  end

  step "the node waits up to {int} seconds for the desktop browser to answer",
       %{args: [seconds]} = context do
    timeout = seconds * 1_000
    assert %{timeout_ms: ^timeout, left: left} = context.wait
    assert left > 15_000 and left <= timeout
    assert {:ok, %{"done" => done}} = context.result
    assert done == context.wait.operation
    context
  end

  step "the thread has {int} browser tabs", %{args: [count]} = context do
    context = agent_thread(context)
    thread = caller(context).thread_id

    Enum.reduce(1..count, context, fn i, context ->
      {_tab, context} =
        World.call!(context, "preview.open", %{"threadId" => thread, "url" => "#{@page}#{i}"})

      context
    end)
  end

  step "an agent lists the thread's preview tabs", context do
    Map.put(context, :result, HalC2.Mcp.Tools.call("halc2_preview_list", %{}, caller(context)))
  end

  step "it receives the first 20 tabs and a cursor for the rest", context do
    {:ok, all} = HalC2.Preview.list(%{"threadId" => caller(context).thread_id})
    assert {:ok, %{"sessions" => sessions, "nextCursor" => 20}} = context.result
    assert sessions == Enum.take(all["sessions"], 20)
    Map.put(context, :all_tabs, all["sessions"])
  end

  step "listing again from that cursor returns the last 5 with no further cursor", context do
    assert {:ok, %{"sessions" => sessions, "nextCursor" => nil}} =
             HalC2.Mcp.Tools.call("halc2_preview_list", %{"cursor" => 20}, caller(context))

    assert sessions == Enum.drop(context.all_tabs, 20)
    assert length(sessions) == 5
    context
  end

  # Opened by the desktop on the agent's behalf, as `preview.open` from its socket.
  step "the thread has a browser tab the agent opened", context do
    context = agent_thread(context)

    {tab, context} =
      World.call!(context, "preview.open", %{
        "threadId" => caller(context).thread_id,
        "url" => @page
      })

    watcher =
      context.node
      |> Node.connect()
      |> Node.sub(@watch, %{"type" => "preview", "node" => Atom.to_string(node())})

    {{:ok, _}, watcher} =
      Node.call(watcher, context.node.environment, "preview.list", %{"threadId" => "none"})

    context
    |> Map.put(:tab, tab["tabId"])
    |> World.put_client("watcher", watcher)
  end

  step "the agent closes that tab", context do
    result = HalC2.Mcp.Tools.call("halc2_preview_close", %{"tabId" => context.tab}, caller(context))
    Map.put(context, :result, result)
  end

  step "the tab is gone for every client", context do
    assert {:ok, %{}} = context.result
    tab = context.tab

    {_frame, _watcher} =
      Node.await(World.client(context, "watcher"), fn frame ->
        frame["t"] == "preview" and frame["id"] == @watch and
          match?(%{"type" => "closed", "tabId" => ^tab}, frame["event"])
      end)

    {listed, _context} =
      World.call!(context, "preview.list", %{"threadId" => caller(context).thread_id})

    assert listed["sessions"] == []
    context
  end

  # --- desktops --------------------------------------------------------------------------------

  defp services do
    Node.ensure(HalC2.Preview)
    Node.ensure(HalC2.PreviewAutomation)
  end

  defp broker, do: :sys.get_state(HalC2.PreviewAutomation)

  # Registers a socket as the browser host `client_id`, waiting for its connection.
  defp connect_desktop(context, name, operations \\ nil, client_id \\ nil) do
    services()
    client_id = client_id || String.replace_prefix(name, "old ", "")

    host = %{
      "clientId" => client_id,
      "environmentId" => context.node.environment,
      "supportedOperations" => operations || @all_operations
    }

    shape = %{"type" => "previewAutomation", "node" => Atom.to_string(node()), "host" => host}
    client = context.node |> Node.connect() |> Node.sub(@host_sub, shape)

    {frame, client} =
      Node.await(client, fn frame ->
        frame["t"] == "previewAutomation" and frame["event"]["type"] == "connected"
      end)

    desktop = %{
      client: client,
      client_id: client_id,
      connection_id: frame["event"]["connectionId"]
    }

    Map.put(context, :desktops, Map.put(context[:desktops] || %{}, name, desktop))
  end

  defp focus(context, name) do
    desktop = context.desktops[name]

    payload = %{
      "clientId" => desktop.client_id,
      "connectionId" => desktop.connection_id,
      "focused" => true
    }

    {nil, client} =
      Node.call!(desktop.client, context.node.environment, "previewAutomation.focusHost", payload)

    put_in(context, [:desktops, name, :client], client)
  end

  defp answer(context, operation, fun),
    do: Map.put(context, :answers, Map.put(context[:answers] || %{}, operation, fun))

  # The browser's answer to a request: a result, an error, or `:timeout` (never answered).
  defp reply(request, context) do
    case (context[:answers] || %{})[request["operation"]] do
      nil -> default_reply(request, context)
      fun -> fun.(request, context)
    end
  end

  defp default_reply(%{"operation" => "status"} = request, context),
    do:
      {:ok,
       %{
         "tabId" => tab(request),
         "url" => context[:page] || @page,
         "title" => "Shop",
         "done" => "status"
       }}

  defp default_reply(%{"operation" => "snapshot"} = request, context),
    do: {:ok, Map.put(page(context), "tabId", tab(request))}

  defp default_reply(%{"operation" => "recordingStop"}, context) do
    {:ok, recording(upload(context))}
  end

  defp default_reply(%{"operation" => op} = request, _context),
    do: {:ok, %{"tabId" => tab(request), "done" => op}}

  defp tab(request), do: request["tabId"] || "tab-1"

  defp page(context) do
    Map.merge(
      %{
        "url" => context[:page] || @page,
        "title" => "Shop",
        "visibleText" => "Welcome to the shop",
        "interactiveElements" => [%{"ref" => "e1", "role" => "button", "name" => "Add to cart"}],
        "screenshot" => %{
          "data" => Base.encode64(png()),
          "mimeType" => "image/png",
          "width" => 1,
          "height" => 1
        }
      },
      context[:snapshot] || %{}
    )
  end

  # A 1x1 PNG.
  defp png,
    do:
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      )

  # The snapshot's page as the agent reads it: the bounded JSON text after the address.
  defp bounded(context) do
    assert {:ok, _metadata, [_url, %{"type" => "text", "text" => text} | _]} = context.result
    JSON.decode!(text)
  end

  defp images(content), do: for(%{"type" => "image"} = image <- content, do: image)

  defp artifacts, do: Path.join(Application.fetch_env!(:hal_c2, :home), "browser-artifacts")

  defp recording(id) do
    %{
      "fileName" => "recording.webm",
      "mimeType" => "video/webm",
      "sizeBytes" => byte_size(@recording)
    }
    |> then(&if(id, do: Map.put(&1, "uploadedAttachmentId", id), else: &1))
  end

  # Uploads the recording the way the desktop does: a signed URL, then an HTTP POST.
  defp upload(context) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => path}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => "recording.webm",
        "mimeType" => "video/webm",
        "sizeBytes" => byte_size(@recording),
        "type" => "file"
      })

    url = ~c"http://127.0.0.1:#{context.node.port}#{path}"

    {:ok, {{_, 204, _}, _, _}} =
      :httpc.request(:post, {url, [], ~c"video/webm", @recording}, [], [])

    id
  end

  # --- the agent -------------------------------------------------------------------------------

  defp caller(context), do: %{thread_id: context[:agent_thread] || "th-agent", instance: "codex"}

  # The agent's thread as a real thread, for tools that read its row.
  defp agent_thread(context) do
    services()
    context = context |> World.create_project("Shop") |> World.create_thread("Agent")
    Map.put(context, :agent_thread, World.thread_id(context, "Agent"))
  end

  defp current_tab(context, url) do
    context = context |> Map.put(:page, url) |> tool("preview_navigate", %{"url" => url})
    assert {:ok, %{"tabId" => "tab-1"}} = context.result
    context
  end

  defp act(context, action, extra \\ %{}) do
    {tool, args, _operation} = Map.fetch!(@actions, action)
    tool(context, tool, Map.merge(args, extra))
  end

  defp tool(context, name, args) do
    context = default_desktop(context)
    scope = caller(context)
    serve(context, fn -> HalC2.Mcp.Tools.call(name, args, scope) end)
  end

  # Starts an action and returns once its request reached a desktop, unanswered
  # (`context.held`), with the call still waiting (`context.task`).
  defp hold(context, action, extra \\ %{}) do
    {tool, args, operation} = Map.fetch!(@actions, action)
    context = default_desktop(context)
    scope = caller(context)
    task = Task.async(fn -> HalC2.Mcp.Tools.call(tool, Map.merge(args, extra), scope) end)

    case loop(Map.put(context, :task, task), &(&1["operation"] == operation)) do
      %{held: _} = context -> context
      context -> flunk("the action finished without waiting: #{inspect(context.result)}")
    end
  end

  # Answers the held request, then serves the call to its end.
  defp finish(%{held: {name, request}} = context) do
    context |> Map.delete(:held) |> respond(name, request) |> loop(nil)
  end

  defp finish(context), do: loop(context, nil)

  defp default_desktop(context) do
    if context[:desktops] in [nil, %{}] and !context[:no_desktop],
      do: connect_desktop(context, "desktop-1"),
      else: context
  end

  defp serve(context, fun), do: loop(Map.put(context, :task, Task.async(fun)), nil)

  # Handles the desktops' frames until the call returns (`context.result`), or a
  # request matches `until` (`context.held`).
  defp loop(context, until) do
    case next_frame(context) do
      {name, %{"t" => "previewAutomation", "event" => %{"type" => "request"} = event}, context} ->
        request = event["request"]
        context = Map.update(context, :log, [{name, request}], &(&1 ++ [{name, request}]))

        if until && until.(request),
          do: Map.put(context, :held, {name, request}),
          else: context |> respond(name, request) |> loop(until)

      {_name, _frame, context} ->
        loop(context, until)

      nil ->
        await_socket_or_result(context, until)
    end
  end

  defp await_socket_or_result(context, until) do
    %{ref: ref} = context.task

    sockets =
      Map.new(context[:desktops] || %{}, fn {name, d} ->
        {Mint.HTTP.get_socket(d.client.conn), name}
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        context |> Map.delete(:task) |> Map.put(:result, result)

      {tag, socket, _data} = message when tag in [:tcp, :ssl] and is_map_key(sockets, socket) ->
        name = sockets[socket]
        client = WsClient.feed(context.desktops[name].client, message)
        context |> put_in([:desktops, name, :client], client) |> loop(until)
    after
      5_000 -> flunk("the agent's preview tool never returned")
    end
  end

  defp next_frame(context) do
    Enum.find_value(context[:desktops] || %{}, fn
      {name, %{client: %{inbox: [frame | rest]}}} ->
        {name, frame, put_in(context, [:desktops, name, :client, :inbox], rest)}

      _ ->
        nil
    end)
  end

  defp respond(context, name, request) do
    case reply(request, context) do
      :timeout ->
        send(Process.whereis(HalC2.PreviewAutomation), {:timeout, request["requestId"]})
        context

      {:ok, result} ->
        send_response(context, name, request, %{"ok" => true, "result" => result})

      {:error, nil} ->
        send_response(context, name, request, %{"ok" => false})

      {:error, error} ->
        send_response(context, name, request, %{"ok" => false, "error" => error})
    end
  end

  # Not awaited: the reply frame is skipped like any other the desktop does not act on.
  defp send_response(context, name, request, response) do
    desktop = context.desktops[name]

    payload =
      Map.merge(response, %{
        "clientId" => desktop.client_id,
        "connectionId" => desktop.connection_id,
        "requestId" => request["requestId"]
      })

    id = System.unique_integer([:positive])

    client =
      Node.rpc(desktop.client, context.node.environment, id, "previewAutomation.respond", payload)

    put_in(context, [:desktops, name, :client], client)
  end

  defp requests(context, operation),
    do: for({name, %{"operation" => ^operation} = r} <- context[:log] || [], do: {name, r})
end
