defmodule HalC2.Steps.Preview.Surfaces do
  @moduledoc """
  Steps for `features/preview/surfaces.feature`: the MC's browser tabs
  (`preview.*` RPCs and the `preview` shape) and its local server suggestions
  (the `localServers` shape).

  The acting client is the default socket; a second socket, `"watcher"`, watches
  the `preview` shape so every change can be checked as other clients see it.
  Local servers are real listeners in this VM on free ports; a feature's port
  number names one (`context.ports`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

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
    watcher = Mc.refute_frame(World.client(context, "watcher"), &(&1["t"] == "preview"))
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

  step "the list carries the MC's run and change numbers", context do
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

  step "the MC reports a different run number so clients drop their old tabs", context do
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

  step "a client opens a browser tab for the thread at the {string} preset",
       %{args: [preset]} = context do
    viewport = preset(preset)
    context = open(context, %{"viewport" => viewport})
    Map.put(context, :requested, viewport)
  end

  step "the tab's viewport is the {string} preset from the start", %{args: [preset]} = context do
    assert listed(context, context.tab)["viewport"] == preset(preset)
    assert context.requested == preset(preset)

    # Nothing resized it: the only change on record is the tab opening.
    {events, context} = event(context, fn _ -> true end, :all)
    assert [%{"type" => "opened", "snapshot" => %{"viewport" => viewport}}] = events
    assert viewport == preset(preset)
    context
  end

  step "a browser tab under the profile {string} resized to {int} by {int}",
       %{args: [profile, width, height]} = context do
    context = open(context, %{"profileId" => profile})

    {reply, context} =
      rpc(context, "preview.resize", %{
        "tabId" => context.tab,
        "viewport" => freeform(width, height)
      })

    assert {:ok, _} = reply
    drain(context)
  end

  step "the desktop reports it navigated to {string}", %{args: [url]} = context do
    navigate(context, %{"url" => url})
  end

  step "the desktop reports its status as loaded", context do
    snapshot = listed(context, context.tab)

    report(context, %{
      "navStatus" => %{
        "_tag" => "Success",
        "url" => snapshot["navStatus"]["url"],
        "title" => "Resized"
      },
      "canGoBack" => true,
      "canGoForward" => false
    })
  end

  step "the tab still has the profile {string}", %{args: [profile]} = context do
    assert listed(context, context.tab)["profileId"] == profile
    context
  end

  step "the tab still has the viewport {int} by {int}", %{args: [width, height]} = context do
    assert listed(context, context.tab)["viewport"] == freeform(width, height)
    context
  end

  step "a client closes a tab the thread does not have", context do
    context = open(context, %{"url" => "http://localhost:5173/"}) |> drain()
    context = Map.put(context, :others, sessions(context))
    {reply, context} = rpc(context, "preview.close", %{"tabId" => "tab-missing"})
    Map.put(context, :reply, reply)
  end

  step "a client closes the tabs of a thread that has none", context do
    context = open(context, %{"url" => "http://localhost:5173/"}) |> drain()
    context = Map.put(context, :others, sessions(context))
    {reply, context} = World.call(context, "preview.close", %{"threadId" => "th-no-tabs"})
    Map.put(context, :reply, reply)
  end

  step "no watching client is told anything", context do
    watcher = Mc.refute_frame(World.client(context, "watcher"), &(&1["t"] == "preview"))
    World.put_client(context, "watcher", watcher)
  end

  step "the thread's other tabs are unchanged", context do
    assert sessions(context) == context.others
    context
  end

  step "the client is told each tab closed", context do
    {events, context} = event(context, &(&1["type"] == "closed"), :all)

    assert Enum.sort(Enum.map(events, & &1["tabId"])) ==
             Enum.sort([context.first, context.second])

    Map.put(context, :closed, events)
  end

  step "the second event's change number is higher than the first's", context do
    assert [first, second] = context.closed
    assert second["revision"] > first["revision"]
    context
  end

  step "the list's change number is the second event's", context do
    {{:ok, list}, context} = rpc(context, "preview.list", %{})
    assert list["revision"] == List.last(context.closed)["revision"]
    context
  end

  step "a client resizes the tab to {int} by {int}", %{args: [width, height]} = context do
    {reply, context} =
      rpc(context, "preview.resize", %{
        "tabId" => context.tab,
        "viewport" => freeform(width, height)
      })

    Map.put(context, :reply, reply)
  end

  step "the MC refuses the resize", context do
    assert {:error, "PreviewInvalidInputError", %{"field" => "viewport"}} = context.reply
    context
  end

  step "the tab keeps its viewport", context do
    assert listed(context, context.tab)["viewport"] == %{"_tag" => "fill"}
    context
  end

  step "the tab's viewport is {int} by {int}", %{args: [width, height]} = context do
    assert {:ok, _} = context.reply
    assert listed(context, context.tab)["viewport"] == freeform(width, height)
    context
  end

  step "a client opens a browser tab at an address of {int} characters",
       %{args: [length]} = context do
    prefix = "http://localhost:5173/"
    open_refused(context, prefix <> String.duplicate("a", length - String.length(prefix)))
  end

  step "a client opens a browser tab at {string}", %{args: [address]} = context do
    open_refused(context, address)
  end

  step "no tab opens", context do
    assert {:error, _, _} = context.reply
    assert sessions(context) == []
    context
  end

  step "the client is told the address is too long", context do
    assert {:error, "PreviewInvalidUrlError", %{"reason" => "too-long"}} = context.reply
    context
  end

  step "the client is told the address cannot be opened", context do
    assert {:error, "PreviewInvalidUrlError", %{"reason" => "unsupported-protocol"}} =
             context.reply

    context
  end

  step "the error says why the address was refused and how long it was", context do
    assert {:error, "PreviewInvalidUrlError", detail} = context.reply
    assert detail["reason"] in ~w(empty parse)
    assert detail["inputLength"] == String.length(context.address)
    context
  end

  step "the error does not contain the address, its credentials, query or fragment", context do
    {:error, error, detail} = context.reply
    text = inspect({error, detail})

    for secret <- ~w(password access_token secret fragment user),
        String.contains?(context.address, secret) do
      refute text =~ secret
    end

    context
  end

  step "the desktop reports a navigation titled with {int} characters",
       %{args: [length]} = context do
    before = listed(context, context.tab)

    {reply, context} =
      rpc(context, "preview.navigate", %{
        "tabId" => context.tab,
        "url" => "http://localhost:5173/next",
        "resolvedTitle" => String.duplicate("t", length)
      })

    assert {:error, "PreviewInvalidInputError", %{"field" => "title"}} = reply
    Map.put(context, :before, before)
  end

  step "the tab keeps its previous page and title", context do
    assert listed(context, context.tab) == context.before
    context
  end

  step "a browser tab showing {string} whose load report is still on its way",
       %{args: [title]} = context do
    url = "http://localhost:5173/"

    context
    |> open(%{"url" => url})
    |> navigate(%{"url" => url, "resolvedTitle" => title})
    |> drain()
    |> Map.put(:left, url)
  end

  step "a navigation to {string} starts and fails with {string}",
       %{args: [url, code]} = context do
    context
    |> report(%{
      "navStatus" => %{"_tag" => "Loading", "url" => url, "title" => ""},
      "canGoBack" => false,
      "canGoForward" => false
    })
    |> report(%{
      "navStatus" => %{
        "_tag" => "LoadFailed",
        "url" => url,
        "title" => "",
        "code" => -102,
        "description" => code
      },
      "canGoBack" => false,
      "canGoForward" => false
    })
    |> Map.put(:failed_url, url)
  end

  step "the report for {string} then arrives", %{args: [title]} = context do
    report(context, %{
      "navStatus" => %{"_tag" => "Success", "url" => context.left, "title" => title},
      "canGoBack" => false,
      "canGoForward" => false
    })
  end

  step "every watching client is still told the tab failed with that error", context do
    {events, context} = event(context, nil, :all)
    mine = Enum.filter(events, &(&1["tabId"] == context.tab))
    assert Enum.any?(mine, &(&1["type"] == "failed"))
    # Nothing after the failure turned it into a success.
    assert [%{"type" => "failed"} | _] = Enum.reverse(mine)
    assert %{"_tag" => "LoadFailed", "url" => url} = listed(context, context.tab)["navStatus"]
    assert url == context.failed_url
    context
  end

  # --- a deleted thread's tabs -------------------------------------------------------

  step "the thread has browser tabs", context do
    context =
      context
      |> watcher()
      |> World.create_project("Preview project")
      |> World.create_thread("Preview thread", "Preview project")

    context = Map.put(context, :real_thread, World.thread_id(context, "Preview thread"))
    context = open(context, %{"url" => "http://localhost:5173/"})
    first = context.tab
    context = open(context, %{"url" => "http://localhost:5173/b"})
    assert length(sessions(context)) == 2
    Map.put(context, :tabs, [first, context.tab])
  end

  step "the thread is deleted", context do
    {reply, context} =
      World.dispatch(context, %{"type" => "thread.delete", "threadId" => context.real_thread})

    assert {:ok, _} = reply
    context
  end

  step "the thread's project is deleted", context do
    project = World.project(context, "Preview project")

    {reply, context} =
      World.call(context, "projects.mutate", %{
        "type" => "project.delete",
        "projectId" => project.id,
        "force" => true
      })

    assert {:ok, _} = reply
    context
  end

  step "every client is told they closed", context do
    {events, context} = event(context, nil, :all)

    closed =
      for %{"type" => "closed", "threadId" => thread, "tabId" => tab} <- events, do: {thread, tab}

    assert Enum.sort(closed) == Enum.sort(for tab <- context.tabs, do: {context.real_thread, tab})
    context
  end

  # --- local servers -------------------------------------------------------------------

  step "a dev server is serving HTML on port {int} of the MC's machine",
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

  step "a program listening on port {int} that redirects to {string}",
       %{args: [port, location]} = context do
    serve(context, port, {:redirect, location})
  end

  step "a program listening on port {int} that accepts connections and never answers",
       %{args: [port]} = context do
    context |> serve(:other, :html) |> serve(port, :silent)
  end

  step "a client watches for local servers", context do
    watch_servers(context)
  end

  step "the MC never asks {string} for anything", %{args: [host]} = context do
    # Following the redirect would be another request; the listener is asked only
    # for its own root, by its own address.
    requests = served()
    assert requests != []

    for request <- requests do
      assert request =~ ~r/^GET \/ HTTP/
      refute request =~ host
    end

    context
  end

  step "the other suggestions are not held up for longer than the probe takes", context do
    # The list arrived (the scan finished, so the probe of the silent port gave up
    # rather than holding it) and still carries the healthy listener.
    assert context.ports[:other] in Enum.map(context.servers, & &1["port"])
    context
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

  step "the MC's own port is not among the suggestions", context do
    # The MC's own port answers HTTP, so it would be a suggestion.
    refute context.mc.port in Enum.map(context.servers, & &1["port"])
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

    {_, client} = Mc.await(World.client(context), has?, 8_000)
    World.put_client(context, client)
  end

  step "the last client stops watching for local servers", context do
    context = watch_servers(context)
    client = World.client(context) |> Mc.unsub(@servers) |> ping()
    World.put_client(context, client)
  end

  step "the MC no longer scans for listening ports", context do
    pid = Process.whereis(HalC2.LocalServers)
    # The next scan tick, now rather than a few seconds from now.
    send(pid, :scan)
    state = :sys.get_state(pid)
    assert state.watchers == %{}
    assert state.timer == nil and state.base == nil
    context
  end

  step "the MC's machine cannot list listening ports", context do
    path = System.get_env("PATH")
    System.put_env("PATH", Mc.tmp_dir(context.mc, "empty-path"))
    ExUnit.Callbacks.on_exit(fn -> System.put_env("PATH", path) end)
    context
  end

  step "the suggestion list is empty", context do
    assert context.servers == []
    context
  end

  # --- HTTPS, the probe cache and configured addresses ---------------------------------

  step "a program listening on port {int} that answers an HTML page over HTTPS only",
       %{args: [port]} = context do
    serve(context, port, :html, tls: true)
  end

  step ~r/^"https:\/\/localhost:(?<port>\d+)" is suggested$/, %{args: [port]} = context do
    actual = context.ports[String.to_integer(port)]
    server = Enum.find(context.servers, &(&1["port"] == actual))
    assert server, "port #{actual} was not suggested: #{inspect(context.servers)}"
    assert server["url"] == "https://localhost:#{actual}"
    context
  end

  step "port {int} was probed and answered with an HTML page", %{args: [port]} = context do
    context |> serve(port, :html) |> watch_servers() |> tap(fn _ -> served() end)
  end

  step "the list is scanned again within fifteen seconds", context do
    scan_now(context)
  end

  step "the MC does not probe port {int} again", %{args: [_port]} = context do
    assert served() == []
    context
  end

  step "the list is scanned again after fifteen seconds", context do
    World.put_app_env(:local_servers_skew, 16_000)
    scan_now(context)
  end

  step "the MC probes port {int} again", %{args: [_port]} = context do
    assert served() != []
    context
  end

  step "a port that failed its probe is also probed again only after fifteen seconds",
       context do
    context = serve(context, :failing, :json)
    scan_now(context)
    assert served() != []
    scan_now(context)
    assert served() == []
    World.put_app_env(:local_servers_skew, 32_000)
    scan_now(context)
    assert served() != []
    context
  end

  step "a client names the configured address {string} when it watches for local servers",
       %{args: [url]} = context do
    name_addresses(context, "default", [url])
  end

  step "the address answers with an HTML page", context do
    [url | _] = context.configured["default"]
    serve_address(context, url, :html)
  end

  step "nothing answers there", context do
    # A port something held a moment ago and nothing holds now.
    [url | _] = context.configured["default"]
    port = url |> URI.parse() |> Map.fetch!(:port)
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, actual} = :inet.port(listen)
    :gen_tcp.close(listen)
    Map.update(context, :ports, %{port => actual}, &Map.put(&1, port, actual))
  end

  step "{string} is suggested with the path the project configured",
       %{args: [url]} = context do
    suggested(context, url)
  end

  step ~r/^"(?<url>[^"]+)" is suggested as written$/, %{args: [url]} = context do
    suggested(context, url)
  end

  step ~r/^"(?<url>http:\/\/localhost:\d+\/)" is suggested$/, %{args: [url]} = context do
    suggested(context, url)
  end

  step "{string} is not among the suggestions", %{args: [url]} = context do
    context = watched(context)
    refute url in suggested_urls(context)
    context
  end

  step "the MC does not probe {string}", %{args: [url]} = context do
    context = watched(context)

    refute Map.has_key?(
             :sys.get_state(HalC2.LocalServers).cache,
             {:url, actual_url(context, url)}
           )

    context
  end

  step "{string} answers 404 but {string} serves an HTML page",
       %{args: [root, page]} = context do
    %URI{path: path} = URI.parse(page)
    port = URI.parse(root).port
    context = serve(context, port, {:paths, %{path => :html}})
    context
  end

  step "a client names the configured address {string} followed by enough characters to reach the 2048 character limit",
       %{args: [url]} = context do
    long = String.pad_trailing(url, 2_048, "a")
    context = name_addresses(context, "default", [long])
    Map.put(context, :long, long)
  end

  step "the MC does not probe it", context do
    context = watched(context)

    refute Map.has_key?(:sys.get_state(HalC2.LocalServers).cache, {:url, context.long}),
           "the long address was probed"

    # Rewritten as localhost it is over the limit too.
    refute Enum.any?(
             Map.keys(:sys.get_state(HalC2.LocalServers).cache),
             &match?({:url, "http://localhost/" <> _}, &1)
           )

    context
  end

  step "the other configured addresses are probed as usual", context do
    other = "http://localhost:3000/"
    context = serve(context, 3000, :html)
    context = name_addresses(context, "default", [context.long, other])
    context = watch_servers(context)
    assert other in suggested_urls(context)
    context
  end

  step "one client names {string} and another names {string}",
       %{args: [first, second]} = context do
    context
    |> name_addresses("default", [first])
    |> name_addresses("second", [second])
  end

  step "both addresses answer with an HTML page", context do
    for name <- ["default", "second"], reduce: context do
      context -> serve_address(context, hd(context.configured[name]), :html)
    end
  end

  step "the first client is suggested {string} and not {string}",
       %{args: [yes, no]} = context do
    context = watched(context)
    assert Enum.any?(suggested_urls(context), &String.ends_with?(&1, yes))
    refute Enum.any?(suggested_urls(context), &String.ends_with?(&1, no))
    context
  end

  step "the second client is suggested {string} and not {string}",
       %{args: [yes, no]} = context do
    context = watched(context, "second")
    urls = suggested_urls(context, "second")
    assert Enum.any?(urls, &String.ends_with?(&1, yes))
    refute Enum.any?(urls, &String.ends_with?(&1, no))
    context
  end

  step "one client names 32 configured addresses", context do
    urls = for n <- 1..32, do: "http://localhost:#{8_000 + n}/"
    name_addresses(context, "default", urls)
  end

  step "another client names one more address that serves a page", context do
    context = name_addresses(context, "second", ["http://localhost:3000/"])
    serve_address(context, "http://localhost:3000/", :html)
  end

  step "the second client is still suggested its address", context do
    context = watched(context)
    context = watched(context, "second")
    assert "http://localhost:3000/" in suggested_urls(context, "second")
    context
  end

  step "two clients watching with different configured addresses", context do
    context
    |> name_addresses("default", ["http://localhost:3001/"])
    |> name_addresses("second", ["http://localhost:3002/"])
    |> watch_servers()
    |> watch_servers("second")
  end

  step "the first client stops watching", context do
    client = World.client(context) |> Mc.unsub(@servers) |> ping()
    World.put_client(context, client)
  end

  step "the MC keeps probing the second client's addresses", context do
    configured =
      :sys.get_state(HalC2.LocalServers).configured
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> List.flatten()

    assert Enum.any?(configured, &(&1 =~ ":3002"))
    context
  end

  step "the MC no longer probes the first client's addresses", context do
    configured =
      :sys.get_state(HalC2.LocalServers).configured
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> List.flatten()

    refute Enum.any?(configured, &(&1 =~ ":3001"))
    context
  end

  step "a client names 40 configured local addresses when it watches for local servers",
       context do
    urls = for n <- 1..40, do: "http://localhost:#{8_000 + n}/"
    name_addresses(context, "default", urls)
  end

  step "the MC probes only the first 32", context do
    context = watched(context)
    probed = for {:url, url} <- Map.keys(:sys.get_state(HalC2.LocalServers).cache), do: url
    assert length(probed) == 32
    assert Enum.sort(probed) == Enum.sort(for(n <- 1..32, do: "http://localhost:#{8_000 + n}/"))
    context
  end

  step "a dev server listens on port {int}", %{args: [port]} = context do
    serve(context, port, :html)
  end

  step "the server on port {int} is suggested once, with the configured address",
       %{args: [port]} = context do
    context = watched(context)
    urls = for url <- suggested_urls(context), url =~ ":#{port}", do: url
    assert urls == ["http://localhost:#{port}"]
    context
  end

  # --- helpers -------------------------------------------------------------------------

  # Names `urls` as `name`'s configured addresses; they are sent when it watches.
  defp name_addresses(context, name, urls) do
    configured = Map.get(context, :configured) || %{}
    Map.put(context, :configured, Map.put(configured, name, urls))
  end

  # A listener where the configured `url` points: its scheme and host family.
  defp serve_address(context, url, kind) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    serve(context, port, kind, tls: scheme == "https", family: if(host == "::1", do: :inet6))
  end

  defp suggested(context, url) do
    context = watched(context)
    assert url in suggested_urls(context), "#{url} not in #{inspect(suggested_urls(context))}"
    context
  end

  # A scan now, and the requests it made counted by `served/0`.
  defp scan_now(context) do
    pid = Process.whereis(HalC2.LocalServers)
    send(pid, :scan)
    :sys.get_state(pid)
    context
  end

  defp services(context) do
    Mc.ensure(HalC2.Preview)
    context
  end

  # The watcher socket, subscribed to tab changes before anything happens.
  defp watcher(context) do
    context = services(context)

    case context.clients["watcher"] do
      nil ->
        client =
          Mc.connect(context.mc)
          |> Mc.sub(@watch, %{"type" => "preview", "mc" => Atom.to_string(node())})
          |> ping()

        World.put_client(context, "watcher", client)

      _ ->
        context
    end
  end

  defp ping(client) do
    client = HalC2.Test.WsClient.send_json(client, %{"t" => "ping"})
    {_, client} = Mc.await(client, &(&1["t"] == "pong"))
    client
  end

  # The scenario's thread: a real one when it deletes its thread, else a stand-in.
  defp rpc(context, method, payload) do
    context = watcher(context)

    World.call(
      context,
      method,
      Map.put(payload, "threadId", Map.get(context, :real_thread, @thread))
    )
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
      :all ->
        {events, watcher} = ping(watcher, :collect)
        {events, World.put_client(context, "watcher", watcher)}

      :first ->
        {frame, watcher} = Mc.await(watcher, &(&1["t"] == "preview" and fun.(&1["event"])))
        {frame["event"], World.put_client(context, "watcher", watcher)}

      :last ->
        {events, watcher} = ping(watcher, :collect)
        {List.last(events), World.put_client(context, "watcher", watcher)}
    end
  end

  # Pings and collects every preview event that arrives before the pong.
  defp ping(client, :collect) do
    client = HalC2.Test.WsClient.send_json(client, %{"t" => "ping"})
    collect(client, [])
  end

  defp collect(client, acc) do
    {frame, client} = HalC2.Test.WsClient.recv(client, 2_000)

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

  defp preset("iphone-se"),
    do: %{"_tag" => "preset", "presetId" => "iphone-se", "width" => 375, "height" => 667}

  defp freeform(width, height), do: %{"_tag" => "freeform", "width" => width, "height" => height}

  defp open_refused(context, address) do
    {reply, context} = rpc(context, "preview.open", %{"url" => address})
    context |> Map.put(:reply, reply) |> Map.put(:address, address)
  end

  # The requests listeners have received since the last call.
  defp served(acc \\ []) do
    receive do
      {:served, request} -> served([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Watches as `name`, naming the scenario's configured addresses (`context.configured`,
  # the features' nominal ports mapped to the listeners' real ones).
  defp watch_servers(context, name \\ "default") do
    Mc.ensure(HalC2.LocalServers)
    context = if context[:seen][name], do: stop_watching(context, name), else: context

    client =
      case Map.get(context, :clients, %{})[name] do
        nil -> Mc.connect(context.mc)
        existing -> existing
      end

    configured = Map.get(context, :configured) || %{}
    urls = for url <- Map.get(configured, name, []), do: actual_url(context, url)

    client =
      Mc.sub(client, @servers, %{
        "type" => "localServers",
        "mc" => Atom.to_string(node()),
        "configuredUrls" => urls
      })

    {frame, client} = Mc.await_local_servers(client, @servers)

    servers = frame["list"]["servers"]
    context = World.put_client(context, name, client)
    context = Map.update(context, :seen, %{name => servers}, &Map.put(&1, name, servers))

    if name == "default", do: Map.put(context, :servers, servers), else: context
  end

  defp stop_watching(context, name) do
    client = World.client(context, name) |> Mc.unsub(@servers) |> ping()
    context |> World.put_client(name, client) |> Map.update!(:seen, &Map.delete(&1, name))
  end

  # The list `name` was told, watching first when it has not been.
  defp watched(context, name \\ "default") do
    if context[:seen][name], do: context, else: watch_servers(context, name)
  end

  # `url` with the nominal port of a feature replaced by the real one of its listener.
  defp actual_url(context, url) do
    Regex.replace(~r/^(\w+:\/\/(?:\[[^\]]*\]|[^\/:]+)):(\d+)/, url, fn whole, host, port ->
      case Map.get(context, :ports, %{})[String.to_integer(port)] do
        nil -> whole
        actual -> "#{host}:#{actual}"
      end
    end)
  end

  defp nominal_url(context, url) do
    Enum.reduce(Map.get(context, :ports, %{}), url, fn
      {nominal, actual}, url when is_integer(nominal) ->
        String.replace(url, ~r/:#{actual}(?=\/|$)/, ":#{nominal}")

      _, url ->
        url
    end)
  end

  defp suggested_urls(context, name \\ "default"),
    do: for(server <- context.seen[name], do: nominal_url(context, server["url"]))

  # A listener on a free loopback port answering every request as `kind`. `opts`:
  # `tls: true` speaks HTTPS, `family: :inet6` listens on ::1.
  defp serve(context, port, kind, opts \\ []) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        {listen, actual} = listen(opts, context)
        send(parent, {ref, actual})
        accept(listen, kind, parent, opts)
      end)

    actual =
      receive do
        {^ref, actual} -> actual
      after
        5_000 -> flunk("a listener did not start")
      end

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    Map.update(context, :ports, %{port => actual}, &Map.put(&1, port, actual))
  end

  defp listen(opts, context) do
    {ip, family} =
      case opts[:family] do
        :inet6 -> {{0, 0, 0, 0, 0, 0, 0, 1}, [:inet6]}
        _ -> {{127, 0, 0, 1}, []}
      end

    base = [:binary, ip: ip, active: false, reuseaddr: true] ++ family

    if opts[:tls] do
      {cert, key} = certificate(context)
      {:ok, listen} = :ssl.listen(0, base ++ [certfile: cert, keyfile: key])
      {:ok, {_, actual}} = :ssl.sockname(listen)
      {listen, actual}
    else
      {:ok, listen} = :gen_tcp.listen(0, base)
      {:ok, actual} = :inet.port(listen)
      {listen, actual}
    end
  end

  # A self-signed certificate for the scenario's HTTPS listeners.
  defp certificate(context) do
    dir = Mc.tmp_dir(context.mc, "tls")
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    unless File.exists?(cert) do
      {_, 0} =
        System.cmd(
          "openssl",
          ~w(req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 1 -keyout #{key} -out #{cert}),
          stderr_to_stdout: true
        )
    end

    {cert, key}
  end

  defp accept(listen, kind, parent, opts) do
    tls? = opts[:tls] == true

    accepted =
      if tls? do
        with {:ok, transport} <- :ssl.transport_accept(listen),
             {:ok, socket} <- :ssl.handshake(transport, 1_000) do
          {:ok, socket}
        else
          # A plain HTTP probe of an HTTPS listener fails its handshake.
          _ -> :retry
        end
      else
        :gen_tcp.accept(listen)
      end

    with {:ok, socket} <- accepted do
      recv = if tls?, do: &:ssl.recv/3, else: &:gen_tcp.recv/3
      send_ = if tls?, do: &:ssl.send/2, else: &:gen_tcp.send/2
      close = if tls?, do: &:ssl.close/1, else: &:gen_tcp.close/1

      request =
        case recv.(socket, 0, 1_000) do
          {:ok, request} ->
            send(parent, {:served, request})
            request

          _ ->
            ""
        end

      if kind == :silent do
        # Holds the connection open and says nothing.
        spawn(fn -> Process.sleep(:infinity) end)
      else
        send_.(socket, response(kind, request))
        close.(socket)
      end
    end

    accept(listen, kind, parent, opts)
  end

  defp response({:paths, pages}, request) do
    path = request |> String.split(" ", parts: 3) |> Enum.at(1)

    case pages[path] do
      nil -> "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      kind -> response(kind, request)
    end
  end

  defp response(kind, _request), do: response(kind)

  defp response({:redirect, location}),
    do:
      "HTTP/1.1 302 Found\r\nlocation: #{location}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"

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
