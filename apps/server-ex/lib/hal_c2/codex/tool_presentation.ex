defmodule HalC2.Codex.ToolPresentation do
  @moduledoc """
  How a Codex MCP tool call is shown in the work log: its surface (`browser` or
  `computer`), the source it groups under, and its icon — a page's favicon for
  browser work, an application's icon for computer work. Codex says which kind
  of work a call was in the result's `codex/toolSurface` metadata; a call
  without it keeps the plain tool presentation (`CodexToolPresentation.ts`).
  """

  @doc "The turn item fields for a Codex `mcpToolCall` item, empty for a plain call."
  @spec fields(map) :: map
  def fields(item) do
    metadata = get_in(item, ["result", "_meta"]) || %{}
    surface = metadata["codex/toolSurface"] || %{}
    app_context = item["appContext"] || %{}
    source_logo = themed_logo([surface, metadata["source"] || %{}, app_context])

    case surface["kind"] do
      "browserUse" -> browser(item, metadata, surface, app_context, source_logo)
      "computerUse" -> computer(item, surface, app_context, source_logo)
      _ -> %{}
    end
  end

  defp browser(_item, metadata, surface, app_context, source_logo) do
    screenshot = surface["screenshot"] || %{}
    browser_use = metadata["browser_use"] || %{}

    latest_tab =
      (surface["openTabs"] || [])
      |> Enum.reverse()
      |> Enum.find(&(is_map(&1) and http_url(&1["url"])))

    page =
      [
        {screenshot, screenshot["pageUrl"]},
        {browser_use, browser_use["url"]},
        {latest_tab || %{}, (latest_tab || %{})["url"]}
      ]
      |> Enum.map(fn {record, url} -> {record, http_url(url)} end)
      |> Enum.find(fn {_record, url} -> url end)

    name =
      browser_name(app_context["appName"]) || browser_name(surface["browserFamily"]) ||
        browser_name(surface["backend"]) || "Browser"

    native_icon =
      case name do
        "Chrome" ->
          %{
            "_tag" => "native-app",
            "app" => %{"_tag" => "display-name", "displayName" => "Google Chrome"}
          }

        name when name in ["Microsoft Edge", "Firefox", "Safari", "Arc"] ->
          %{"_tag" => "native-app", "app" => %{"_tag" => "display-name", "displayName" => name}}

        _ ->
          nil
      end

    source =
      %{
        "key" => "browser-use:#{String.downcase(String.trim(name))}",
        "name" => name,
        "kind" => if(name == "Browser", do: "browser", else: "integration")
      }
      |> with_icon(source_logo || native_icon)

    fields = %{"toolSurface" => "browser", "toolSource" => source}

    case page do
      {record, url} ->
        icon =
          %{"_tag" => "website", "pageUrl" => url}
          |> maybe("faviconUrl", image_url(record["faviconUrl"] || record["favIconUrl"]))
          |> maybe(
            "faviconUrlDark",
            image_url(record["faviconUrlDark"] || record["favIconUrlDark"])
          )

        Map.put(fields, "toolIcon", icon)

      nil ->
        fields
    end
  end

  defp computer(item, surface, app_context, source_logo) do
    app = native_app(surface["app"])
    args = item["arguments"] || %{}

    argument_name =
      display_name(args["appName"]) || display_name(args["application"]) ||
        if(is_binary(args["app"]), do: display_name(args["app"]))

    name =
      display_name(app_context["appName"]) || argument_name ||
        (app && app["_tag"] == "display-name" && app["displayName"]) ||
        (app && app["_tag"] == "app-id" && app_name_from_id(app["appId"])) ||
        "Computer Use"

    key =
      cond do
        app == nil -> "computer-use"
        app["_tag"] == "app-id" -> native_key(app["appId"])
        true -> "native-app-name:#{String.downcase(String.trim(app["displayName"]))}"
      end

    app_icon = if app, do: %{"_tag" => "native-app", "app" => app}

    source =
      %{"key" => key, "name" => name, "kind" => "computer"}
      |> with_icon(source_logo || app_icon)

    %{"toolSurface" => "computer", "toolSource" => source}
    |> then(&if(app_icon, do: Map.put(&1, "toolIcon", app_icon), else: &1))
  end

  defp with_icon(source, nil), do: source
  defp with_icon(source, icon), do: Map.put(source, "icon", icon)

  defp maybe(map, _key, nil), do: map
  defp maybe(map, key, value), do: Map.put(map, key, value)

  defp themed_logo(records) do
    Enum.find_value(records, fn record ->
      with url when is_binary(url) <- image_url((record || %{})["logoUrl"]) do
        %{"_tag" => "themed-logo", "logoUrl" => url}
        |> maybe("logoUrlDark", image_url(record["logoUrlDark"] || record["logoDarkUrl"]))
      end
    end)
  end

  defp native_app(%{"kind" => "appId", "appId" => id}) do
    if app_id = valid_app_id(id), do: %{"_tag" => "app-id", "appId" => app_id}
  end

  defp native_app(%{"kind" => "displayName", "displayName" => name}) do
    if name = display_name(name), do: %{"_tag" => "display-name", "displayName" => name}
  end

  defp native_app(_app), do: nil

  defp valid_app_id(id) when is_binary(id) do
    id = String.trim(id)
    if id != "" and byte_size(id) <= 512 and id =~ ~r/^[A-Za-z0-9._-]+$/, do: id
  end

  defp valid_app_id(_id), do: nil

  defp native_key(app_id) do
    key = "native-app:#{String.downcase(app_id)}"

    if byte_size(key) <= 512 do
      key
    else
      digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
      String.slice(key, 0, 512 - byte_size(digest) - 1) <> ":" <> digest
    end
  end

  @known_apps %{
    "com.apple.finder" => "Finder",
    "com.apple.safari" => "Safari",
    "com.google.chrome" => "Chrome",
    "com.microsoft.edgemac" => "Microsoft Edge",
    "org.mozilla.firefox" => "Firefox",
    "company.thebrowser.browser" => "Arc"
  }
  defp app_name_from_id(id), do: @known_apps[String.downcase(id)]

  defp browser_name(value) do
    case display_name(value) do
      nil ->
        nil

      name ->
        lower = String.downcase(name)

        cond do
          String.contains?(lower, "chrome") or lower == "chromium" -> "Chrome"
          String.contains?(lower, "edge") -> "Microsoft Edge"
          String.contains?(lower, "firefox") -> "Firefox"
          String.contains?(lower, "safari") -> "Safari"
          String.contains?(lower, "arc") -> "Arc"
          lower == "iab" or String.contains?(lower, "in-app") -> "Browser"
          true -> name
        end
    end
  end

  defp display_name(value) when is_binary(value) do
    name = value |> String.trim() |> String.replace(~r/\s+/, " ")
    if name != "" and String.length(name) <= 160, do: name
  end

  defp display_name(_value), do: nil

  defp http_url(value) when is_binary(value) and byte_size(value) <= 4096 do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        if host != "", do: URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp http_url(_value), do: nil

  defp image_url(value) when is_binary(value) and byte_size(value) <= 4096 do
    case URI.parse(value) do
      %URI{scheme: scheme} = uri when scheme in ["http", "https", "data"] -> URI.to_string(uri)
      _ -> nil
    end
  end

  defp image_url(_value), do: nil
end
