defmodule HalC2.ProjectFavicon do
  @moduledoc """
  The icon file a project shows, found in this order: the project's saved
  `faviconPath`, then the checkout's hal-c2.json
  `iconPath`, then well-known favicon locations, then an icon an HTML or root
  route source links to. Paths other than the saved one stay inside the checkout.
  """

  @candidates ~w(favicon.svg favicon.ico favicon.png public/favicon.svg public/favicon.ico
                 public/favicon.png app/favicon.ico app/favicon.png app/icon.svg app/icon.png
                 app/icon.ico src/favicon.ico src/favicon.svg src/app/favicon.ico
                 src/app/icon.svg src/app/icon.png assets/icon.svg assets/icon.png
                 assets/logo.svg assets/logo.png .idea/icon.svg)

  @sources ~w(index.html public/index.html app/routes/__root.tsx src/routes/__root.tsx
              app/root.tsx src/root.tsx src/index.html)

  @link_icon ~r/<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])(?=[^>]*\bhref=["']([^"'?]+))[^>]*>/i
  @icon_rel ~r/\brel\s*:\s*["'](?:icon|shortcut icon)["']/i
  @icon_href ~r/\bhref\s*:\s*["']([^"'?]+)/i

  @doc "The icon's absolute path under `root`, or nil when the project has none."
  def resolve(root, saved_path \\ nil) do
    saved(root, saved_path) || first(root, List.wrap(icon_path(root))) || first(root, @candidates) ||
      Enum.find_value(@sources, fn source ->
        with {:ok, text} <- File.read(Path.join(root, source)),
             href when is_binary(href) <- href(text) do
          clean = String.trim_leading(href, "/")
          first(root, [Path.join("public", clean), clean])
        else
          _ -> nil
        end
      end)
  end

  # A saved path may point outside the checkout; it is used where it exists.
  defp saved(_root, nil), do: nil

  defp saved(root, path) do
    full = if Path.type(path) == :absolute, do: path, else: Path.join(root, path)
    if File.regular?(full), do: full
  end

  defp icon_path(root) do
    with {:ok, text} <- HalC2.ProjectFile.read(root),
         {:ok, %{"iconPath" => path}} when is_binary(path) <- JSON.decode(text),
         do: path,
         else: (_ -> nil)
  end

  defp first(root, candidates) do
    Enum.find_value(candidates, fn relative ->
      case HalC2.Workspace.resolve(root, relative) do
        {:ok, full} -> if File.regular?(full), do: full
        {:error, _} -> nil
      end
    end)
  end

  defp href(text) do
    case Regex.run(@link_icon, text) do
      [_, href] ->
        href

      _ ->
        # Icon metadata counts when `rel` and `href` share a brace-free run.
        text
        |> String.split("}")
        |> Enum.find_value(fn run ->
          if Regex.match?(@icon_rel, run),
            do: with([_, href] <- Regex.run(@icon_href, run), do: href, else: (_ -> nil))
        end)
    end
  end
end
