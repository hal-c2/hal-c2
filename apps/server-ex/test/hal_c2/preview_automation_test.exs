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

  test "an agent's click reaches the host, and the tab it lands on stays its current tab" do
    host("desk")

    call =
      Task.async(fn ->
        HalC2.Mcp.Preview.call("preview_click", %{"locator" => "#go"}, @caller)
      end)

    {connection_id, request} = next_request("desk")

    assert %{"operation" => "click", "input" => %{"locator" => "#go"}, "threadId" => "th-1"} =
             request

    refute Map.has_key?(request, "tabId")
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
