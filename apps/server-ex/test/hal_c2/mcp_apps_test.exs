defmodule HalC2.McpAppsTest do
  use ExUnit.Case, async: false

  alias HalC2.McpApps

  @moduletag :tmp_dir
  @mime "text/html;profile=mcp-app"
  @uri "ui://weather/forecast.html"

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :ok
  end

  defp snapshot(contents), do: McpApps.snapshot("th-1", "weather", "get_forecast", @uri, contents)
  defp stored(%{"attachmentId" => id}), do: File.read!(HalC2.Attachments.path(%{"id" => id}))

  test "stores the app document with its policy after the doctype, ahead of its scripts" do
    html = "<!DOCTYPE html><html><script>run()</script></html>"
    app = snapshot([%{"uri" => @uri, "mimeType" => @mime, "text" => html}])

    assert %{"server" => "weather", "tool" => "get_forecast", "resourceUri" => @uri} = app
    assert app["attachmentId"] =~ "-mcp-app-"
    assert McpApps.document_id?(app["attachmentId"])

    assert "<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" <>
             _ = stored(app)

    assert stored(app) =~ "connect-src 'none'"
    assert String.ends_with?(stored(app), "<html><script>run()</script></html>")
  end

  test "keeps only scheme-qualified origins and the permissions the spec names" do
    ui = %{
      "csp" => %{
        "connectDomains" => [
          "https://api.example",
          "*.example",
          "javascript:x",
          "https://x; script-src *"
        ],
        "resourceDomains" => ["https://*.cdn.example:8443"],
        "frameDomains" => "https://not-a-list.example"
      },
      "permissions" => %{"camera" => %{}, "telepathy" => %{}, "microphone" => true},
      "prefersBorder" => false
    }

    app = snapshot([%{"mimeType" => @mime, "text" => "<p>hi</p>", "_meta" => %{"ui" => ui}}])

    assert app["csp"] == %{
             "connectDomains" => ["https://api.example"],
             "resourceDomains" => ["https://*.cdn.example:8443"]
           }

    assert app["permissions"] == %{"camera" => %{}}
    assert app["prefersBorder"] == false
    # No doctype: one goes first, so the document is in standards mode, then the policy.
    assert "<!doctype html><meta http-equiv=\"Content-Security-Policy\"" <> _ = stored(app)
    assert stored(app) =~ "script-src 'unsafe-inline' https://*.cdn.example:8443"
  end

  test "decodes a base64 blob, and stores nothing that is not an app document" do
    blob = Base.encode64("<p>from a blob</p>")

    assert stored(snapshot([%{"mimeType" => "text/html; profile=mcp-app", "blob" => blob}])) =~
             "from a blob"

    assert snapshot([%{"mimeType" => "text/html", "text" => "<p>plain html</p>"}]) == nil

    assert snapshot([%{"uri" => "ui://other", "mimeType" => @mime, "text" => "<p>other</p>"}]) ==
             nil

    assert snapshot([%{"mimeType" => @mime, "text" => "  "}]) == nil
    assert snapshot([%{"mimeType" => @mime, "blob" => Base.encode64(<<255, 254>>)}]) == nil

    assert McpApps.snapshot("th-1", "weather", "t", "https://x", [
             %{"mimeType" => @mime, "text" => "x"}
           ]) == nil
  end

  test "stores no document over 5 MiB" do
    big = String.duplicate("a", 5 * 1024 * 1024 + 1)
    assert snapshot([%{"mimeType" => @mime, "text" => big}]) == nil
  end

  test "serves the document with the theme and cookie scripts after its policy" do
    app = snapshot([%{"mimeType" => @mime, "text" => "<!doctype html><script>app()</script>"}])
    served = McpApps.serve_document(stored(app))

    [policy, theme, cookie, own] =
      for text <- [
            "Content-Security-Policy",
            "host-context-changed",
            ~s(defineProperty(document,"cookie"),
            "app()"
          ],
          do: served |> :binary.match(text) |> elem(0)

    assert policy < theme and theme < cookie and cookie < own

    assert {"content-security-policy", "sandbox allow-scripts" <> rest} =
             List.keyfind(McpApps.serve_headers(), "content-security-policy", 0)

    refute rest =~ "allow-same-origin"
  end

  test "cuts what an app tells the model at a character boundary" do
    assert McpApps.cut("short") == "short"
    cut = McpApps.cut(String.duplicate("€", 6000))
    assert byte_size(cut) == 16_383 and String.valid?(cut)
    assert McpApps.cut("ééé", 3) == "é"
  end
end
