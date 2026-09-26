defmodule HalC2.PreviewTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(HalC2.Preview)
    :ok = HalC2.Preview.subscribe(self())
    :ok
  end

  test "a tab opens, navigates, fails, and closes, with an event for each" do
    {:ok, %{"tabId" => tab, "navStatus" => %{"_tag" => "Loading"}}} =
      HalC2.Preview.open(%{"threadId" => "t1", "url" => "http://localhost:5173/"})

    assert_receive {:halc2_preview, _, %{"type" => "opened", "revision" => 1}}

    {:ok, snapshot} =
      HalC2.Preview.navigate(%{
        "threadId" => "t1",
        "tabId" => tab,
        "url" => "http://localhost:5173/a"
      })

    assert %{"navStatus" => %{"_tag" => "Success", "url" => "http://localhost:5173/a"}} = snapshot
    assert_receive {:halc2_preview, _, %{"type" => "navigated", "revision" => 2}}

    failed = %{
      "_tag" => "LoadFailed",
      "url" => "http://localhost:5173/b",
      "title" => "",
      "code" => -102,
      "description" => "refused"
    }

    {:ok, nil} =
      HalC2.Preview.report_status(%{
        "threadId" => "t1",
        "tabId" => tab,
        "navStatus" => failed,
        "canGoBack" => true,
        "canGoForward" => false
      })

    assert_receive {:halc2_preview, _, %{"type" => "failed", "code" => -102}}

    assert {:ok, %{"sessions" => [%{"canGoBack" => true}], "revision" => 3}} =
             HalC2.Preview.list(%{"threadId" => "t1"})

    {:ok, nil} = HalC2.Preview.close(%{"threadId" => "t1"})
    assert_receive {:halc2_preview, _, %{"type" => "closed", "tabId" => ^tab}}
    assert {:ok, %{"sessions" => []}} = HalC2.Preview.list(%{"threadId" => "t1"})
  end

  test "an unknown tab is a lookup error" do
    assert {:error, %{"_tag" => "PreviewSessionLookupError"}} =
             HalC2.Preview.refresh(%{"threadId" => "t1", "tabId" => "nope"})
  end
end
