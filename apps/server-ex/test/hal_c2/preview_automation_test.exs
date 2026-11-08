defmodule HalC2.PreviewAutomationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!(HalC2.PreviewAutomation)
    :ok
  end

  @caller %{thread_id: "th-1", instance: "codex"}
  @png Base.encode64(<<137, 80, 78, 71>>)

  # A desktop host: registers, then answers requests with `answer`.
  defp host(client_id, operations \\ nil) do
    host = %{"clientId" => client_id, "environmentId" => "env"}
    host = if operations, do: Map.put(host, "supportedOperations", operations), else: host
    {:ok, connection_id} = HalC2.PreviewAutomation.connect(host, self())
    assert_receive {:hal_c2_preview_automation, _, ^client_id, %{"type" => "connected"}}
    connection_id
  end

  defp next_request(client_id) do
    assert_receive {:hal_c2_preview_automation, _, ^client_id,
                    %{"type" => "request", "connectionId" => connection_id, "request" => request}}

    {connection_id, request}
  end

  defp answer(client_id, connection_id, request, result) do
    HalC2.PreviewAutomation.respond(%{
      "clientId" => client_id,
      "connectionId" => connection_id,
      "requestId" => request["requestId"],
      "ok" => true,
      "result" => result
    })
  end

  test "an agent's click reaches the host on the tab it read, which stays its current tab" do
    host("desk")

    # A first read with no tab of its own: the desktop says which tab it read.
    call = Task.async(fn -> HalC2.PreviewAutomation.invoke(@caller, "status", %{}) end)
    {connection_id, request} = next_request("desk")
    refute Map.has_key?(request, "tabId")
    answer("desk", connection_id, request, %{"tabId" => "tab-1"})
    assert {:ok, _} = Task.await(call)

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call("preview_click", %{"locator" => "#go"}, @caller)
      end)

    {connection_id, request} = next_request("desk")

    assert %{
             "operation" => "click",
             "input" => %{"locator" => "#go"},
             "threadId" => "th-1",
             "tabId" => "tab-1",
             "tabIdExplicit" => false
           } = request

    answer("desk", connection_id, request, %{"tabId" => "tab-1", "clicked" => true})

    # The follow-up status read names the page for the tool's icon.
    {_, status} = next_request("desk")
    assert %{"operation" => "status", "tabId" => "tab-1", "tabIdExplicit" => true} = status
    answer("desk", connection_id, status, %{"url" => "http://localhost:5173/"})

    assert {:ok, %{"clicked" => true, "toolIcon" => %{"pageUrl" => "http://localhost:5173/"}}} =
             Task.await(call)

    # The next call without a tab goes to that tab.
    call = Task.async(fn -> HalC2.Mcp.Preview.call("preview_status", %{}, @caller) end)
    {_, request} = next_request("desk")
    assert %{"tabId" => "tab-1", "tabIdExplicit" => false} = request
    answer("desk", connection_id, request, %{"url" => "about:blank"})
    assert {:ok, %{"url" => "about:blank"}} = Task.await(call)
  end

  test "preview_open refuses addresses a tab cannot show, before any host is asked" do
    assert {:error, "PreviewAutomationInvalidInputError", message} =
             HalC2.Mcp.Preview.call("preview_open", %{"url" => "about:blank"}, @caller)

    assert message =~ "protocol \"about:\" is unsupported"
    assert message =~ "Omit the address to open a blank tab"

    assert {:error, "PreviewAutomationInvalidInputError", message} =
             HalC2.Mcp.Preview.call("preview_open", %{"url" => "mailto:a@example.com"}, @caller)

    assert message =~ "protocol \"mailto:\" is unsupported"
  end

  test "preview_open sends a dev-server target on, over an address, and adds a scheme" do
    host("desk")

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call(
          "preview_open",
          %{
            "target" => %{"kind" => "environment-port", "port" => 6381},
            "url" => "http://localhost:3000"
          },
          @caller
        )
      end)

    {connection_id, request} = next_request("desk")
    assert request["input"]["target"] == %{"kind" => "environment-port", "port" => 6381}
    refute Map.has_key?(request["input"], "url")
    answer("desk", connection_id, request, %{"tabId" => "tab-1"})
    assert {:ok, _} = Task.await(call)

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call("preview_open", %{"url" => "localhost:3000"}, @caller)
      end)

    {_, request} = next_request("desk")
    assert request["input"]["url"] == "http://localhost:3000"
    answer("desk", connection_id, request, %{"tabId" => "tab-1"})
    assert {:ok, _} = Task.await(call)
  end

  test "preview_open reads a scheme only at the start, and a bracketed IPv6 loopback is http" do
    connection_id = host("desk")

    for {given, sent} <- [
          {"localhost:3000/login?next=http://example.com/",
           "http://localhost:3000/login?next=http://example.com/"},
          {"[::1]:3000", "http://[::1]:3000"}
        ] do
      call =
        Task.async(fn ->
          HalC2.Mcp.Preview.call("preview_open", %{"url" => given}, @caller)
        end)

      {_, request} = next_request("desk")
      assert request["input"]["url"] == sent
      answer("desk", connection_id, request, %{"tabId" => "tab-1"})
      assert {:ok, _} = Task.await(call)
    end
  end

  test "a snapshot leaves its screenshot out unless the agent asks for it" do
    host("desk")

    snapshot = %{
      "url" => "https://example.com/",
      "title" => "Example",
      "visibleText" => "hello",
      "interactiveElements" => [],
      "consoleEntries" => [],
      "networkEntries" => [],
      "actionTimeline" => [],
      "screenshot" => %{"mimeType" => "image/png", "data" => @png, "width" => 1, "height" => 1}
    }

    call = Task.async(fn -> HalC2.Mcp.Preview.call("preview_snapshot", %{}, @caller) end)
    {connection_id, request} = next_request("desk")
    answer("desk", connection_id, request, snapshot)
    assert {:ok, _metadata, content} = Task.await(call)
    assert Enum.filter(content, &(&1["type"] == "image")) == []

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call("preview_snapshot", %{"save" => true}, @caller)
      end)

    {_, request} = next_request("desk")
    answer("desk", connection_id, request, snapshot)

    assert {:ok, %{"url" => "https://example.com/", "screenshotPath" => path}, content} =
             Task.await(call)

    assert File.read!(path) == Base.decode64!(@png)
    assert [%{"text" => _url}, %{"text" => note}] = content
    assert note =~ path
  end

  test "without a host, or with one that cannot do it, the agent is told" do
    assert {:error, "PreviewAutomationNoAvailableHostError", message} =
             HalC2.Mcp.Preview.call("preview_status", %{}, @caller)

    assert message =~ "desktop app"

    host("old", ~w(status))

    assert {:error, "PreviewAutomationNoAvailableHostError", _} =
             HalC2.Mcp.Preview.call("preview_resize", %{"mode" => "fill"}, @caller)
  end

  # An open the host answers as the desktop does: `tab`, or a new tab of the
  # thread made with `preview.open`.
  defp open(client_id, opts, tab \\ :new) do
    call = Task.async(fn -> HalC2.PreviewAutomation.invoke(@caller, "open", %{}, opts) end)
    {connection_id, request} = next_request(client_id)

    tab =
      if tab == :new,
        do: elem(HalC2.Preview.open(%{"threadId" => "th-1"}), 1)["tabId"],
        else: tab

    answer(client_id, connection_id, request, %{"tabId" => tab})
    assert {:ok, %{"tabId" => ^tab}} = Task.await(call)
    {connection_id, request, tab}
  end

  # Regression: ownership lived on the host's session assignment, so the
  # eviction of a timed-out host cost the agent its own tab.
  test "a tab the agent opened stays its own after its host is dropped and registers again" do
    start_supervised!(HalC2.Preview)
    host("desk")
    {_, _, tab} = open("desk", [])
    assert HalC2.PreviewAutomation.tab_ownership(@caller, tab) == :own

    call = Task.async(fn -> HalC2.PreviewAutomation.invoke(@caller, "click", %{}) end)
    {_, request} = next_request("desk")
    send(Process.whereis(HalC2.PreviewAutomation), {:timeout, request["requestId"]})
    assert {:error, %{"_tag" => "PreviewAutomationTimeoutError"}} = Task.await(call)
    assert_receive {:hal_c2_preview_automation, _, "desk", :end}

    host("desk")
    assert HalC2.PreviewAutomation.tab_ownership(@caller, tab) == :own
  end

  # Regression: every open claimed the tab it landed on, the user's included.
  test "an open that reuses the user's tab, named or current, does not make it the agent's" do
    start_supervised!(HalC2.Preview)
    host("desk")
    {:ok, %{"tabId" => user_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})

    {_, request, _} = open("desk", [tab_id: user_tab], user_tab)
    assert request["tabIdExplicit"]
    assert HalC2.PreviewAutomation.tab_ownership(@caller, user_tab) == :not_agent

    # Now the session's current tab, which an open without a tab reuses.
    {_, request, _} = open("desk", [], user_tab)
    assert %{"tabId" => ^user_tab, "tabIdExplicit" => false} = request
    assert HalC2.PreviewAutomation.tab_ownership(@caller, user_tab) == :not_agent
  end

  # Regression: two sessions of a thread opening at once both saw the new tab
  # as absent before and present after, and the later reply took it.
  test "of two sessions opening at once on one thread, the one whose open made the tab keeps it" do
    start_supervised!(HalC2.Preview)
    host("desk")
    other = %{@caller | instance: "claude"}

    first = Task.async(fn -> HalC2.PreviewAutomation.invoke(@caller, "open", %{}, []) end)
    {connection_id, request} = next_request("desk")
    second = Task.async(fn -> HalC2.PreviewAutomation.invoke(other, "open", %{}, []) end)
    {_, other_request} = next_request("desk")

    {:ok, %{"tabId" => tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})
    answer("desk", connection_id, request, %{"tabId" => tab})
    assert {:ok, _} = Task.await(first)
    answer("desk", connection_id, other_request, %{"tabId" => tab})
    assert {:ok, _} = Task.await(second)

    assert HalC2.PreviewAutomation.tab_ownership(@caller, tab) == :own
    assert HalC2.PreviewAutomation.tab_ownership(other, tab) == :other_agent
  end

  defp report(client_id, connection_id, fields) do
    HalC2.PreviewAutomation.focus_host(
      Map.merge(fields, %{
        "clientId" => client_id,
        "environmentId" => "env",
        "connectionId" => connection_id,
        "focused" => true
      })
    )
  end

  test "a tab a person is using or another session opened is read, never changed" do
    start_supervised!(HalC2.Preview)
    connection_id = host("desk")
    other = %{@caller | instance: "claude"}
    {:ok, %{"tabId" => user_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})
    report("desk", connection_id, %{"controlledTabIds" => [user_tab]})

    assert {:error, %{"_tag" => "PreviewAutomationTabInUseError", "tabId" => ^user_tab}} =
             HalC2.PreviewAutomation.invoke(@caller, "click", %{}, tab_id: user_tab)

    call =
      Task.async(fn ->
        HalC2.PreviewAutomation.invoke(@caller, "snapshot", %{}, tab_id: user_tab)
      end)

    {_, request} = next_request("desk")
    answer("desk", connection_id, request, %{"tabId" => user_tab})
    assert {:ok, _} = Task.await(call)

    {_, _, mine} = open("desk", [])

    assert {:error, %{"_tag" => "PreviewAutomationTabOtherAgentError", "tabId" => ^mine}} =
             HalC2.PreviewAutomation.invoke(other, "type", %{}, tab_id: mine)
  end

  # Regression (found by the property): an open naming no tab reused the
  # current tab a read had made the user's, and was refused as in use.
  test "an open after reading a tab a person is now using makes a new tab" do
    start_supervised!(HalC2.Preview)
    connection_id = host("desk")
    {:ok, %{"tabId" => user_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})

    call =
      Task.async(fn ->
        HalC2.PreviewAutomation.invoke(@caller, "status", %{}, tab_id: user_tab)
      end)

    {_, request} = next_request("desk")
    answer("desk", connection_id, request, %{"tabId" => user_tab})
    assert {:ok, _} = Task.await(call)
    report("desk", connection_id, %{"controlledTabIds" => [user_tab]})

    {_, request, tab} = open("desk", [])
    refute Map.has_key?(request, "tabId")
    assert request["input"]["reuseExistingTab"] == false
    assert tab != user_tab
    assert HalC2.PreviewAutomation.tab_ownership(@caller, tab) == :own
  end

  # The host's answer to an open whose page failed to load, on `tab`.
  defp refuse(client_id, connection_id, request, tab) do
    HalC2.PreviewAutomation.respond(%{
      "clientId" => client_id,
      "connectionId" => connection_id,
      "requestId" => request["requestId"],
      "ok" => false,
      "error" => %{
        "_tag" => "PreviewAutomationNavigationError",
        "message" => "net::ERR_CONNECTION_REFUSED",
        "tabId" => tab
      }
    })
  end

  defp tabs(thread) do
    {:ok, %{"sessions" => sessions}} = HalC2.Preview.list(%{"threadId" => thread})
    Enum.map(sessions, & &1["tabId"])
  end

  test "a failed open closes the tab it made, never one it reused" do
    start_supervised!(HalC2.Preview)
    connection_id = host("desk")
    {:ok, %{"tabId" => user_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})

    call = Task.async(fn -> HalC2.PreviewAutomation.invoke(@caller, "open", %{}, []) end)
    {_, request} = next_request("desk")
    {:ok, %{"tabId" => made}} = HalC2.Preview.open(%{"threadId" => "th-1"})
    refuse("desk", connection_id, request, made)
    assert {:error, %{"remoteMessage" => "net::ERR_CONNECTION_REFUSED"}} = Task.await(call)
    assert tabs("th-1") == [user_tab]

    call =
      Task.async(fn ->
        HalC2.PreviewAutomation.invoke(@caller, "open", %{}, tab_id: user_tab)
      end)

    {_, request} = next_request("desk")
    refuse("desk", connection_id, request, user_tab)
    assert {:error, _} = Task.await(call)
    assert tabs("th-1") == [user_tab]

    {_, _, tab} = open("desk", [])
    assert HalC2.PreviewAutomation.tab_ownership(@caller, tab) == :own
  end

  # Regression (review of #1311): a session with no tab sent its change with no
  # tab, and the desktop filled it with its own current tab of the thread,
  # which another session's open had made.
  test "a session with no tab never changes the desktop's current tab, and opens its own" do
    start_supervised!(HalC2.Preview)
    host("desk")
    other = %{@caller | instance: "claude"}

    call = Task.async(fn -> HalC2.PreviewAutomation.invoke(other, "open", %{}, []) end)
    {connection_id, request} = next_request("desk")
    {:ok, %{"tabId" => theirs}} = HalC2.Preview.open(%{"threadId" => "th-1"})
    answer("desk", connection_id, request, %{"tabId" => theirs})
    assert {:ok, _} = Task.await(call)

    for op <- ~w(click type press scroll navigate evaluate) do
      assert {:error, %{"_tag" => "PreviewAutomationTabNotFoundError", "operation" => ^op}} =
               HalC2.PreviewAutomation.invoke(@caller, op, %{})
    end

    refute_received {:hal_c2_preview_automation, _, "desk", %{"type" => "request"}}

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call("preview_open", %{"url" => "http://localhost:5173/"}, @caller)
      end)

    {connection_id, request} = next_request("desk")
    refute Map.has_key?(request, "tabId")
    assert request["input"]["reuseExistingTab"] == false
    {:ok, %{"tabId" => mine}} = HalC2.Preview.open(%{"threadId" => "th-1"})
    answer("desk", connection_id, request, %{"tabId" => mine})
    assert {:ok, %{"tabId" => ^mine}} = Task.await(call)
    assert HalC2.PreviewAutomation.tab_ownership(@caller, mine) == :own
    assert HalC2.PreviewAutomation.tab_ownership(other, theirs) == :own
  end

  # Regression (review of #1311): a failed open closed every new tab of the
  # thread no agent owned yet, a person's and another open's on its way too.
  test "a failed open closes only the tab it made, not a person's or a racing open's" do
    start_supervised!(HalC2.Preview)
    connection_id = host("desk")
    other = %{@caller | instance: "claude"}

    first = Task.async(fn -> HalC2.PreviewAutomation.invoke(@caller, "open", %{}, []) end)
    {_, first_request} = next_request("desk")
    {:ok, %{"tabId" => first_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})

    second = Task.async(fn -> HalC2.PreviewAutomation.invoke(other, "open", %{}, []) end)
    {_, second_request} = next_request("desk")
    {:ok, %{"tabId" => second_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})
    {:ok, %{"tabId" => person_tab}} = HalC2.Preview.open(%{"threadId" => "th-1"})

    refuse("desk", connection_id, second_request, second_tab)
    assert {:error, _} = Task.await(second)
    assert Enum.sort(tabs("th-1")) == Enum.sort([first_tab, person_tab])

    answer("desk", connection_id, first_request, %{"tabId" => first_tab})
    assert {:ok, _} = Task.await(first)
    assert HalC2.PreviewAutomation.tab_ownership(@caller, first_tab) == :own
    assert HalC2.PreviewAutomation.tab_ownership(@caller, person_tab) == :not_agent
  end

  test "a session's new-tab open on its way leaves its previous tab free" do
    start_supervised!(HalC2.Preview)
    connection_id = host("desk")
    {_, _, tab} = open("desk", [])

    call =
      Task.async(fn ->
        HalC2.PreviewAutomation.invoke(@caller, "open", %{"reuseExistingTab" => false}, [])
      end)

    {_, request} = next_request("desk")
    assert %{^tab => %{in_use: nil}} = HalC2.PreviewAutomation.tab_states(@caller, [tab])
    answer("desk", connection_id, request, %{"tabId" => "tab-new"})
    assert {:ok, _} = Task.await(call)
  end

  test "at the MC's limit, an idle tab that will not close still counts and the open is refused" do
    Application.put_env(:hal_c2, :preview_tab_limits, mc: 1)
    on_exit(fn -> Application.delete_env(:hal_c2, :preview_tab_limits) end)
    start_supervised!(HalC2.Preview)
    host("desk")
    {_, _, tab} = open("desk", [])

    :sys.replace_state(HalC2.PreviewAutomation, fn state ->
      update_in(state, [:used, tab], fn {at, n} -> {at - 31 * 60_000, n} end)
    end)

    stop_supervised!(HalC2.Preview)

    assert {:error, %{"_tag" => "PreviewAutomationTabLimitError", "within" => "mc"}} =
             HalC2.PreviewAutomation.invoke(@caller, "open", %{"reuseExistingTab" => false}, [])

    assert HalC2.PreviewAutomation.tab_ownership(@caller, tab) == :own
  end

  test "an open names a reported profile by name or id in any case, or the host's default" do
    start_supervised!(HalC2.Preview)
    work = %{"id" => "work", "name" => "Work", "kind" => "persistent"}
    default = %{"id" => "default", "name" => "Default", "kind" => "persistent"}
    desk = host("desk")

    report("desk", desk, %{"browserProfiles" => [default], "defaultBrowserProfileId" => "default"})

    laptop = host("laptop")
    report("laptop", laptop, %{"browserProfiles" => [default, work]})
    # The focused desk would take a session that names no profile.
    report("desk", desk, %{})

    call =
      Task.async(fn ->
        HalC2.PreviewAutomation.invoke(@caller, "open", %{"profile" => "WORK"}, [])
      end)

    {connection_id, request} = next_request("laptop")
    assert request["input"] == %{"profileId" => "work", "reuseExistingTab" => false}
    answer("laptop", connection_id, request, %{"tabId" => "tab-w"})
    assert {:ok, _} = Task.await(call)

    other = %{@caller | thread_id: "th-2"}
    call = Task.async(fn -> HalC2.PreviewAutomation.invoke(other, "open", %{}, []) end)
    {connection_id, request} = next_request("desk")
    assert request["input"] == %{"profileId" => "default", "reuseExistingTab" => false}
    answer("desk", connection_id, request, %{"tabId" => "tab-d"})
    assert {:ok, _} = Task.await(call)

    assert {:error, %{"_tag" => "PreviewAutomationUnknownProfileError"} = error} =
             HalC2.PreviewAutomation.invoke(@caller, "open", %{"profile" => "Personal"}, [])

    assert HalC2.PreviewAutomation.message(error) ==
             "There is no browser profile named \"Personal\". Use one of: Default, Work."
  end

  test "an unanswered request fails and drops the host, whose stream ends" do
    host("desk")

    assert {:error, "PreviewAutomationTimeoutError", _} =
             HalC2.Mcp.Preview.call(
               "preview_wait_for",
               %{"text" => "x", "timeoutMs" => 50},
               @caller
             )

    assert_receive {:hal_c2_preview_automation, _, "desk", :end}

    assert {:error, "PreviewAutomationNoAvailableHostError", _} =
             HalC2.Mcp.Preview.call("preview_status", %{}, @caller)
  end

  test "a snapshot is bounded JSON plus the screenshot, and can be saved" do
    host("desk")

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call(
          "preview_snapshot",
          %{"save" => true, "includeImage" => true},
          @caller
        )
      end)

    {connection_id, request} = next_request("desk")
    assert request["input"] == %{}

    answer("desk", connection_id, request, %{
      "url" => "https://example.com/a",
      "title" => "Example",
      "visibleText" => String.duplicate("x", 9_000),
      "interactiveElements" => [%{"name" => "Go", "locator" => "#go"}],
      "consoleEntries" => for(i <- 1..50, do: %{"level" => "log", "text" => "line #{i}"}),
      "networkEntries" => [],
      "actionTimeline" => [],
      "accessibilityTree" => %{"role" => "document"},
      "screenshot" => %{"mimeType" => "image/png", "data" => @png, "width" => 10, "height" => 10}
    })

    assert {:ok, metadata, [_url, %{"text" => text}, %{"text" => note}, image]} = Task.await(call)
    assert File.read!(metadata["screenshotPath"]) == Base.decode64!(@png)
    assert metadata["screenshotPath"] =~ "browser-screenshot-example-com-"
    refute Map.has_key?(metadata["screenshot"], "data")
    assert image == %{"type" => "image", "data" => @png, "mimeType" => "image/png"}

    sent = JSON.decode!(text)
    refute Map.has_key?(sent, "accessibilityTree")
    assert length(sent["consoleEntries"]) == 40
    assert String.length(sent["visibleText"]) == 8_001
    assert note =~ "10 older console entries"
  end
end
