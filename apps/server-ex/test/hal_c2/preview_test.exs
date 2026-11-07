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

    assert_receive {:hal_c2_preview, _, %{"type" => "opened", "revision" => 1}}

    {:ok, snapshot} =
      HalC2.Preview.navigate(%{
        "threadId" => "t1",
        "tabId" => tab,
        "url" => "http://localhost:5173/a"
      })

    assert %{"navStatus" => %{"_tag" => "Success", "url" => "http://localhost:5173/a"}} = snapshot
    assert_receive {:hal_c2_preview, _, %{"type" => "navigated", "revision" => 2}}

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

    assert_receive {:hal_c2_preview, _, %{"type" => "failed", "code" => -102}}

    assert {:ok, %{"sessions" => [%{"canGoBack" => true}], "revision" => 3}} =
             HalC2.Preview.list(%{"threadId" => "t1"})

    {:ok, nil} = HalC2.Preview.close(%{"threadId" => "t1"})
    assert_receive {:hal_c2_preview, _, %{"type" => "closed", "tabId" => ^tab}}
    assert {:ok, %{"sessions" => []}} = HalC2.Preview.list(%{"threadId" => "t1"})
  end

  test "an unknown tab is a lookup error" do
    assert {:error, %{"_tag" => "PreviewSessionLookupError"}} =
             HalC2.Preview.refresh(%{"threadId" => "t1", "tabId" => "nope"})
  end

  test "an address or viewport outside the limits is refused without opening a tab" do
    secret = "https://user:password@example.com:bad/path?access_token=secret#fragment"

    assert {:error, %{"_tag" => "PreviewInvalidUrlError", "reason" => "parse"} = error} =
             HalC2.Preview.open(%{"threadId" => "t1", "url" => secret})

    refute inspect(error) =~ "password"
    assert error["inputLength"] == String.length(secret)

    for {url, reason} <- [
          {"   ", "empty"},
          {"ftp://example.com/file", "unsupported-protocol"},
          {"http://localhost/" <> String.duplicate("a", 2_048), "too-long"}
        ] do
      assert {:error, %{"reason" => ^reason}} =
               HalC2.Preview.open(%{"threadId" => "t1", "url" => url})
    end

    for {w, h} <- [{239, 800}, {800, 239}, {3_841, 800}, {3_840, 2_161}] do
      viewport = %{"_tag" => "freeform", "width" => w, "height" => h}

      assert {:error, %{"_tag" => "PreviewInvalidInputError", "field" => "viewport"}} =
               HalC2.Preview.open(%{"threadId" => "t1", "viewport" => viewport})
    end

    assert {:ok, %{"sessions" => []}} = HalC2.Preview.list(%{"threadId" => "t1"})

    edge = %{"_tag" => "freeform", "width" => 3_840, "height" => 2_160}

    assert {:ok, %{"viewport" => ^edge}} =
             HalC2.Preview.open(%{"threadId" => "t1", "viewport" => edge})
  end
end
