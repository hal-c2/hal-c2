defmodule T3.Steps.Preview.Surfaces do
  @moduledoc """
  Steps for `features/preview/surfaces.feature`: the node's browser tabs
  (`preview.*` RPCs and the `preview` shape) and its local server suggestions
  (the `localServers` shape).

  The acting client is the default socket; a second socket, `"watcher"`, watches
  the `preview` shape so every change can be checked as other clients see it.
  Local servers are real listeners in this VM on free ports; a feature's port
  number names one (`context.ports`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  @thread "th-preview"
  @watch 71
  @servers 72

  # --- tabs ------------------------------------------------------------------------------

  step "a client opens a browser tab for the thread at {string}", %{args: [url]} = context do
    open(context, %{"url" => url})
  end

  step "a client opens a browser tab for the thread without an address", context do
    open(context, %{})
  end

  step "a client opens a browser tab under the profile {string}", %{args: [profile]} = context do
    open(context, %{"profileId" => profile})
  end

  step "the thread has a new tab loading {string}", %{args: [url]} = context do
    assert %{"navStatus" => %{"_tag" => "Loading", "url" => ^url}} = listed(context, context.tab)
    context
  end

  step "the thread has a new idle tab", context do
    assert %{"navStatus" => %{"_tag" => "Idle"}} = listed(context, context.tab)
    context
  end

  step "the tab fills the space it is given", context do
    assert listed(context, context.tab)["viewport"] == %{"_tag" => "fill"}
    context
  end

  step "the tab remembers the profile {string}", %{args: [profile]} = context do
    assert listed(context, context.tab)["profileId"] == profile
    context
  end

  step "every watching client is told the tab {word}", %{args: [what]} = context do
    told(context, context.tab, what)
  end

  step "a browser tab showing {string}", %{args: [url]} = context do
    context |> open(%{"url" => url}) |> navigate(%{"url" => url}) |> drain()
  end

  step "a browser tab showing a page titled {string}", %{args: [title]} = context do
    url = "http://localhost:5173/"
    context |> open(%{"url" => url}) |> navigate(%{"url" => url, "resolvedTitle" => title})
  end

  step "a browser tab showing a page", context do
    url = "http://localhost:5173/"
    context |> open(%{"url" => url}) |> navigate(%{"url" => url}) |> drain()
  end

  step "a browser tab loading {string}", %{args: [url]} = context do
    context |> open(%{"url" => url}) |> drain()
  end

  step "a browser tab that fills its space", context do
    context = context |> open(%{}) |> drain()
    assert listed(context, context.tab)["viewport"] == %{"_tag" => "fill"}
    context
  end

  step "a browser tab that has visited two pages", context do
    context
    |> open(%{"url" => "http://localhost:5173/"})
    |> navigate(%{"url" => "http://localhost:5173/"})
    |> navigate(%{"url" => "http://localhost:5173/cart"})
    |> drain()
  end

  step "the desktop reports it navigated to {string} titled {string}",
       %{args: [url, title]} = context do
    navigate(context, %{"url" => url, "resolvedTitle" => title})
  end

  step "the desktop reports a navigation without a title", context do
    navigate(context, %{"url" => "http://localhost:5173/next"})
  end

  step "the tab shows {string} titled {string}", %{args: [url, title]} = context do
    assert %{"_tag" => "Success", "url" => ^url, "title" => ^title} =
             listed(context, context.tab)["navStatus"]

    context
  end

  step "the tab keeps the title {string}", %{args: [title]} = context do
    assert %{"_tag" => "Success", "url" => "http://localhost:5173/next", "title" => ^title} =
             listed(context, context.tab)["navStatus"]

    context
  end

  step "the desktop reports the load failed with {string}", %{args: [code]} = context do
    report(context, %{
      "navStatus" => %{
        "_tag" => "LoadFailed",
        "url" => "http://localhost:9999",
        "title" => "",
        "code" => -102,
        "description" => code
      },
      "canGoBack" => false,
      "canGoForward" => false
    })
  end

  step "every watching client is told the tab failed with that error", context do
    {event, context} = event(context, &(&1["type"] == "failed" and &1["tabId"] == context.tab))
    assert %{"url" => "http://localhost:9999", "code" => -102} = event
    assert event["description"] == "ERR_CONNECTION_REFUSED"
    context
  end

  step "the desktop reports it can go back but not forward", context do
    report(context, %{
      "navStatus" => %{
        "_tag" => "Success",
        "url" => "http://localhost:5173/cart",
        "title" => "Cart"
      },
      "canGoBack" => true,
      "canGoForward" => false
    })
  end

  step "every client sees that the tab can go back but not forward", context do
    {event, context} = event(context, &(&1["type"] == "navigated" and &1["tabId"] == context.tab))
    assert %{"canGoBack" => true, "canGoForward" => false} = event["snapshot"]
    assert %{"canGoBack" => true, "canGoForward" => false} = listed(context, context.tab)
    context
  end

  step "a client resizes the tab to the {string} preset", %{args: [preset]} = context do
    viewport = %{"_tag" => "preset", "presetId" => preset, "width" => 375, "height" => 667}

    {reply, context} =
      rpc(context, "preview.resize", %{"tabId" => context.tab, "viewport" => viewport})

    assert {:ok, %{"viewport" => ^viewport}} = reply
    context
  end

  step "the tab's viewport is the {string} preset", %{args: [preset]} = context do
    assert %{"_tag" => "preset", "presetId" => ^preset} = listed(context, context.tab)["viewport"]
    context
  end

  step "a client refreshes the tab", context do
    before = listed(context, context.tab)
    {reply, context} = rpc(context, "preview.refresh", %{"tabId" => context.tab})
    context |> Map.put(:reply, reply) |> Map.put(:before, before)
  end

  step "the request succeeds without changing the tab", context do
    assert {:ok, nil} = context.reply
    assert listed(context, context.tab) == context.before
    watcher = Node.refute_frame(World.client(context, "watcher"), &(&1["t"] == "preview"))
    World.put_client(context, "watcher", watcher)
  end

  step "the desktop reports the reload as it happens", context do
    context =
      report(context, %{
        "navStatus" => %{"_tag" => "Loading", "url" => "http://localhost:5173/", "title" => ""},
        "canGoBack" => false,
        "canGoForward" => false
      })

    {event, context} = event(context, &(&1["type"] == "navigated" and &1["tabId"] == context.tab))
    assert event["snapshot"]["navStatus"]["_tag"] == "Loading"
    context
  end

  step "a thread with two browser tabs", context do
    context = open(context, %{"url" => "http://localhost:5173/a"})
    first = context.tab
    context = context |> open(%{"url" => "http://localhost:5173/b"}) |> drain()
    Map.merge(context, %{first: first, second: context.tab})
  end

  step "a thread with two browser tabs, the second changed most recently", context do
    context = open(context, %{"url" => "http://localhost:5173/a"})
    first = context.tab
    context = open(context, %{"url" => "http://localhost:5173/b"})
    # Changes are ordered by time; the second changes again until its time is later.
    context = touch_until_later(context, first)
    Map.merge(context, %{first: first, second: context.tab})
  end

  step "a client closes the first tab", context do
    {reply, context} = rpc(context, "preview.close", %{"tabId" => context.first})
    assert {:ok, nil} = reply
    context
  end

  step "only the second tab remains", context do
    assert [%{"tabId" => tab}] = sessions(context)
    assert tab == context.second
    context
  end

  step "every watching client is told the first tab closed", context do
    told(context, context.first, "closed")
  end

  step "a client closes the thread's browser tabs without naming one", context do
    {reply, context} = rpc(context, "preview.close", %{})
    assert {:ok, nil} = reply
    context
  end

  step "the thread has no browser tabs", context do
    assert sessions(context) == []
    context
  end

  step "a client lists the thread's browser tabs", context do
    {reply, context} = rpc(context, "preview.list", %{})
    assert {:ok, list} = reply
    Map.put(context, :list, list)
  end

  step "it receives both tabs with the second one last", context do
    assert Enum.map(context.list["sessions"], & &1["tabId"]) == [context.first, context.second]
    context
  end

  step "the list carries the node's run and change numbers", context do
    {last, context} = event(context, fn _ -> true end, :last)
    assert context.list["serverEpoch"] == last["serverEpoch"]
    assert context.list["revision"] == last["revision"]
    context
  end

  step "a client is watching browser tab changes", context do
    watcher(context)
  end

  step "a tab opens, navigates and closes", context do
    context
    |> open(%{"url" => "http://localhost:5173/"})
    |> navigate(%{"url" => "http://localhost:5173/a"})
    |> then(fn context ->
      {{:ok, nil}, context} = rpc(context, "preview.close", %{"tabId" => context.tab})
      context
    end)
  end

  step "each event carries a higher change number than the one before", context do
    {events, context} =
      Enum.map_reduce(~w(opened navigated closed), context, fn type, context ->
        event(context, &(&1["type"] == type and &1["tabId"] == context.tab))
      end)

    revisions = Enum.map(events, & &1["revision"])
    assert revisions == Enum.sort(revisions) and length(Enum.uniq(revisions)) == 3
    context
  end

  step "a thread with a browser tab", context do
    context = open(context, %{"url" => "http://localhost:5173/"})
    {{:ok, list}, context} = rpc(context, "preview.list", %{})
    assert [_] = list["sessions"]
    Map.put(context, :epoch, list["serverEpoch"])
  end

  step "the node reports a different run number so clients drop their old tabs", context do
    {{:ok, list}, context} = rpc(context, "preview.list", %{})
    assert is_binary(list["serverEpoch"]) and list["serverEpoch"] != context.epoch
    context
  end

  step "a client asks to {word} a tab the thread does not have", %{args: [action]} = context do
    ask_unknown(context, action)
  end

  step "a client asks to report status on a tab the thread does not have", context do
    ask_unknown(context, "report status on")
  end

  step "the request fails naming the thread and the unknown tab", context do
    assert {:error, "PreviewSessionLookupError", detail} = context.reply
    assert %{"threadId" => @thread, "tabId" => "tab-missing"} = detail
    context
  end

  # --- local servers -------------------------------------------------------------------

  step "a dev server is serving HTML on port {int} of the node's machine",
       %{args: [port]} = context do
    serve(context, port, :html)
  end

  step ~r/^a program listening on port (?<port>\d+) that answers with (?<answer>.+)$/,
       %{args: [port, answer]} = context do
    port = String.to_integer(port)

    kind =
      case answer do
        "an HTML page" -> :html
        "a redirect" -> :redirect
        "no HTTP at all" -> :none
        "JSON" -> :json
        "an empty 204 response" -> :empty
      end

    serve(context, port, kind)
  end

  step "a client watches for local servers", context do
    watch_servers(context)
  end

  step "a client is watching for local servers", context do
    watch_servers(context)
  end

  step ~r/^"http:\/\/localhost:(?<port>\d+)" is suggested with the name of the process serving it$/,
       %{args: [port]} = context do
    actual = context.ports[String.to_integer(port)]
    server = Enum.find(context.servers, &(&1["port"] == actual))
    assert server, "port #{actual} was not suggested: #{inspect(context.servers)}"
    assert server["url"] == "http://localhost:#{actual}"
    assert server["pid"] == String.to_integer(System.pid())
    assert server["processName"] =~ "beam"
    context
  end

  step "port {int} is suggested", %{args: [port]} = context do
    assert context.ports[port] in Enum.map(context.servers, & &1["port"])
    context
  end

  step "port {int} is not suggested", %{args: [port]} = context do
    refute context.ports[port] in Enum.map(context.servers, & &1["port"])
    context
  end

  step "the node's own port is not among the suggestions", context do
    # The node's own port answers with its web app, so it would be a suggestion.
    refute context.node.port in Enum.map(context.servers, & &1["port"])
    context
  end

  step "a new dev server starts serving HTML on port {int}", %{args: [port]} = context do
    serve(context, port, :html)
  end

  step "within a few seconds the client is told the list now includes port {int}",
       %{args: [port]} = context do
    actual = context.ports[port]

    has? =
      &(&1["t"] == "localServers" and
          actual in Enum.map(&1["list"]["servers"], fn s -> s["port"] end))

    {_, client} = Node.await(World.client(context), has?, 8_000)
    World.put_client(context, client)
  end

  step "the last client stops watching for local servers", context do
    context = watch_servers(context)
    client = World.client(context) |> Node.unsub(@servers) |> ping()
    World.put_client(context, client)
  end

  step "the node no longer scans for listening ports", context do
    pid = Process.whereis(T3.LocalServers)
    # The next scan tick, now rather than a few seconds from now.
    send(pid, :scan)
    state = :sys.get_state(pid)
    assert state.watchers == %{}
    assert state.timer == nil and state.list == nil
    context
  end

  step "the node's machine cannot list listening ports", context do
    path = System.get_env("PATH")
    System.put_env("PATH", Node.tmp_dir(context.node, "empty-path"))
    ExUnit.Callbacks.on_exit(fn -> System.put_env("PATH", path) end)
    context
  end

  step "the suggestion list is empty", context do
    assert context.servers == []
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp services(context) do
    Node.ensure(T3.Preview)
    context
  end

  # The watcher socket, subscribed to tab changes before anything happens.
  defp watcher(context) do
    context = services(context)

    case context.clients["watcher"] do
      nil ->
        client =
          Node.connect(context.node)
          |> Node.sub(@watch, %{"type" => "preview", "node" => Atom.to_string(node())})
          |> ping()

        World.put_client(context, "watcher", client)

      _ ->
        context
    end
  end

  defp ping(client) do
    client = T3.Test.WsClient.send_json(client, %{"t" => "ping"})
    {_, client} = Node.await(client, &(&1["t"] == "pong"))
    client
  end

  defp rpc(context, method, payload) do
    context = watcher(context)
    World.call(context, method, Map.put(payload, "threadId", @thread))
  end

  defp open(context, input) do
    {reply, context} = rpc(context, "preview.open", input)
    assert {:ok, %{"tabId" => tab}} = reply
    Map.put(context, :tab, tab)
  end

  defp navigate(context, input) do
    {reply, context} = rpc(context, "preview.navigate", Map.put(input, "tabId", context.tab))
    assert {:ok, %{"navStatus" => %{"_tag" => "Success"}}} = reply
    context
  end

  defp report(context, input) do
    {reply, context} = rpc(context, "preview.reportStatus", Map.put(input, "tabId", context.tab))
    assert {:ok, nil} = reply
    context
  end

  defp sessions(context) do
    {{:ok, %{"sessions" => sessions}}, _} = rpc(context, "preview.list", %{})
    sessions
  end

  defp listed(context, tab) do
    Enum.find(sessions(context), &(&1["tabId"] == tab)) || flunk("no tab #{tab}")
  end

  # Waits for the watcher's event matching `fun` (`:last` takes every pending one).
  defp event(context, fun, mode \\ :first) do
    watcher = World.client(context, "watcher")

    case mode do
      :first ->
        {frame, watcher} = Node.await(watcher, &(&1["t"] == "preview" and fun.(&1["event"])))
        {frame["event"], World.put_client(context, "watcher", watcher)}

      :last ->
        {events, watcher} = ping(watcher, :collect)
        {List.last(events), World.put_client(context, "watcher", watcher)}
    end
  end

  # Pings and collects every preview event that arrives before the pong.
  defp ping(client, :collect) do
    client = T3.Test.WsClient.send_json(client, %{"t" => "ping"})
    collect(client, [])
  end

  defp collect(client, acc) do
    {frame, client} = T3.Test.WsClient.recv(client, 2_000)

    case frame do
      %{"t" => "pong"} -> {Enum.reverse(acc), client}
      %{"t" => "preview", "event" => event} -> collect(client, [event | acc])
      _ -> collect(client, acc)
    end
  end

  defp told(context, tab, what) do
    {event, context} = event(context, &(&1["type"] == what and &1["tabId"] == tab))
    assert event["threadId"] == @thread
    assert is_binary(event["serverEpoch"]) and is_integer(event["revision"])

    if what != "closed",
      do: assert(event["snapshot"] == listed(context, tab))

    context
  end

  # Drops the watcher's events so far, so later steps see only new ones.
  defp drain(context) do
    {_, watcher} = ping(World.client(context, "watcher"), :collect)
    World.put_client(context, "watcher", watcher)
  end

  defp touch_until_later(context, first) do
    context = navigate(context, %{"url" => "http://localhost:5173/b"})
    [a, b] = Enum.map([first, context.tab], &listed(context, &1)["updatedAt"])
    if b > a, do: context, else: touch_until_later(context, first)
  end

  defp ask_unknown(context, action) do
    {method, extra} =
      case action do
        "navigate" -> {"preview.navigate", %{"url" => "http://localhost:5173/"}}
        "report status on" -> {"preview.reportStatus", %{"navStatus" => %{"_tag" => "Idle"}}}
        "resize" -> {"preview.resize", %{"viewport" => %{"_tag" => "fill"}}}
        "refresh" -> {"preview.refresh", %{}}
      end

    {reply, context} = rpc(context, method, Map.put(extra, "tabId", "tab-missing"))
    Map.put(context, :reply, reply)
  end

  defp watch_servers(context) do
    Node.ensure(T3.LocalServers)

    client =
      Node.sub(World.client(context), @servers, %{
        "type" => "localServers",
        "node" => Atom.to_string(node())
      })

    {frame, client} =
      Node.await(client, &(&1["t"] == "localServers" and &1["id"] == @servers), 10_000)

    context |> World.put_client(client) |> Map.put(:servers, frame["list"]["servers"])
  end

  # A listener on a free loopback port answering every request as `kind`.
  defp serve(context, port, kind) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, actual} = :inet.port(listen)

    pid = spawn(fn -> receive(do: (:go -> accept(listen, kind))) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    send(pid, :go)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    Map.update(context, :ports, %{port => actual}, &Map.put(&1, port, actual))
  end

  defp accept(listen, kind) do
    {:ok, socket} = :gen_tcp.accept(listen)
    _ = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.send(socket, response(kind))
    :gen_tcp.close(socket)
    accept(listen, kind)
  end

  defp response(:html),
    do:
      "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: 13\r\nconnection: close\r\n\r\n<html></html>"

  defp response(:redirect),
    do: "HTTP/1.1 302 Found\r\nlocation: /login\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"

  defp response(:json),
    do:
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"

  defp response(:empty), do: "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n"
  defp response(:none), do: "SSH-2.0-OpenSSH_9.0\r\n"
end
